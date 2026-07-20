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
        // Hook-reported sessions carry a PID; transcript-discovered ones don't —
        // fall back to matching a running agent process by working directory.
        let pid = session.processID
            ?? locateProcess(provider: session.provider, cwd: session.cwd)
        guard let pid, let app = hostTerminalApp(forProcess: pid) else { return false }
        return app.activate(options: [])
    }

    /// Find a running `claude`/`codex` process whose current working directory
    /// matches the session's cwd. Lets jump-to-terminal work with zero setup
    /// (no hooks installed). ~50 ms of `ps` on click; only runs when needed.
    static func locateProcess(provider: AgentProvider, cwd: String) -> pid_t? {
        guard !cwd.isEmpty else { return nil }
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        do { try ps.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        let needle = provider == .claude ? "claude" : "codex"
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let spaceIndex = trimmed.firstIndex(of: " "),
                  let pid = pid_t(trimmed[..<spaceIndex]) else { continue }
            let command = trimmed[trimmed.index(after: spaceIndex)...].lowercased()
            guard command.contains(needle) else { continue }
            // Skip app-bundle helper processes (Claude.app/Codex.app renderers);
            // the CLI process is the one whose cwd is the project directory.
            if command.contains(".app/contents/") { continue }
            if currentWorkingDirectory(of: pid) == cwd { return pid }
        }
        return nil
    }

    /// Working directory via proc_pidinfo(PROC_PIDVNODEPATHINFO).
    static func currentWorkingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, ptr, size)
        }
        guard result == size else { return nil }
        var path = info.pvi_cdir.vip_path
        return withUnsafePointer(to: &path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
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
