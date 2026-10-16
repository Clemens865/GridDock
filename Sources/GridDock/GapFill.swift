import AppKit

/// Keeps the grid free of holes: a window next to an empty cell grows into it (a cell freed by a
/// closed or moved window gets taken over), and a window that grew shrinks back when another
/// window is dropped onto the cell it borrowed.
final class GapFill {
    static let shared = GapFill()

    private let key = "fillEmptyCells"
    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key); if newValue { fill() } }
    }

    private var timer: Timer?
    private var scanning = false

    init() {
        UserDefaults.standard.register(defaults: [key: true])
    }

    /// Checks for holes every few seconds (closing a window sends no event we could listen to).
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.fill() }
    }

    // MARK: Which cells a window sits on

    /// Cells of which the frame covers at least `share` of the area.
    static func coveredCells(_ f: CGRect, layout: GridLayout, on screen: NSScreen, share: CGFloat) -> Set<Int> {
        Set(layout.cells.indices.filter { i in
            let c = ScreenGeometry.frame(for: layout.cells[i], on: screen)
            let x = c.intersection(f)
            return !x.isNull && x.width * x.height >= share * c.width * c.height
        })
    }

    /// The cells a window fills (one cell or a span), or nil when it isn't sitting on the grid.
    /// The tolerance lets in terminals, which round their size to whole characters.
    static func snappedCells(_ f: CGRect, layout: GridLayout, on screen: NSScreen) -> Set<Int>? {
        let covered = coveredCells(f, layout: layout, on: screen, share: 0.5)
        guard layout.isRectangle(covered), let b = layout.bounds(of: covered) else { return nil }
        let t = ScreenGeometry.frame(for: b, on: screen)
        let tol: CGFloat = 24
        guard abs(f.minX - t.minX) < tol, abs(f.minY - t.minY) < tol,
              abs(f.maxX - t.maxX) < tol, abs(f.maxY - t.maxY) < tol else { return nil }
        return covered
    }

    // MARK: Filling

    /// Looks for holes (off the main thread, since asking every app for its windows can be slow)
    /// and lets neighbours grow into them. `dropped` was just placed into `cells`.
    func fill(dropped: AXWindow? = nil, into cells: [Int] = []) {
        guard enabled, !scanning, NSEvent.pressedMouseButtons == 0, !OverlayController.shared.isPicking,
              !MainActor.assumeIsolated({ AutoArrange.shared.busy }) else { return }
        scanning = true
        let layout = GridManager.shared.layout
        let page = PageManager.shared.current
        Task.detached(priority: .userInitiated) {
            let wins = AX.visibleWindows().filter(Rules.tiles).compactMap { w in w.frame.map { (w, $0) } }
            DispatchQueue.main.async {
                self.scanning = false
                // Things changed while we looked (page switch, new grid, a drag started): try again later.
                guard self.enabled, NSEvent.pressedMouseButtons == 0, !OverlayController.shared.isPicking,
                      GridManager.shared.layout == layout, PageManager.shared.current == page else { return }
                for screen in NSScreen.screens {
                    let area = ScreenGeometry.flip(screen.frame)
                    let here = wins.filter { area.contains(CGPoint(x: $0.1.midX, y: $0.1.midY)) }
                    self.apply(here, layout: layout, on: screen, dropped: dropped, into: cells)
                }
            }
        }
    }

    private func apply(_ wins: [(AXWindow, CGRect)], layout: GridLayout, on screen: NSScreen,
                       dropped: AXWindow?, into droppedCells: [Int]) {
        let isDropped = { (w: AXWindow) in dropped.map(w.isSame) ?? false }
        let droppedHere = wins.contains { isDropped($0.0) }
        let into = droppedHere ? Set(droppedCells) : []

        var owners: [(window: AXWindow, frame: CGRect, before: Set<Int>)] = []
        var spans: [Set<Int>] = []
        var blocked = Set<Int>()
        for (w, f) in wins where !isDropped(w) {
            guard var s = Self.snappedCells(f, layout: layout, on: screen) else {
                // A window off the grid keeps the cells it overlaps; nothing grows underneath it.
                blocked.formUnion(Self.coveredCells(f, layout: layout, on: screen, share: 0.15))
                continue
            }
            let before = s
            s.subtract(into)
            if s.isEmpty { continue }                       // stacked in the drop cell: leave it be
            if !layout.isRectangle(s) { s = [s.min()!] }
            owners.append((w, f, before)); spans.append(s)
        }
        if droppedHere, let d = dropped, let f = wins.first(where: { isDropped($0.0) })?.1 {
            owners.append((d, f, into)); spans.append(into)
        }

        let after = layout.filling(spans, blocked: blocked)
        for (i, o) in owners.enumerated() where after[i] != o.before {
            // Skip a window that moved since we looked (the next round sees it where it is now).
            if !isDropped(o.window), let now = o.window.frame,
               abs(now.minX - o.frame.minX) > 2 || abs(now.minY - o.frame.minY) > 2 { continue }
            GridManager.shared.place(o.window, inCells: after[i].sorted(), on: screen)
        }
    }
}
