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

    func arrangeEverything() {
        guard !busy, Self.checkStageManager() else { return }
        busy = true
        Task {
            defer { busy = false }
            await gatherAll()
            arrangeOnGridDesktop()
        }
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
            return screenAX.contains(CGPoint(x: f.midX, y: f.midY))
        }
        guard !wins.isEmpty else { PageHUD.shared.flash(message: "No windows to arrange"); return }

        // Keep each app's windows together (e.g. all terminals side by side).
        var order: [pid_t] = []
        for w in wins where !order.contains(w.pid) { order.append(w.pid) }
        let grouped = order.flatMap { pid in wins.filter { $0.pid == pid } }

        let pageCount = Int(ceil(Double(grouped.count) / Double(perPage)))
        let base = grouped.count / pageCount, extra = grouped.count % pageCount
        var chunks: [[AXWindow]] = []
        var i = 0
        for p in 0..<pageCount {
            let size = base + (p < extra ? 1 : 0)
            chunks.append(Array(grouped[i..<(i + size)]))
            i += size
        }
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

    private func tick() {
        guard enabled, !busy, !Self.stageManagerOn, !OverlayController.shared.isPicking, NSEvent.pressedMouseButtons == 0 else { return }
        if Spaces.isAvailable, let home = Spaces.home, Spaces.current != home { return }  // you're in a fullscreen app or elsewhere

        let pm = PageManager.shared
        let screenAX = ScreenGeometry.flip(gridScreen.frame)
        let visible = AX.visibleWindows().filter { w in
            guard let f = w.frame else { return false }
            return screenAX.contains(CGPoint(x: f.midX, y: f.midY))
        }
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
