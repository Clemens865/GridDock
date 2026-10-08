import AppKit

/// "Arrange everything" gathers every window — fullscreen apps, other desktops, minimized,
/// hidden — onto the grid desktop and spreads them over pages. Auto-arrange mode keeps it that
/// way: new windows join the grid, closed ones free their cell, full pages spill onto new ones.
@MainActor
final class AutoArrange {
    static let shared = AutoArrange()

    private let modeKey = "autoArrangeMode"
    private let maxKey = "windowsPerPage"
    private var timer: Timer?
    private(set) var busy = false

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: modeKey) }
        set { UserDefaults.standard.set(newValue, forKey: modeKey); newValue ? startWatching() : stopWatching() }
    }

    var perPage: Int {
        get { let v = UserDefaults.standard.integer(forKey: maxKey); return v > 0 ? v : 6 }
        set { UserDefaults.standard.set(newValue, forKey: maxKey) }
    }

    /// The display that holds the grid (Spaces are tracked for the main display).
    private var gridScreen: NSScreen { NSScreen.screens.first ?? NSScreen.main! }

    private func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    // MARK: Arrange everything

    /// Stage Manager keeps only one app group on the desktop and shrinks the rest into its side
    /// strip, so a grid can't show them. GridDock needs it off.
    static var stageManagerOn: Bool {
        UserDefaults(suiteName: "com.apple.WindowManager")?.bool(forKey: "GloballyEnabled") ?? false
    }

    /// Returns false (and explains) when Stage Manager would hide the arranged windows.
    static func checkStageManager() -> Bool {
        guard stageManagerOn else { return true }
        let alert = NSAlert()
        alert.messageText = "Turn off Stage Manager"
        alert.informativeText = "Stage Manager shows one app at a time and shrinks all others into the strip on the left, so they can't sit in the grid. Turn it off in Control Center (the Stage Manager tile) or in System Settings → Desktop & Dock, then arrange again."
        alert.addButton(withTitle: "Open Desktop & Dock settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!)
        }
        return false
    }

    func arrangeEverything(byProject: Bool = false) {
        guard !busy, Self.checkStageManager() else { return }
        busy = true
        Task {
            defer { busy = false }
            await gatherAll()
            byProject ? arrangeByProject() : arrangeOnGridDesktop()
        }
    }

    /// Project name for a folder: the folder right below "Software-Projects" (or similar roots),
    /// otherwise the folder itself. The home folder itself belongs to no project.
    nonisolated static func projectName(forPath path: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard !path.isEmpty, path != home, path != "/" else { return nil }
        let parts = (path as NSString).pathComponents
        for root in ["Software-Projects", "Projects", "Developer", "Code", "src", "repos"] {
            if let i = parts.firstIndex(of: root), parts.count > i + 1 { return parts[i + 1] }
        }
        return (path as NSString).lastPathComponent
    }

    /// One page per project: terminals by their folder (or Claude session), other windows by a
    /// project name in their title. Everything else goes on a final "Other" page.
    private func arrangeByProject() {
        let screenAX = ScreenGeometry.flip(gridScreen.frame)
        let wins = AX.visibleWindows().filter { w in
            guard let f = w.frame else { return false }
            return screenAX.contains(CGPoint(x: f.midX, y: f.midY)) && Rules.tiles(w)
        }
        guard !wins.isEmpty else { PageHUD.shared.flash(message: "No windows to arrange"); return }

        let dirs = TerminalBridge.directoriesByWindowTitle()
        var projectOf: [Int: String] = [:]
        for (i, w) in wins.enumerated() where w.bundleID == ProjectLayoutStore.terminalBundleID {
            let cwd = SessionMonitor.shared.session(for: w)?.cwd ?? dirs[w.title]
            if let name = cwd.flatMap(Self.projectName(forPath:)) { projectOf[i] = name }
        }
        // Other apps join a project when their title mentions it (e.g. "TaxMex – Chrome", "Atelier").
        let known = Set(projectOf.values).filter { $0.count >= 4 }
        for (i, w) in wins.enumerated() where projectOf[i] == nil {
            let title = w.title.lowercased()
            if let match = known.first(where: { title.contains($0.lowercased()) }) { projectOf[i] = match }
        }

        var groups: [(String, [AXWindow])] = known.union(projectOf.values).sorted().map { name in
            (name, wins.indices.filter { projectOf[$0] == name }.map { wins[$0] })
        }
        let rest = wins.indices.filter { projectOf[$0] == nil }.map { wins[$0] }
        if !rest.isEmpty { groups.append(("Other", rest)) }

        var chunks: [[AXWindow]] = []
        var names: [String?] = []
        for (name, ws) in groups where !ws.isEmpty {
            let parts = GridLayout.balancedChunks(ws, perPage: perPage)
            for (k, part) in parts.enumerated() {
                chunks.append(part)
                names.append(parts.count > 1 ? "\(name) \(k + 1)" : name)
            }
        }
        PageManager.shared.rebuild(chunks, names: names)
        PageHUD.shared.flash(message: "\(groups.count) project pages: " + groups.map(\.0).joined(separator: " · "))
    }

    /// Windows that live on a Space other than the grid desktop: (pid, window id, space).
    private func foreignWindows() -> [(pid_t, CGWindowID, UInt64)] {
        guard Spaces.isAvailable, let home = Spaces.home else { return [] }
        let known = Set(Spaces.ordered().map(\.id))
        let me = ProcessInfo.processInfo.processIdentifier
        let regular = Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map(\.processIdentifier))
        let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me, regular.contains(pid),
                  let wid = w[kCGWindowNumber as String] as? CGWindowID,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  (b["Width"] ?? 0) > 150, (b["Height"] ?? 0) > 150,
                  let space = Spaces.space(ofWindowID: wid), space != home, known.contains(space)
            else { return nil }
            return (pid, wid, space)
        }
    }

    private func gatherAll() async {
        PageManager.shared.unparkAll()

        // Hidden apps and minimized windows come back first (they then show up on their own Space).
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.isHidden {
            app.unhide()
        }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            for w in AX.windows(of: app, includeMinimized: true) where w.isMinimized {
                AXUIElementSetAttributeValue(w.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
        }
        await sleep(0.8)

        guard Spaces.isAvailable, let home = Spaces.home else { return }
        var skipped = Set<CGWindowID>()
        for _ in 0..<40 {
            let pending = foreignWindows().filter { !skipped.contains($0.1) }
            guard let (pid, wid, space) = pending.first else { break }
            Log.write("gather: \(pending.count) windows elsewhere; next pid \(pid) window \(wid) on space \(space)")
            PageHUD.shared.flash(message: "Bringing windows to Desktop \(Spaces.homeNumber)…  \(pending.count) left")
            skipped.insert(wid)   // one attempt per window, so a stubborn one can't loop forever

            guard await SpacePull.go(to: space) else { continue }
            await sleep(0.3)
            guard let app = NSRunningApplication(processIdentifier: pid),
                  let w = AX.windows(of: app, includeMinimized: true).first(where: { Spaces.windowID($0) == wid })
            else { Log.write("gather: window \(wid) not visible to Accessibility even on its space"); continue }

            if w.isFullscreen {
                await withCheckedContinuation { c in w.exitFullscreen { c.resume() } }
                await sleep(0.3)
            }
            if let s = Spaces.space(of: w), s != home {
                _ = await SpacePull.pullToHome(w)
            }
        }
        _ = await SpacePull.go(to: home)
        await sleep(0.3)
    }

    /// Groups the grid desktop's windows by app and spreads them over balanced pages.
    private func arrangeOnGridDesktop() {
        let screen = gridScreen
        let screenAX = ScreenGeometry.flip(screen.frame)
        let wins = AX.visibleWindows().filter { w in
            guard let f = w.frame else { return false }
            return screenAX.contains(CGPoint(x: f.midX, y: f.midY)) && Rules.tiles(w)
        }
        guard !wins.isEmpty else { PageHUD.shared.flash(message: "No windows to arrange"); return }

        // Keep each app's windows together (e.g. all terminals side by side).
        var order: [pid_t] = []
        for w in wins where !order.contains(w.pid) { order.append(w.pid) }
        let grouped = order.flatMap { pid in wins.filter { $0.pid == pid } }

        let chunks = GridLayout.balancedChunks(grouped, perPage: perPage)
        let pageCount = chunks.count
        PageManager.shared.rebuild(chunks)
        PageHUD.shared.flash(message: "Arranged \(grouped.count) windows on \(pageCount) page\(pageCount == 1 ? "" : "s")")
    }

    // MARK: Auto-arrange mode

    func startWatching() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in AutoArrange.shared.tick() }
        }
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    private var scanning = false

    private func tick() {
        guard enabled, !busy, !scanning, !Self.stageManagerOn, !OverlayController.shared.isPicking,
              NSEvent.pressedMouseButtons == 0 else { return }
        if Spaces.isAvailable, let home = Spaces.home, Spaces.current != home { return }  // you're in a fullscreen app or elsewhere

        // Asking every app for its windows can be slow (a busy app answers late), so do it off the main thread.
        scanning = true
        let screenAX = ScreenGeometry.flip(gridScreen.frame)
        Task.detached(priority: .userInitiated) {
            let visible = AX.visibleWindows().filter { w in
                guard let f = w.frame else { return false }
                return screenAX.contains(CGPoint(x: f.midX, y: f.midY)) && Rules.tiles(w)
            }
            await MainActor.run {
                AutoArrange.shared.scanning = false
                AutoArrange.shared.apply(visible)
            }
        }
    }

    private func apply(_ visible: [AXWindow]) {
        guard enabled, !busy, NSEvent.pressedMouseButtons == 0 else { return }
        let pm = PageManager.shared
        let cur = pm.currentWindows
        let alive = cur.filter { w in visible.contains { $0.isSame(w) } }
        let new = visible.filter { v in !cur.contains { $0.isSame(v) } }
        guard !new.isEmpty || alive.count != cur.count else { return }

        var list = alive
        var spillPage: Int?
        for w in new {
            if list.count < perPage { list.append(w) } else { spillPage = pm.addToPageWithRoom(w, max: perPage) }
        }
        pm.tile(list, on: gridScreen)
        if let page = spillPage {
            // Show the page the new window landed on.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { pm.go(to: page) }
        }
    }
}
