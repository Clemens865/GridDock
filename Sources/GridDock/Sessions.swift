import AppKit

/// A Claude Code session as reported by the hook script.
struct ClaudeSession {
    enum State: String { case working, waiting, done }
    let id: String
    let state: State
    let cwd: String
    let tty: String
    let updated: Date

    var project: String { (cwd as NSString).lastPathComponent }
}

extension Notification.Name {
    static let claudeSessionsChanged = Notification.Name("GridDock.claudeSessionsChanged")
}

/// Watches the hook files and maps each session to its Terminal window (via the window's tty).
@MainActor
final class SessionMonitor {
    static let shared = SessionMonitor()

    private(set) var sessions: [ClaudeSession] = []
    /// tty → Terminal window ID, refreshed every few seconds (AppleScript is too slow to run every tick).
    private var ttyWindows: [String: CGWindowID] = [:]
    private var lastTTYRefresh = Date.distantPast
    private var timer: Timer?
    private var lastStates: [String: ClaudeSession.State] = [:]

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in SessionMonitor.shared.poll() }
        }
        poll()
    }

    var waitingCount: Int { sessions.filter { $0.state == .waiting }.count }

    private func poll() {
        let dir = ClaudeHooks.sessionsDir
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let liveTTYs = Self.ttysWithClaude()
        var found: [ClaudeSession] = []
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let state = (obj["state"] as? String).flatMap(ClaudeSession.State.init),
                  let ts = obj["ts"] as? Double else { continue }
            let tty = obj["tty"] as? String ?? ""
            // Session gone without a SessionEnd (crash, closed window): forget it.
            if !tty.isEmpty && !liveTTYs.contains(tty) { try? FileManager.default.removeItem(at: url); continue }
            if Date().timeIntervalSince1970 - ts > 24 * 3600 { continue }
            found.append(ClaudeSession(id: url.deletingPathExtension().lastPathComponent, state: state,
                                       cwd: obj["cwd"] as? String ?? "", tty: tty,
                                       updated: Date(timeIntervalSince1970: ts)))
        }
        found.sort { $0.project < $1.project }

        // Newly waiting sessions get a heads-up, especially when they're on a hidden page.
        for s in found where s.state == .waiting && lastStates[s.id] != .waiting {
            announce(s)
        }
        lastStates = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0.state) })

        if Date().timeIntervalSince(lastTTYRefresh) > 4 || found.contains(where: { ttyWindows[$0.tty] == nil && !$0.tty.isEmpty }) {
            ttyWindows = TerminalBridge.windowIDsByTTY()
            lastTTYRefresh = Date()
        }
        let changed = found.map { "\($0.id)\($0.state)" } != sessions.map { "\($0.id)\($0.state)" }
        sessions = found
        if changed { NotificationCenter.default.post(name: .claudeSessionsChanged, object: nil) }
        StatusBorders.shared.update()
    }

    /// Terminal device paths that currently run a `claude` process.
    private static func ttysWithClaude() -> Set<String> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "tty=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        var ttys = Set<String>()
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0] != "??", (parts[1] as NSString).lastPathComponent == "claude" else { continue }
            ttys.insert("/dev/" + parts[0])
        }
        return ttys
    }

    /// The session running in this window, if any.
    func session(for w: AXWindow) -> ClaudeSession? {
        guard w.bundleID == ProjectLayoutStore.terminalBundleID, let id = Spaces.windowID(w) else { return nil }
        // Several sessions can share a window (tabs): the one needing attention wins.
        let mine = sessions.filter { ttyWindows[$0.tty] == id }
        return mine.first { $0.state == .waiting } ?? mine.first { $0.state == .working } ?? mine.first
    }

    /// The Terminal window a session runs in.
    func window(for s: ClaudeSession) -> AXWindow? {
        guard let id = ttyWindows[s.tty],
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: ProjectLayoutStore.terminalBundleID).first
        else { return nil }
        return AX.windows(of: app, includeMinimized: true).first { Spaces.windowID($0) == id }
    }

    private func announce(_ s: ClaudeSession) {
        var where_ = ""
        if let w = window(for: s), let i = PageManager.shared.pageIndex(of: w), i != PageManager.shared.current {
            where_ = "  ·  on \(PageManager.shared.title(of: i))"
        }
        PageHUD.shared.flash(message: "⏺ \(s.project) needs you\(where_)  ·  ⌃⌥W to jump there")
    }

    /// ⌃⌥W: focus the next session that needs you (switching pages if needed).
    func jumpToWaiting() {
        let waiting = sessions.filter { $0.state == .waiting }
        guard !waiting.isEmpty else { PageHUD.shared.flash(message: "No Claude session is waiting for you"); return }
        let focused = AX.focusedWindow()
        let currentIdx = waiting.firstIndex { s in focused.map { session(for: $0)?.id == s.id } ?? false }
        let next = waiting[((currentIdx ?? -1) + 1) % waiting.count]
        guard let w = window(for: next) else { return }
        if let i = PageManager.shared.pageIndex(of: w), i != PageManager.shared.current {
            PageManager.shared.go(to: i, focus: w)
        } else {
            w.focus()
        }
    }
}
