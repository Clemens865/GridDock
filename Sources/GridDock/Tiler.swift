import AppKit

/// Connects the tile model to real windows. When a tiled window starts moving or resizing, it reads
/// the windows on that screen into a `Tile` tree; while the gesture goes on, the overlay shows
/// the frame every window would get; when it ends, every window is placed.
final class Tiler {
    static let shared = Tiler()

    private let enabledKey = "smartTiling", sharedKey = "sharedGrid"
    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
    /// Size every column by the windows side by side in it, so edges line up as one grid.
    var sharedGrid: Bool {
        get { UserDefaults.standard.bool(forKey: sharedKey) }
        set { UserDefaults.standard.set(newValue, forKey: sharedKey) }
    }

    init() {
        UserDefaults.standard.register(defaults: [enabledKey: true, sharedKey: true])
    }

    enum Kind { case move, resize }

    private struct Session {
        let kind: Kind
        let screen: NSScreen
        let windows: [AXWindow]      // key = index
        let tree: Tile
        let src: Int
        let start: CGRect            // its cell in the tree, normalized
        let original: CGRect         // its frame before the gesture (AX)
    }
    private var session: Session?
    private var plan: TileGestures.Plan?
    private var token = 0

    /// True once the windows are read and the gesture can be previewed.
    var isReady: Bool { session != nil }

    // MARK: Screen ↔ normalized

    static func normalized(_ f: CGRect, on screen: NSScreen) -> CGRect {
        let vf = ScreenGeometry.flip(screen.visibleFrame)
        return CGRect(x: (f.minX - vf.minX) / vf.width, y: (f.minY - vf.minY) / vf.height,
                      width: f.width / vf.width, height: f.height / vf.height)
    }

    // MARK: Gesture

    /// Reads the windows around `w` (off the main thread: asking every app can be slow). The preview
    /// starts once that is done; until then, or when the windows don't form a tiling, nothing happens.
    func begin(_ kind: Kind, window w: AXWindow, startFrame: CGRect) {
        cancel()
        guard enabled else { return }
        token += 1
        let mine = token
        let screen = ScreenGeometry.screen(containingAX: CGPoint(x: startFrame.midX, y: startFrame.midY))
        let layout = GridManager.shared.layout
        Task.detached(priority: .userInitiated) {
            let others = AX.visibleWindows().filter { !$0.isSame(w) && Rules.tiles($0) }
                .compactMap { o in o.frame.map { (o, $0) } }
            DispatchQueue.main.async {
                guard mine == self.token else { return }
                let area = ScreenGeometry.flip(screen.frame)
                let here = others.filter { area.contains(CGPoint(x: $0.1.midX, y: $0.1.midY)) }
                if let s = Self.tiled(w, startFrame, here, layout: layout, on: screen, kind: kind) {
                    self.session = s
                    Log.write("tiler: \(kind) with \(s.windows.count) tiled windows")
                } else if kind == .move, let s = Self.fresh(w, startFrame, here, on: screen, kind: kind) {
                    self.session = s
                    Log.write("tiler: move with \(s.windows.count) untiled windows, starting from an auto grid")
                } else {
                    Log.write("tiler: \(kind) skipped, \(here.count + 1) windows don't form a tiling")
                }
            }
        }
    }

    /// The windows as they sit on the grid now, when they form a tiling.
    private static func tiled(_ w: AXWindow, _ startFrame: CGRect, _ others: [(AXWindow, CGRect)],
                              layout: GridLayout, on screen: NSScreen, kind: Kind) -> Session? {
        guard let cells = GapFill.snappedCells(startFrame, layout: layout, on: screen),
              let r = layout.bounds(of: cells) else { return nil }
        var windows = [w], rects: [Int: CGRect] = [0: r]
        for (o, f) in others {
            guard let c = GapFill.snappedCells(f, layout: layout, on: screen), let q = layout.bounds(of: c),
                  !rects.values.contains(where: { $0.intersection(q).width * $0.intersection(q).height > 0.001 })
            else { return nil }                            // off the grid, or stacked on another window
            rects[windows.count] = q
            windows.append(o)
        }
        guard let tree = Tile.build(rects) else { return nil }
        return Session(kind: kind, screen: screen, windows: windows, tree: tree, src: 0, start: r, original: startFrame)
    }

    /// Windows that aren't tiled yet (free-floating, or a Stage Manager stage): start from an auto
    /// grid in their on-screen reading order. The preview shows the whole result before the drop.
    private static func fresh(_ w: AXWindow, _ startFrame: CGRect, _ others: [(AXWindow, CGRect)],
                              on screen: NSScreen, kind: Kind) -> Session? {
        let all = ([(w, startFrame)] + others).map { ($0.0, normalized($0.1, on: screen)) }
            .sorted { a, b in
                let ra = Int(a.1.midY * 2), rb = Int(b.1.midY * 2)
                return ra != rb ? ra < rb : a.1.midX < b.1.midX
            }
        let vf = screen.visibleFrame
        let auto = GridLayout.auto(count: all.count, screenAspect: vf.width / max(vf.height, 1))
        let rects = Dictionary(uniqueKeysWithValues: auto.cells.enumerated().map { ($0.offset, $0.element) })
        guard let tree = Tile.build(rects), let src = all.firstIndex(where: { $0.0.isSame(w) }) else { return nil }
        return Session(kind: kind, screen: screen, windows: all.map(\.0), tree: tree, src: src, start: auto.cells[src], original: startFrame)
    }

    private func name(_ s: Session) -> (Int) -> String {
        { i in s.windows.indices.contains(i) ? s.windows[i].appName : "?" }
    }

    /// Moving: the cursor is at `p` (AX coordinates).
    func move(to p: CGPoint) {
        guard let s = session, s.kind == .move else { return }
        let r = Self.normalized(CGRect(origin: p, size: .zero), on: s.screen)
        plan = TileGestures.drop(s.tree.copy(), moving: s.src, at: r.origin, shared: sharedGrid, name: name(s))
        preview()
    }

    /// Resizing: the window's frame is now `f` (AX coordinates).
    func resize(to f: CGRect) {
        guard let s = session, s.kind == .resize else { return }
        plan = TileGestures.resize(s.tree.copy(), window: s.src, from: s.start, to: Self.normalized(f, on: s.screen),
                                   shared: sharedGrid, name: name(s))
        preview()
    }

    private func preview() {
        guard let s = session else { return }
        guard let t = plan?.tree else {
            OverlayController.shared.showPreview([], caption: plan?.text ?? "", on: s.screen)
            return
        }
        let ghosts = t.solve().rects.map { k, r in
            OverlayView.Ghost(frame: ScreenGeometry.frame(for: r, on: s.screen),
                              role: k == s.src ? .target : k == plan?.partner ? .partner : .other,
                              label: k == s.src || k == plan?.partner ? s.windows[k].appName : nil)
        }
        OverlayController.shared.showPreview(ghosts, caption: plan?.text ?? "", on: s.screen)
    }

    /// Ends the gesture: places every window as previewed, or puts the moved window back.
    /// Returns false when there was no session (the caller falls back to plain cell snapping).
    @discardableResult
    func finish() -> Bool {
        defer { cancel() }
        guard let s = session else { return false }
        Log.write("tiler: finish \(plan?.rule.rawValue ?? "no plan")")
        guard let t = plan?.tree else {
            s.windows[s.src].setFrame(s.original)
            return true
        }
        let rects = t.solve().rects
        let order = rects.keys.sorted { a, b in
            let ra = rects[a]!, rb = rects[b]!
            return abs(ra.minY - rb.minY) > 0.01 ? ra.minY < rb.minY : ra.minX < rb.minX
        }
        let layout = GridLayout(name: "Custom", cells: order.map { rects[$0]! })
        PageManager.shared.adopt(layout, windows: order.map { s.windows[$0] }, on: s.screen)
        return true
    }

    func cancel() {
        token += 1
        session = nil
        plan = nil
    }
}
