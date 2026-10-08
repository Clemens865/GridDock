import AppKit

/// Terminal.app specifics: find each window's working directory, open new windows in a folder.
/// Uses AppleScript (macOS asks once for "Automation → Terminal" permission).
enum TerminalBridge {
    private static func runAppleScript(_ source: String) -> NSAppleEventDescriptor? {
        var err: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
        if let err { NSLog("GridDock AppleScript error: \(err)") }
        return result
    }

    private static func shell(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    /// [window title: current directory of its shell] for every Terminal window.
    static func directoriesByWindowTitle() -> [String: String] {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: ProjectLayoutStore.terminalBundleID).isEmpty else { return [:] }
        let script = """
        set out to ""
        tell application "Terminal"
            repeat with w in windows
                set out to out & (name of w) & "\t" & (tty of selected tab of w) & linefeed
            end repeat
        end tell
        return out
        """
        guard let text = runAppleScript(script)?.stringValue else { return [:] }
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, let dir = cwd(ofTTY: parts[1]) else { continue }
            result[parts[0]] = dir
        }
        return result
    }

    /// [tty: window ID] for every tab of every Terminal window (a session in a background tab maps to its window).
    /// Terminal's AppleScript window id is the system window number, which — unlike the title — never changes.
    static func windowIDsByTTY() -> [String: CGWindowID] {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: ProjectLayoutStore.terminalBundleID).isEmpty else { return [:] }
        let script = """
        set out to ""
        tell application "Terminal"
            repeat with w in windows
                set n to id of w
                repeat with t in tabs of w
                    set out to out & (tty of t) & "\t" & n & linefeed
                end repeat
            end repeat
        end tell
        return out
        """
        guard let text = runAppleScript(script)?.stringValue else { return [:] }
        var result: [String: CGWindowID] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            if parts.count == 2, let id = CGWindowID(parts[1]) { result[parts[0]] = id }
        }
        return result
    }

    /// Working directory of the shell running on a tty like "/dev/ttys003".
    private static func cwd(ofTTY tty: String) -> String? {
        let name = tty.replacingOccurrences(of: "/dev/", with: "")
        let procs = shell(["ps", "-t", name, "-o", "pid=,comm="]).split(separator: "\n")
        let shellNames = ["zsh", "bash", "fish", "sh"]
        guard let line = procs.first(where: { l in shellNames.contains { l.hasSuffix($0) } }),
              let pid = line.split(separator: " ").first else { return nil }
        let out = shell(["lsof", "-a", "-p", String(pid), "-d", "cwd", "-Fn"])
        return out.split(separator: "\n").first { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
    }

    /// Opens a new Terminal window in `dir` (optionally running `command`) and returns it.
    @MainActor
    static func openWindow(in dir: String, command: String?) async -> AXWindow? {
        func terminalWindows() -> [AXWindow] {
            NSRunningApplication.runningApplications(withBundleIdentifier: ProjectLayoutStore.terminalBundleID)
                .flatMap { AX.windows(of: $0) }
        }
        let before = terminalWindows()
        let quoted = "'" + dir.replacingOccurrences(of: "'", with: "'\\''") + "'"
        var cmd = "cd \(quoted)"
        if let command, !command.isEmpty { cmd += " && \(command)" }
        let escaped = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        _ = runAppleScript("""
        tell application "Terminal"
            do script "\(escaped)"
            activate
        end tell
        """)
        for _ in 0..<25 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if let new = terminalWindows().first(where: { w in !before.contains { $0.isSame(w) } }) { return new }
        }
        return nil
    }
}
