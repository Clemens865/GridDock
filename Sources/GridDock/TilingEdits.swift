import CoreGraphics

/// The edits a drop or a resize makes. Edits that move a window take the tree without it.
extension Tile {
    enum Side { case left, right, top, bottom
        var dir: Dir { self == .left || self == .right ? .h : .v }
        var first: Bool { self == .left || self == .top }
    }

    /// Screen edge: the window becomes a full-height column (full-width row) on that side.
    static func edge(_ tree: Tile?, _ win: Int, _ side: Side) -> Tile {
        guard let tree else { return Tile(win: win) }
        if !tree.isLeaf && tree.dir == side.dir {
            let avg = tree.w.reduce(0, +) / CGFloat(tree.w.count)
            if side.first { tree.kids.insert(Tile(win: win), at: 0); tree.w.insert(avg, at: 0) }
            else { tree.kids.append(Tile(win: win)); tree.w.append(avg) }
            return tree
        }
        return side.first ? Tile(side.dir, [Tile(win: win), tree], [1, 2]) : Tile(side.dir, [tree, Tile(win: win)], [2, 1])
    }

    /// Gap between windows `a` and `b`: the window slots in between.
    static func between(_ tree: Tile, _ win: Int, _ a: Int, _ b: Int, _ dir: Dir) -> Tile? {
        guard let c = tree.common(a, b), c.node.dir == dir else { return nil }
        let at = max(c.ia, c.ib), avg = c.node.w.reduce(0, +) / CGFloat(c.node.w.count)
        c.node.kids.insert(Tile(win: win), at: at); c.node.w.insert(avg, at: at)
        return tree
    }

    /// Side of a window: it splits, and `win` takes the half on `side`.
    static func split(_ tree: Tile, _ win: Int, _ target: Int, _ side: Side) -> Tile? {
        guard let f = tree.locate(target) else { return nil }
        if let p = f.parent, p.dir == side.dir {
            let half = p.w[f.index] / 2
            p.w[f.index] = half
            let at = side.first ? f.index : f.index + 1
            p.kids.insert(Tile(win: win), at: at); p.w.insert(half, at: at)
            return tree
        }
        let s = Tile(side.dir, side.first ? [Tile(win: win), f.node] : [f.node, Tile(win: win)])
        guard let p = f.parent else { return s }
        p.kids[f.index] = s
        return tree
    }

    /// Middle of a window: the two trade places.
    static func swap(_ tree: Tile, _ a: Int, _ b: Int) -> Tile {
        if let fa = tree.locate(a), let fb = tree.locate(b) { fa.node.win = b; fb.node.win = a }
        return tree
    }

    /// Branch `squeezed` of split `splitID` was pushed below its minimum: the branch beside it takes
    /// its space, and each squeezed window moves in next to the window across from it in the
    /// neighbouring branch of the parent. Nil when there is no such neighbour.
    static func takeover(_ tree: Tile, _ splitID: Int, _ squeezed: Int) -> Tile? {
        guard let s = tree.find(split: splitID), let outer = tree.parent(of: splitID) else { return nil }
        let rects = tree.solve().rects
        let across = outer.parent.kids[outer.index > 0 ? outer.index - 1 : outer.index + 1]
        let horizontal = outer.parent.dir == .h
        let side: Side = outer.index > 0 ? (horizontal ? .right : .bottom) : (horizontal ? .left : .top)
        let hosts = across.leaves
        var t: Tile? = tree
        for m in s.kids[squeezed].leaves {
            guard let r = rects[m] else { continue }
            let host = hosts.first { h in
                guard let q = rects[h] else { return false }
                return horizontal ? (q.minY...q.maxY).contains(r.midY) : (q.minX...q.maxX).contains(r.midX)
            } ?? hosts[0]
            guard let rest = t?.removing(m) else { return nil }
            t = split(rest, m, host, side)
        }
        return t?.normalized()
    }

    /// A new window splits the largest one along its longer side (`aspect` = screen width / height).
    static func inserting(_ tree: Tile?, _ win: Int, aspect: CGFloat) -> Tile {
        guard let tree else { return Tile(win: win) }
        let rects = tree.solve().rects
        guard let (big, r) = rects.max(by: { $0.value.width * $0.value.height < $1.value.width * $1.value.height })
        else { return tree }
        return split(tree, win, big, r.width * aspect >= r.height ? .right : .bottom) ?? tree
    }
}
