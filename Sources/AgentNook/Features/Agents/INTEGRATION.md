# Features/Agents — integration notes

Engine-only module (models + managers, **no SwiftUI views**). `Features/AgentsUI`
consumes the published state and provides all views, including the settings view
and hook install/uninstall buttons.

## Startup calls (AppDelegate, at launch)

```swift
AgentSessionStore.shared.start()      // binds /tmp/agentnook.sock, discovers existing
                                      // sessions from transcripts, starts liveness +
                                      // stale timers. Idempotent.
AgentHookInstaller.shared.refreshStatus()   // read-only status probe (no writes)
```

Optional on quit: `AgentSessionStore.shared.stop()` (closes + unlinks the socket).

**Never call `AgentHookInstaller.shared.install()` automatically** — it must be
triggered by an explicit UI button (AgentsUI settings). `install()`/`uninstall()`
are idempotent, preserve all non-AgentNook config, and mark entries with the
`agentnook` path marker.

## Published state (for AgentsUI)

- `AgentSessionStore.shared` (`@MainActor ObservableObject`)
  - `sessions: [String: AgentSession]`, `orderedSessions` (attention first),
    `attention: Bool` (any session waiting/permission — drive the closed-notch
    wing pulse from this), `liveSessionCount`, `socketActive`
  - `respondToPermission(sessionKey:allow:remember:denyMessage:)`
  - `answerQuestion(sessionKey:question:answer:)` (AskUserQuestion)
  - `resolvePermission(sessionKey:responseJSON:)` (raw escape hatch)
- `AgentSession`: provider, projectName (cwd last component), model,
  permissionMode, interactive?, state (`idle/working/runningTool/waitingForInput/
  permissionRequest/compacting/ended`), isStale, lastUserPrompt,
  lastAssistantMessage, toolEvents (ring, last 20), pendingPermission
  (`AgentPermissionRequestPayload`: toolName, toolInput, suggestions,
  inputSummary), tokensUsed/contextWindow (`contextFraction`), codexOrigin.
- `AgentHookInstaller.shared`: `claudeState` / `codexState` / `overallState`
  (`notInstalled/partial/installed`), `lastError`, `install()`, `uninstall()`,
  `refreshStatus()`.
- `AgentTerminalJump.jump(to: session)` — click a session row → activates the
  hosting terminal/editor (or opens `codex://threads/<id>` for Codex desktop).
  `AgentTerminalJump.frontmostIsTerminal()` for mute logic (already used by
  AgentNotifier).

## Settings

Engine reads (already in Core/SettingsStore): `agentsNotifyOnAttention`,
`agentsNotifyOnCompletion`, `agentsIdleCutoffMinutes`. Settings **view** comes
from AgentsUI.

## Permissions / Info.plist

- **User notifications**: `AgentNotifier` requests UN authorization lazily on
  the first notification (never at launch). Requires a bundled app (bundle id);
  when running unbundled it degrades to `NSSound.beep()` + log, no crash.
  No Info.plist key needed (alert+sound only).
- No other TCC permissions. The socket, hook configs, and transcripts are plain
  file access (app is unsandboxed).

## Behavior notes for the integrator

- Socket: `/tmp/agentnook.sock`, chmod 0600, stale-socket probe on bind. If a
  second AgentNook instance is running, `socketActive == false` (UI can surface).
- PermissionRequest hooks are held open ≤290s. On timeout the app writes
  **nothing** and closes — the hook prints nothing and the CLI falls back to its
  own interactive prompt (safe default; no silent deny).
- Hook script installed to
  `~/Library/Application Support/AgentNook/agentnook-hook.sh` (0755); registered
  as `… claude` in `${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json`
  (SessionStart, UserPromptSubmit, PreToolUse `*`, PostToolUse `*`,
  PermissionRequest `*`, PreCompact auto+manual, Stop, SubagentStop, SessionEnd,
  Notification `agent_needs_input|agent_completed|permission_prompt`) and as
  `… codex` in `~/.codex/hooks.json` (SessionStart, UserPromptSubmit, PreToolUse,
  PermissionRequest, PostToolUse, Stop; timeout 300). Codex hooks are on by
  default — no config.toml flag is touched.
- Sessions ended linger 60s, then disappear; sessions idle past
  `agentsIdleCutoffMinutes` are marked `isStale` (busy states demoted to idle)
  and silently dropped at 2× the cutoff.
- Notifications: needs-input / approval-needed / finished, 30s per-session
  cooldown, muted while a terminal/editor is frontmost, skipped for
  non-interactive (`claude -p`) runs.
