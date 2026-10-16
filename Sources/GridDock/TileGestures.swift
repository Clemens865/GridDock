import CoreGraphics

/// Reads what a drop or a resize means and returns the layout it would produce.
/// Points and frames are normalized to the screen (0...1, top-left).
enum TileGestures {
    enum Rule: String { case edge, between, split, swap, resize, takeover, cancel }

    struct Plan {
        let rule: Rule
        let tree: Tile?          // nil: nothing changes
        var partner: Int? = nil  // the other window of a swap
        let text: String
    }

    static let edgeZone: CGFloat = 0.04       // drop this close to a screen edge → new column / row
    static let lineZone: CGFloat = 0.022      // this close to a gap → slot in between
    static let minSize: CGFloat = 0.1         // squeezing a side below this pushes through
    static let snaps: [CGFloat] = [1 / 4, 1 / 3, 1 / 2, 2 / 3, 3 / 4]

    static func tidy(_ t: Tile?, shared: Bool) -> Tile? {
        guard let n = t?.normalized() else { return nil }
        return shared ? n.balanced() : n
    }

    private static func window(at p: CGPoint, in rects: [Int: CGRect]) -> Int? {
        rects.first { $0.value.insetBy(dx: -0.001, dy: -0.001).contains(p) }?.key
    }

    // MARK: Moving a window

    static func drop(_ tree: Tile, moving src: Int, at p: CGPoint, shared: Bool, name: (Int) -> String) -> Plan {
        let (rects, bounds) = tree.solve()
        guard (0...1).contains(p.x), (0...1).contains(p.y) else { return Plan(rule: .cancel, tree: nil, text: "Off the screen: nothing changes") }
        let rest = { tree.copy().removing(src) }

        // Screen edge
        let edges: [(Tile.Side, CGFloat)] = [(.left, p.x), (.right, 1 - p.x), (.top, p.y), (.bottom, 1 - p.y)]
        if let (side, d) = edges.min(by: { $0.1 < $1.1 }), d < edgeZone {
            let what = side.dir == .h ? "full-height column" : "full-width row"
            return Plan(rule: .edge, tree: tidy(Tile.edge(rest(), src, side), shared: shared),
                        text: "\(name(src)) becomes a \(what) on the \(side)")
        }
        // Gap between two windows
        for b in bounds {
            let along = b.dir == .h ? p.y : p.x, across = b.dir == .h ? p.x : p.y
            guard abs(across - b.at) <= lineZone, along >= b.from, along <= b.to else { continue }
            let off: CGFloat = 0.012
            let pa = b.dir == .h ? CGPoint(x: b.at - off, y: p.y) : CGPoint(x: p.x, y: b.at - off)
            let pc = b.dir == .h ? CGPoint(x: b.at + off, y: p.y) : CGPoint(x: p.x, y: b.at + off)
            guard let a = window(at: pa, in: rects), let c = window(at: pc, in: rects), a != src, c != src,
                  let r = rest(), let t = Tile.between(r, src, a, c, b.dir) else { continue }
            return Plan(rule: .between, tree: tidy(t, shared: shared),
                        text: "\(name(src)) slots in between \(name(a)) and \(name(c))")
        }
        guard let over = window(at: p, in: rects), over != src, let r = rects[over] else {
            return Plan(rule: .cancel, tree: nil, text: "Back where it was: nothing changes")
        }
        let u = (p.x - r.minX) / r.width, v = (p.y - r.minY) / r.height
        // Middle of a window
        if abs(u - 0.5) < 0.2 && abs(v - 0.5) < 0.2 {
            return Plan(rule: .swap, tree: Tile.swap(tree.copy(), src, over), partner: over,
                        text: "\(name(src)) and \(name(over)) trade places")
        }
        // Side of a window
        let sides: [(Tile.Side, CGFloat)] = [(.left, u), (.right, 1 - u), (.top, v), (.bottom, 1 - v)]
        let side = sides.min { $0.1 < $1.1 }!.0
        guard let base = rest(), let t = Tile.split(base, src, over, side) else {
            return Plan(rule: .cancel, tree: nil, text: "Nothing changes")
        }
        return Plan(rule: .split, tree: tidy(t, shared: shared), text: "\(name(over)) splits; \(name(src)) takes its \(side) half")
    }

    // MARK: Resizing a window

    /// `start` and `now` are the window's frames before and during the resize. Nil when the edge
    /// that moved is an outer screen edge (nothing to share with).
    static func resize(_ tree: Tile, window win: Int, from start: CGRect, to now: CGRect, shared: Bool,
                       name: (Int) -> String) -> Plan? {
        // Which edge moved the most.
        let moves: [(dir: Tile.Dir, isMax: Bool, from: CGFloat, to: CGFloat)] = [
            (.h, false, start.minX, now.minX), (.h, true, start.maxX, now.maxX),
            (.v, false, start.minY, now.minY), (.v, true, start.maxY, now.maxY)]
        guard let m = moves.max(by: { abs($0.to - $0.from) < abs($1.to - $1.from) }), abs(m.to - m.from) > 0.004
        else { return nil }
        let rects = tree.solve().rects
        guard let mine = rects[win] else { return nil }
        let mid = m.dir == .h ? mine.midY : mine.midX
        let edgeAt = m.dir == .h ? (m.isMax ? mine.maxX : mine.minX) : (m.isMax ? mine.maxY : mine.minY)
        guard let b = tree.solve().bounds.first(where: { b in
            b.dir == m.dir && abs(b.at - edgeAt) < 0.02 && (m.isMax ? b.before : b.after).contains(win) && mid >= b.from && mid <= b.to
        }) else { return nil }

        let t = tree.copy()
        guard let s = t.find(split: b.split) else { return nil }
        let total = s.w.reduce(0, +)
        let pStart = b.dir == .h ? b.parent.minX : b.parent.minY, pSize = b.dir == .h ? b.parent.width : b.parent.height
        let startOf = { (i: Int) in pStart + pSize * s.w.prefix(i).reduce(0, +) / total }
        let lo = startOf(b.index), hi = startOf(b.index + 2), pair = s.w[b.index] + s.w[b.index + 1]
        var f = min(hi - 0.01, max(lo + 0.01, m.to))
        let snap = snaps.first { abs($0 - f) < 0.02 && $0 > lo && $0 < hi }
        if let snap { f = snap }

        let squeezed = f - lo < minSize ? b.index : hi - f < minSize ? b.index + 1 : nil
        if let squeezed, let pushed = Tile.takeover(tree.copy(), b.split, squeezed) {
            let grower = squeezed == b.index ? b.index + 1 : b.index
            let s0 = tree.find(split: b.split)!
            let g = s0.kids[grower].leaves.map(name).joined(separator: ", ")
            let moved = s0.kids[squeezed].leaves.map(name).joined(separator: ", ")
            return Plan(rule: .takeover, tree: tidy(pushed, shared: shared),
                        text: "\(g) takes the full \(b.dir == .h ? "width" : "height"); \(moved) moves in beside the window across")
        }
        s.w[b.index] = pair * (f - lo) / (hi - lo)
        s.w[b.index + 1] = pair * (hi - f) / (hi - lo)
        let label = snap.flatMap { s in snaps.firstIndex(of: s) }.map { ["¼", "⅓", "½", "⅔", "¾"][$0] }
        return Plan(rule: .resize, tree: t, text: "Boundary at \(Int((f * 100).rounded()))%" + (label.map { " · clicked into \($0)" } ?? ""))
    }
}
