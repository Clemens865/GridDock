import AppKit

/// GridDock pages: several grids on the same macOS desktop. Windows of hidden pages are parked
/// off-screen, so you can swipe between page-sized groups of windows without macOS Spaces
/// (which no public API can move windows between).
final class PageManager {
    static let shared = PageManager()

    struct Slot { let window: AXWindow; let cells: [Int] }
    struct Page { var layout: GridLayout; var slots: [Slot] }

    private(set) var pages: [Page] = []
    private(set) var current = 0
    /// Windows of the visible page in cell order (kept up to date by tiling, switching and auto-arrange).
    private(set) var currentWindows: [AXWindow] = []
    private var scrollAccum: CGFloat = 0
    private var swipeFired = false
    private var monitor: Any?

    private init() {
        pages = [Page(layout: GridManager.shared.layout, slots: [])]
    }

    var pageCount: Int { pages.count }

    /// Window count per page (live for the current page, stored for the others).
    func windowCount(of index: Int) -> Int {
        guard pages.indices.contains(index) else { return 0 }
        if index == current {
            return GridManager.shared.occupancy(on: activeScreen).values.reduce(0) { $0 + $1.count }
        }
        return pages[index].slots.count
    }

    private var activeScreen: NSScreen { ScreenGeometry.screen(containingAX: ScreenGeometry.mouseAX) }

    // MARK: Switching

    /// Records what is in the current page's cells, then parks those windows off-screen.
    private func stashCurrent(on screen: NSScreen) {
        let occupancy = GridManager.shared.occupancy(on: screen)
        var slots: [Slot] = []
        for (cell, wins) in occupancy {
            for w in wins { slots.append(Slot(window: w, cells: [cell])) }
        }
        pages[current].layout = GridManager.shared.layout
        pages[current].slots = slots
        let park = ScreenGeometry.parkingPoint(on: screen)
        for s in slots {
            guard let size = s.window.frame?.size else { continue }
            s.window.setFrame(CGRect(origin: park, size: size))
        }
    }

    private func show(_ index: Int, on screen: NSScreen) {
        current = index
        GridManager.shared.layout = pages[index].layout
        let alive = pages[index].slots.filter { $0.window.frame != nil }   // drop closed windows
        pages[index].slots = alive
        for s in alive { GridManager.shared.place(s.window, inCells: s.cells, on: screen) }
        currentWindows = alive.sorted { ($0.cells.first ?? 0) < ($1.cells.first ?? 0) }.map(\.window)
        alive.last?.window.focus()
        PageHUD.shared.flash()
    }

    func go(to index: Int) {
        guard pages.indices.contains(index), index != current else { return }
        let screen = activeScreen
        stashCurrent(on: screen)
        // Empty pages you leave behind disappear (except the last remaining one).
        let leaving = current
        show(index, on: screen)
        if pages[leaving].slots.isEmpty && pages.count > 1 {
            pages.remove(at: leaving)
            if leaving < current { current -= 1 }
            PageHUD.shared.flash()
        }
    }

    func next() { current + 1 < pages.count ? go(to: current + 1) : PageHUD.shared.flash() }
    func previous() { current > 0 ? go(to: current - 1) : PageHUD.shared.flash() }

    /// Adds an empty page after the current one (same grid) and switches to it.
    func newPage() {
        let screen = activeScreen
        stashCurrent(on: screen)
        pages.insert(Page(layout: GridManager.shared.layout, slots: []), at: current + 1)
        current += 1
        currentWindows = []
        PageHUD.shared.flash()
    }

    /// Moves the focused window onto the neighbouring page (creating it if needed), into its first free cell.
    func sendFocused(forward: Bool) {
        guard let w = AX.focusedWindow(), let size = w.frame?.size else { NSSound.beep(); return }
        let screen = activeScreen
        var target = current + (forward ? 1 : -1)
        if target < 0 { NSSound.beep(); return }
        if target >= pages.count {
            pages.append(Page(layout: GridManager.shared.layout, slots: []))
            target = pages.count - 1
        }
        pages[target].slots.removeAll { $0.window.isSame(w) }
        let used = Set(pages[target].slots.flatMap(\.cells))
        let free = pages[target].layout.cells.indices.first { !used.contains($0) }
        if let free {
            pages[target].slots.append(Slot(window: w, cells: [free]))
        } else {
            // Page is full: grow it into an auto grid with room for one more.
            let n = pages[target].slots.count + 1
            pages[target].layout = .auto(count: n, screenAspect: ScreenGeometry.mainAspect)
            pages[target].slots = (pages[target].slots.map(\.window) + [w]).enumerated().map { Slot(window: $1, cells: [$0]) }
        }
        w.setFrame(CGRect(origin: ScreenGeometry.parkingPoint(on: screen), size: size))
        PageHUD.shared.flash(message: "Sent to page \(target + 1)")
    }

    // MARK: Tile all

    /// Puts every visible window on this screen into an auto-sized grid, however many there are.
    func tileAll() {
        let screen = activeScreen
        let gm = GridManager.shared
        let screenAX = ScreenGeometry.flip(screen.frame)
        // Keep windows already in cells in their order, then add the rest.
        let occ = gm.occupancy(on: screen)
        var ordered = occ.keys.sorted().flatMap { occ[$0] ?? [] }
        for w in AX.visibleWindows() where !ordered.contains(where: { $0.isSame(w) }) {
            if let f = w.frame, screenAX.contains(CGPoint(x: f.midX, y: f.midY)) { ordered.append(w) }
        }
        guard !ordered.isEmpty else { NSSound.beep(); return }
        tile(ordered, on: screen)
        PageHUD.shared.flash()
    }

    /// Lays out exactly these windows on the visible page in an auto-sized grid.
    func tile(_ windows: [AXWindow], on screen: NSScreen? = nil) {
        let screen = screen ?? activeScreen
        let gm = GridManager.shared
        currentWindows = windows
        guard !windows.isEmpty else { return }
        let vf = screen.visibleFrame
        gm.layout = .auto(count: windows.count, screenAspect: vf.width / max(vf.height, 1))
        for (i, w) in windows.enumerated() { gm.place(w, inCells: [i], on: screen) }
    }

    /// Replaces all pages: group 0 is shown, the others are parked off-screen.
    func rebuild(_ groups: [[AXWindow]]) {
        let screen = activeScreen
        let park = ScreenGeometry.parkingPoint(on: screen)
        let aspect = screen.visibleFrame.width / max(screen.visibleFrame.height, 1)
        pages = groups.map { g in
            Page(layout: .auto(count: g.count, screenAspect: aspect),
                 slots: g.enumerated().map { Slot(window: $1, cells: [$0]) })
        }
        if pages.isEmpty { pages = [Page(layout: GridManager.shared.layout, slots: [])] }
        current = 0
        for g in groups.dropFirst() {
            for w in g { if let size = w.frame?.size { w.setFrame(CGRect(origin: park, size: size)) } }
        }
        tile(groups.first ?? [], on: screen)
        PageHUD.shared.flash()
    }

    /// Puts a window on a page that still has room (or a new page) and returns that page's index.
    func addToPageWithRoom(_ w: AXWindow, max perPage: Int) -> Int {
        let screen = activeScreen
        let candidates = pages.indices.filter { $0 != current && pages[$0].slots.count < perPage }
        let target: Int
        if let i = candidates.first(where: { $0 > current }) ?? candidates.first {
            target = i
        } else {
            pages.append(Page(layout: GridManager.shared.layout, slots: []))
            target = pages.count - 1
        }
        let wins = pages[target].slots.sorted { ($0.cells.first ?? 0) < ($1.cells.first ?? 0) }.map(\.window) + [w]
        pages[target].layout = .auto(count: wins.count, screenAspect: ScreenGeometry.mainAspect)
        pages[target].slots = wins.enumerated().map { Slot(window: $1, cells: [$0]) }
        if let size = w.frame?.size { w.setFrame(CGRect(origin: ScreenGeometry.parkingPoint(on: screen), size: size)) }
        return target
    }

    // MARK: Swipe (⌥ + two-finger horizontal swipe)

    func startSwipeMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] e in self?.handleScroll(e) }
    }

    private func handleScroll(_ e: NSEvent) {
        if e.phase == .began || e.phase == .mayBegin { scrollAccum = 0; swipeFired = false }
        if e.phase == .ended || e.phase == .cancelled { scrollAccum = 0; swipeFired = false; return }
        guard e.modifierFlags.contains(.option), e.momentumPhase == [], !swipeFired,
              abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) else { return }
        // Normalise for "natural scrolling" so fingers-left always means next page.
        let dx = e.isDirectionInvertedFromDevice ? e.scrollingDeltaX : -e.scrollingDeltaX
        scrollAccum += dx
        if abs(scrollAccum) > 60 {
            swipeFired = true
            DispatchQueue.main.async { self.scrollAccum < 0 ? self.next() : self.previous() }
        }
    }

    // MARK: Safety

    /// Brings back every parked window (on quit, or after a crash left windows off-screen).
    func unparkAll() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let vf = ScreenGeometry.flip(screen.visibleFrame)
        var offset: CGFloat = 0
        for w in AX.allWindows() {
            guard let f = w.frame, ScreenGeometry.isParked(f) else { continue }
            let size = CGSize(width: min(f.width, vf.width * 0.6), height: min(f.height, vf.height * 0.6))
            w.setFrame(CGRect(origin: CGPoint(x: vf.minX + 60 + offset, y: vf.minY + 40 + offset), size: size))
            offset += 30
        }
        pages = [Page(layout: GridManager.shared.layout, slots: [])]
        current = 0
        currentWindows = []
    }
}

/// Small transient indicator: "Page 2 / 3 · Auto (7)".
final class PageHUD {
    static let shared = PageHUD()
    private var panel: NSPanel?
    private var label: NSTextField?
    private var hideWork: DispatchWorkItem?

    func flash(message: String? = nil) {
        let pm = PageManager.shared
        let dots = (0..<pm.pageCount).map { $0 == pm.current ? "●" : "○" }.joined(separator: " ")
        let text = message ?? "\(dots)    Page \(pm.current + 1) / \(pm.pageCount)  ·  \(GridManager.shared.layout.name)"
        if panel == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.level = .statusBar
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let bg = NSVisualEffectView()
            bg.material = .hudWindow
            bg.state = .active
            bg.wantsLayer = true
            bg.layer?.cornerRadius = 12
            let l = NSTextField(labelWithString: "")
            l.font = .systemFont(ofSize: 15, weight: .semibold)
            l.alignment = .center
            l.translatesAutoresizingMaskIntoConstraints = false
            bg.addSubview(l)
            NSLayoutConstraint.activate([l.centerXAnchor.constraint(equalTo: bg.centerXAnchor),
                                         l.centerYAnchor.constraint(equalTo: bg.centerYAnchor)])
            p.contentView = bg
            panel = p; label = l
        }
        label?.stringValue = text
        let width = (label?.intrinsicContentSize.width ?? 200) + 48
        let screen = ScreenGeometry.screen(containingAX: ScreenGeometry.mouseAX)
        let vf = screen.visibleFrame
        panel?.setFrame(CGRect(x: vf.midX - width / 2, y: vf.minY + 40, width: width, height: 44), display: true)
        panel?.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.panel?.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }
}
