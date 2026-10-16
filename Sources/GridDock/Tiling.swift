import CoreGraphics

/// A layout as nested splits: columns that hold stacks, stacks that hold rows, and so on.
/// Every drop or resize is one small edit of this tree, so the screen never gets holes or
/// overlaps. Windows are leaves, named by an Int key. Frames are normalized (0...1, top-left).
final class Tile {
    enum Dir { case h, v }          // h: side by side, v: stacked

    private static var nextID = 0
    let id: Int
    var win: Int?                   // set on a leaf
    var dir: Dir = .h
    var kids: [Tile] = []
    var w: [CGFloat] = []

    init(win: Int) { id = Self.newID(); self.win = win }
    init(_ dir: Dir, _ kids: [Tile], _ w: [CGFloat]? = nil) {
        id = Self.newID(); self.dir = dir; self.kids = kids; self.w = w ?? kids.map { _ in 1 }
    }
    private init(id: Int) { self.id = id }
    private static func newID() -> Int { nextID += 1; return nextID }

    var isLeaf: Bool { win != nil }
    var leaves: [Int] { win.map { [$0] } ?? kids.flatMap(\.leaves) }

    func copy() -> Tile {
        let t = Tile(id: id)
        t.win = win; t.dir = dir; t.kids = kids.map { $0.copy() }; t.w = w
        return t
    }

    // MARK: Frames

    struct Boundary {
        let split: Int, index: Int, dir: Dir
        let at: CGFloat, from: CGFloat, to: CGFloat   // position across, extent along
        let parent: CGRect
        let before: [Int], after: [Int]
    }

    func solve(in r: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> (rects: [Int: CGRect], bounds: [Boundary]) {
        var rects: [Int: CGRect] = [:], bounds: [Boundary] = []
        solve(r, &rects, &bounds)
        return (rects, bounds)
    }

    private func solve(_ r: CGRect, _ rects: inout [Int: CGRect], _ bounds: inout [Boundary]) {
        if let win { rects[win] = r; return }
        let total = w.reduce(0, +)
        var pos = dir == .h ? r.minX : r.minY
        for (i, k) in kids.enumerated() {
            let size = (dir == .h ? r.width : r.height) * w[i] / total
            let kr = dir == .h ? CGRect(x: pos, y: r.minY, width: size, height: r.height)
                               : CGRect(x: r.minX, y: pos, width: r.width, height: size)
            k.solve(kr, &rects, &bounds)
            pos += size
            if i < kids.count - 1 {
                bounds.append(Boundary(split: id, index: i, dir: dir, at: pos,
                                       from: dir == .h ? r.minY : r.minX, to: dir == .h ? r.maxY : r.maxX,
                                       parent: r, before: k.leaves, after: kids[i + 1].leaves))
            }
        }
    }

    // MARK: Finding things

    func find(split id: Int) -> Tile? {
        if self.id == id && !isLeaf { return self }
        for k in kids { if let f = k.find(split: id) { return f } }
        return nil
    }

    /// The leaf holding a window, its parent and its index there.
    func locate(_ win: Int) -> (node: Tile, parent: Tile?, index: Int)? {
        if self.win == win { return (self, nil, -1) }
        for (i, k) in kids.enumerated() {
            if k.win == win { return (k, self, i) }
            if let f = k.locate(win) { return f }
        }
        return nil
    }

    /// Parent of a split and the split's index there.
    func parent(of id: Int) -> (parent: Tile, index: Int)? {
        for (i, k) in kids.enumerated() {
            if k.id == id { return (self, i) }
            if let f = k.parent(of: id) { return f }
        }
        return nil
    }

    /// Lowest split holding both windows in different branches.
    func common(_ a: Int, _ b: Int) -> (node: Tile, ia: Int, ib: Int)? {
        guard !isLeaf, let ia = kids.firstIndex(where: { $0.leaves.contains(a) }),
              let ib = kids.firstIndex(where: { $0.leaves.contains(b) }) else { return nil }
        return ia == ib ? kids[ia].common(a, b) : (self, ia, ib)
    }

    // MARK: Tidying

    /// Drops single-child splits and merges a split into a parent going the same way.
    func normalized() -> Tile {
        if isLeaf { return self }
        var nk: [Tile] = [], nw: [CGFloat] = []
        for (i, k0) in kids.enumerated() {
            let k = k0.normalized()
            if !k.isLeaf && k.dir == dir {
                let t = k.w.reduce(0, +)
                for (j, kk) in k.kids.enumerated() { nk.append(kk); nw.append(w[i] * k.w[j] / t) }
            } else { nk.append(k); nw.append(w[i]) }
        }
        if nk.count == 1 { return nk[0] }
        kids = nk; w = nw
        return self
    }

    /// How many windows sit side by side in this branch along `d`.
    func units(_ d: Dir) -> CGFloat {
        if isLeaf { return 1 }
        let u = kids.map { $0.units(d) }
        return dir == d ? u.reduce(0, +) : u.max() ?? 1
    }

    /// "Shared grid": every branch is as wide (tall) as the windows it has side by side, so edges line up.
    @discardableResult
    func balanced() -> Tile {
        guard !isLeaf else { return self }
        kids.forEach { $0.balanced() }
        w = kids.map { $0.units(dir) }
        return self
    }

    /// The tree without a window (nil when it was the only one).
    func removing(_ win: Int) -> Tile? {
        guard let f = locate(win) else { return self }
        guard let p = f.parent else { return nil }
        p.kids.remove(at: f.index); p.w.remove(at: f.index)
        return normalized()
    }

    // MARK: Building from frames

    /// Rebuilds the tree from window frames that tile `r` (by finding lines no window crosses).
    /// Nil when the frames don't form such a tiling.
    static func build(_ rects: [Int: CGRect], in r: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> Tile? {
        if rects.count == 1, let k = rects.keys.first { return Tile(win: k) }
        guard !rects.isEmpty else { return nil }
        let tol: CGFloat = 0.01
        for dir in [Dir.h, .v] {
            let lo = { (q: CGRect) in dir == .h ? q.minX : q.minY }, hi = { (q: CGRect) in dir == .h ? q.maxX : q.maxY }
            let start = dir == .h ? r.minX : r.minY, end = dir == .h ? r.maxX : r.maxY
            var cuts = rects.values.map(lo).filter { c in
                c > start + tol && !rects.values.contains { lo($0) < c - tol && hi($0) > c + tol }
            }.sorted()
            cuts = cuts.reduce(into: []) { a, c in if a.last.map({ abs($0 - c) > tol }) ?? true { a.append(c) } }
            guard !cuts.isEmpty else { continue }
            let edges = [start] + cuts + [end]
            var kids: [Tile] = [], w: [CGFloat] = []
            for i in 0..<(edges.count - 1) {
                let part = rects.filter { lo($0.value) >= edges[i] - tol && hi($0.value) <= edges[i + 1] + tol }
                let sub = dir == .h ? CGRect(x: edges[i], y: r.minY, width: edges[i + 1] - edges[i], height: r.height)
                                    : CGRect(x: r.minX, y: edges[i], width: r.width, height: edges[i + 1] - edges[i])
                guard let k = build(part, in: sub) else { return nil }
                kids.append(k); w.append(edges[i + 1] - edges[i])
            }
            return Tile(dir, kids, w)
        }
        return nil
    }
}
