import Foundation

/// The embedded hook script installed to
/// `~/Library/Application Support/Atoll/atoll-hook.sh` (chmod 755).
///
/// One script serves both providers — the installer registers it as
/// `atoll-hook.sh claude` in ~/.claude/settings.json and
/// `atoll-hook.sh codex` in ~/.codex/hooks.json.
///
/// Behavior:
/// - exits 0 instantly (and silently) when /tmp/atoll.sock is absent, so the
///   hooks cost ~nothing while Atoll is not running;
/// - reads the hook JSON from stdin (passed through as fd 3 into python3),
///   maps hook_event_name → status, walks the process ancestry (≤8 hops) to find
///   the real claude/codex PID, detects non-interactive `-p/--print` runs, and
///   sends one JSON line to the socket;
/// - for PermissionRequest it half-closes the socket (SHUT_WR) and blocks in
///   recv for up to 290s; whatever Atoll writes back is printed to stdout
///   verbatim, which the CLI consumes as the hook-decision JSON. If the app
///   never answers, the script prints nothing and the CLI falls back to its own
///   permission prompt.
enum AgentHookScript {

    /// Marker every installed hook command must contain — used for idempotent
    /// install and prune-only-ours uninstall.
    static let marker = "atoll"

    static let scriptFileName = "atoll-hook.sh"

    static let text: String = #"""
#!/bin/bash
# atoll-hook.sh — Atoll agent-session hook (marker: atoll)
# Installed and managed by Atoll.app. Do not edit; reinstalling overwrites.
# Usage: atoll-hook.sh [claude|codex]
SOCKET="${AGENTNOOK_SOCKET:-/tmp/atoll.sock}"
[ -S "$SOCKET" ] || exit 0
PROVIDER="${1:-${AGENTNOOK_PROVIDER:-claude}}"
command -v /usr/bin/python3 >/dev/null 2>&1 || exit 0
# Keep the hook's real stdin (the hook JSON) on fd 3; the heredoc takes fd 0.
exec 3<&0
/usr/bin/python3 - "$PROVIDER" "$SOCKET" <<'AGENTNOOK_PY'
import json, os, re, socket, subprocess, sys

provider = sys.argv[1] if len(sys.argv) > 1 else "claude"
sock_path = sys.argv[2] if len(sys.argv) > 2 else "/tmp/atoll.sock"

STATUS_MAP = {
    "UserPromptSubmit": "processing",
    "PreToolUse": "running_tool",
    "PostToolUse": "processing",
    "PostToolUseFailure": "processing",
    "PreCompact": "compacting",
    "Stop": "waiting_for_input",
    "SubagentStop": "waiting_for_input",
    "PermissionRequest": "permission_request",
    "SessionStart": "session_start",
    "SessionEnd": "ended",
    "Notification": "notification",
}


def find_agent_process(needle):
    """Walk the parent-PID chain (max 8 hops) looking for the claude/codex
    process. Returns (pid, tty, interactive) or (None, "", True)."""
    try:
        out = subprocess.run(
            ["/bin/ps", "-axo", "pid=,ppid=,tty=,command="],
            capture_output=True, text=True, timeout=5,
        ).stdout
    except Exception:
        return None, "", True
    table = {}
    for line in out.splitlines():
        parts = line.split(None, 3)
        if len(parts) < 4:
            continue
        try:
            pid_i = int(parts[0]); ppid_i = int(parts[1])
        except ValueError:
            continue
        table[pid_i] = (ppid_i, parts[2], parts[3])
    pid = os.getppid()
    for _ in range(8):
        entry = table.get(pid)
        if entry is None:
            return None, "", True
        ppid_i, tty, cmd = entry
        lower = cmd.lower()
        if "atoll" in lower or lower.startswith("/usr/bin/python3"):
            # our own hook chain — keep climbing
            pid = ppid_i
            continue
        argv = cmd.split()
        hit = False
        for tok in argv[:3]:
            base = os.path.basename(tok).lower()
            if needle in base:
                hit = True
                break
        if hit:
            padded = " " + cmd + " "
            interactive = not (" -p " in padded or " --print" in padded
                               or " exec " in padded and needle == "codex")
            return pid, tty, interactive
        if ppid_i in (0, 1) or ppid_i == pid:
            return None, "", True
        pid = ppid_i
    return None, "", True


def main():
    try:
        raw = os.fdopen(3, "r").read()
    except Exception:
        raw = ""
    try:
        data = json.loads(raw) if raw.strip() else {}
    except Exception:
        data = {}
    if not isinstance(data, dict):
        data = {}

    event = data.get("hook_event_name") or ""
    status = STATUS_MAP.get(event, "processing")

    needle = "claude" if provider == "claude" else "codex"
    agent_pid, tty, interactive = find_agent_process(needle)

    payload = {
        "provider": provider,
        "session_id": data.get("session_id") or "",
        "event": event,
        "status": status,
        "transcript_path": data.get("transcript_path"),
        "cwd": data.get("cwd"),
        "interactive": interactive,
        "permission_mode": data.get("permission_mode"),
    }
    if data.get("model"):
        payload["model"] = data.get("model")
    if event == "UserPromptSubmit":
        payload["user_prompt"] = data.get("prompt") or data.get("user_prompt")
    if event in ("PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest"):
        payload["tool"] = data.get("tool_name")
        payload["tool_use_id"] = data.get("tool_use_id")
        payload["tool_input"] = data.get("tool_input")
    if event == "PermissionRequest":
        payload["permission_suggestions"] = data.get("permission_suggestions")
    if event in ("Stop", "SubagentStop") and data.get("last_assistant_message"):
        payload["last_assistant_message"] = data.get("last_assistant_message")
    if event == "Notification":
        payload["notification_type"] = (data.get("notification_type")
                                        or data.get("matcher") or "")
        payload["message"] = data.get("message")
    if event == "PreCompact":
        payload["compact_trigger"] = data.get("trigger")
    if event in ("SessionStart", "SessionEnd"):
        payload["source"] = data.get("source") or data.get("reason")
    if agent_pid is not None:
        key = "claude_process_id" if provider == "claude" else "codex_process_id"
        payload[key] = agent_pid
    if provider == "codex":
        payload["codex_origin"] = "desktop" if tty.strip() in ("??", "?", "") else "cli"

    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(5)
        s.connect(sock_path)
        s.sendall((json.dumps(payload) + "\n").encode("utf-8"))
    except Exception:
        return

    if event == "PermissionRequest":
        # Hold the line: Atoll writes the hook-decision JSON back when the
        # user answers in the notch. Print it verbatim; print nothing on timeout
        # so the CLI falls back to its own prompt.
        try:
            s.shutdown(socket.SHUT_WR)
            s.settimeout(290)
            chunks = []
            while True:
                b = s.recv(65536)
                if not b:
                    break
                chunks.append(b)
            reply = b"".join(chunks).decode("utf-8", "replace").strip()
            if reply:
                sys.stdout.write(reply)
                sys.stdout.flush()
        except Exception:
            pass
    try:
        s.close()
    except Exception:
        pass


try:
    main()
except Exception:
    pass
AGENTNOOK_PY
exit 0
"""#
}
