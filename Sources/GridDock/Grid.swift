import AppKit

/// A grid layout: a list of cells in normalized coordinates (0...1, origin top-left).
struct GridLayout: Codable, Equatable {
    var name: String
    var cells: [CGRect]

    static func uniform(_ name: String, cols: Int, rows: Int) -> GridLayout {
        var cells: [CGRect] = []
        for r in 0..<rows {
            for c in 0..<cols {
                cells.append(CGRect(x: CGFloat(c) / CGFloat(cols),
                                    y: CGFloat(r) / CGFloat(rows),
                                    width: 1 / CGFloat(cols),
                                    height: 1 / CGFloat(rows)))
            }
        }
        return GridLayout(name: name, cells: cells)
    }

    /// Grid sized for `count` windows: picks the column count whose cells are closest to a
    /// pleasant shape on this screen. When the last row is short, the windows above its empty
    /// cells reach down to the bottom, so every column keeps its width and nothing is left empty.
    static func auto(count: Int, screenAspect: CGFloat = 16.0 / 10.0) -> GridLayout {
        let n = max(1, count)
        var best = (cols: 1, score: CGFloat.infinity)
        for cols in 1...n {
            let rows = Int(ceil(Double(n) / Double(cols)))
            let cellAspect = (screenAspect / CGFloat(cols)) * CGFloat(rows)
            let empty = CGFloat(cols * rows - n)
            let score = abs(log(cellAspect / 0.9)) + empty * 0.3
            if score < best.score { best = (cols, score) }
        }
        let cols = best.cols
        let rows = Int(ceil(Double(n) / Double(cols)))
        var cells: [CGRect] = []
        for k in 0..<n {
            let r = k / cols, c = k % cols
            let reachesDown = r == rows - 2 && k + cols >= n
            cells.append(CGRect(x: CGFloat(c) / CGFloat(cols), y: CGFloat(r) / CGFloat(rows),
                                width: 1 / CGFloat(cols), height: CGFloat(reachesDown ? 2 : 1) / CGFloat(rows)))
        }
        return GridLayout(name: "Auto (\(n))", cells: cells)
    }

    // MARK: Filling empty cells

    /// Bounding box of some cells (normalized coordinates).
    func bounds(of set: Set<Int>) -> CGRect? {
        let rects = set.filter { cells.indices.contains($0) }.map { cells[$0] }
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    /// True when the cells together form one solid rectangle (so one window can cover them).
    func isRectangle(_ set: Set<Int>) -> Bool {
        guard let b = bounds(of: set) else { return false }
        let area = set.reduce(CGFloat(0)) { $0 + cells[$1].width * cells[$1].height }
        return abs(area - b.width * b.height) < 1e-6
    }

    /// Grows the given spans (one per window) into empty cells, so the grid has no holes.
    /// An empty cell goes to the window above it first, then left, right, below — and only
    /// when the window still covers a rectangle afterwards. `blocked` cells are never taken.
    func filling(_ spans: [Set<Int>], blocked: Set<Int> = []) -> [Set<Int>] {
        var spans = spans
        let taken = spans.reduce(into: blocked) { $0.formUnion($1) }
        var empty = Set(cells.indices).subtracting(taken)
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 1e-6 }
        var progress = true
        while progress && !empty.isEmpty {
            progress = false
            for e in empty.sorted() {
                let c = cells[e]
                var best: (rank: Int, index: Int)?
                for (i, s) in spans.enumerated() where !s.isEmpty && isRectangle(s.union([e])) {
                    guard let b = bounds(of: s) else { continue }
                    let rank = near(b.maxY, c.minY) ? 0 : near(b.maxX, c.minX) ? 1 : near(b.minX, c.maxX) ? 2 : 3
                    if best == nil || rank < best!.rank { best = (rank, i) }
                }
                if let b = best {
                    spans[b.index].insert(e)
                    empty.remove(e)
                    progress = true
                }
            }
        }
        return spans
    }

    /// Splits items into the fewest pages of at most `perPage`, as evenly as possible (14 by 6 → 5, 5, 4).
    static func balancedChunks<T>(_ items: [T], perPage: Int) -> [[T]] {
        guard !items.isEmpty, perPage > 0 else { return [] }
        let pageCount = Int(ceil(Double(items.count) / Double(perPage)))
        let base = items.count / pageCount, extra = items.count % pageCount
        var chunks: [[T]] = []
        var i = 0
        for p in 0..<pageCount {
            let size = base + (p < extra ? 1 : 0)
            chunks.append(Array(items[i..<(i + size)]))
            i += size
        }
        return chunks
    }

    /// Rebuilds a layout from its name: presets, "C × R" custom grids and "Auto (n)".
    static func resolve(_ name: String) -> GridLayout? {
        if let p = presets.first(where: { $0.name == name }) { return p }
        let digits = name.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        if name.hasPrefix("Auto"), let n = digits.first { return auto(count: n, screenAspect: ScreenGeometry.mainAspect) }
        if digits.count == 2, (1...12).contains(digits[0]), (1...12).contains(digits[1]) {
            return uniform("\(digits[0]) × \(digits[1])", cols: digits[0], rows: digits[1])
        }
        return nil
    }

    static let presets: [GridLayout] = [
        .uniform("2 × 1", cols: 2, rows: 1),
        .uniform("2 × 2", cols: 2, rows: 2),
        .uniform("3 × 2", cols: 3, rows: 2),
        .uniform("3 × 3", cols: 3, rows: 3),
        .uniform("4 × 2", cols: 4, rows: 2),
        GridLayout(name: "Main + 2", cells: [
            CGRect(x: 0, y: 0, width: 0.5, height: 1),
            CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
            CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
        ]),
        GridLayout(name: "Main + 4", cells: [
            CGRect(x: 0, y: 0, width: 0.5, height: 1),
            CGRect(x: 0.5, y: 0, width: 0.25, height: 0.5),
            CGRect(x: 0.75, y: 0, width: 0.25, height: 0.5),
            CGRect(x: 0.5, y: 0.5, width: 0.25, height: 0.5),
            CGRect(x: 0.75, y: 0.5, width: 0.25, height: 0.5),
        ]),
        GridLayout(name: "Center + sides", cells: [
            CGRect(x: 0, y: 0, width: 0.25, height: 1),
            CGRect(x: 0.25, y: 0, width: 0.5, height: 1),
            CGRect(x: 0.75, y: 0, width: 0.25, height: 1),
        ]),
    ]
}

enum ScreenGeometry {
    static let gap: CGFloat = 8

    /// Height of the primary screen; AX coordinates have their origin at its top-left.
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// Converts an AppKit (bottom-left origin) rect to AX/CG (top-left origin) coordinates, and back.
    static func flip(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// Absolute AX-coordinate frame for a cell on a screen, with gaps applied.
    static func frame(for cell: CGRect, on screen: NSScreen) -> CGRect {
        let vf = flip(screen.visibleFrame)
        let g = gap
        var r = CGRect(x: vf.minX + cell.minX * vf.width,
                       y: vf.minY + cell.minY * vf.height,
                       width: cell.width * vf.width,
                       height: cell.height * vf.height)
        r = r.insetBy(dx: g / 2, dy: g / 2)
        // Outer edges get a full gap
        if cell.minX == 0 { r.origin.x += g / 2; r.size.width -= g / 2 }
        if cell.maxX >= 0.999 { r.size.width -= g / 2 }
        if cell.minY == 0 { r.origin.y += g / 2; r.size.height -= g / 2 }
        if cell.maxY >= 0.999 { r.size.height -= g / 2 }
        return r.integral
    }

    /// Screen under a point given in AX coordinates.
    static func screen(containingAX p: CGPoint) -> NSScreen {
        NSScreen.screens.first { flip($0.frame).contains(p) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    static var mainAspect: CGFloat {
        guard let f = NSScreen.main?.visibleFrame, f.height > 0 else { return 16.0 / 10.0 }
        return f.width / f.height
    }

    /// Off-screen parking spot for windows on hidden pages: the window's top-left sits on the
    /// screen's bottom-right corner (macOS keeps at least a sliver of a window on screen).
    static func parkingPoint(on screen: NSScreen) -> CGPoint {
        let f = flip(screen.frame)
        return CGPoint(x: f.maxX - 1, y: f.maxY - 1)
    }

    static func isParked(_ frame: CGRect) -> Bool {
        NSScreen.screens.contains { s in
            let p = parkingPoint(on: s)
            return abs(frame.minX - p.x) < 40 && abs(frame.minY - p.y) < 40
        }
    }

    /// Mouse location in AX coordinates.
    static var mouseAX: CGPoint {
        let m = NSEvent.mouseLocation
        return CGPoint(x: m.x, y: primaryHeight - m.y)
    }
}
