import AppKit
import Darwin

/// Jump-to-terminal: walk the agent process's ancestry until we find a known
/// terminal/editor app and activate it. Codex desktop sessions open the
/// `codex://threads/<id>` deep link instead.
enum AgentTerminalJump {

    /// Known terminal / editor bundle ids (exact matches).
    static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp-Preview",
        "io.alacritty",
        "org.alacritty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
        "com.mitchellh.ghostty",
        "com.raphaelamorim.rio",
        "org.tabby",
        "dev.commandline.waveterm",
        "org.contourterminal.Contour",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.exafunction.windsurf",
        "dev.zed.Zed",
        // Desktop apps hosting embedded agent sessions (Claude Code inside
        // Claude Desktop; Codex desktop). Jump activates the app; notification
        // muting treats them like terminals when frontmost.
        "com.anthropic.claudefordesktop",
        "com.openai.codex",
    ]

    /// Prefix matches (JetBrains IDE family ships many bundle ids).
    static let terminalBundlePrefixes: [String] = [
        "com.jetbrains.",
        "com.google.android.studio",
    ]

    static func isTerminalBundleID(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        if terminalBundleIDs.contains(bundleID) { return true }
        return terminalBundlePrefixes.contains { bundleID.hasPrefix($0) }
    }

    /// True when the frontmost app is a terminal/editor — used to mute notifications.
    @MainActor
    static func frontmostIsTerminal() -> Bool {
        isTerminalBundleID(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    /// Bring the terminal (or Codex desktop thread) hosting this session to front.
    /// Returns false when there is nothing to jump to.
    @MainActor
    @discardableResult
    static func jump(to session: AgentSession) -> Bool {
        if session.provider == .codex, session.codexOrigin == .desktop {
            guard let url = URL(string: "codex://threads/\(session.sessionId)") else { return false }
            return NSWorkspace.shared.open(url)
        }
        guard let pid = session.processID else { return false }
        guard let app = hostTerminalApp(forProcess: pid) else { return false }
        return app.activate(options: [])
    }

    /// Walk the ppid chain (≤12 hops) from `pid` looking for a running app whose
    /// bundle id is in the terminal allowlist.
    @MainActor
    static func hostTerminalApp(forProcess pid: pid_t) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<12 {
            guard current > 0 else { return nil }
            if let app = NSRunningApplication(processIdentifier: current),
               isTerminalBundleID(app.bundleIdentifier) {
                return app
            }
            guard let parent = parentPID(of: current), parent != current, parent > 1 else {
                return nil
            }
            current = parent
        }
        return nil
    }

    /// Parent PID via proc_pidinfo(PROC_PIDT_SHORTBSDINFO). Returns nil for
    /// dead processes or permission failures — never crashes.
    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        let flavor: Int32 = PROC_PIDT_SHORTBSDINFO
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            proc_pidinfo(pid, flavor, 0, ptr, size)
        }
        guard result == size else { return nil }
        return pid_t(info.pbsi_ppid)
    }
}
