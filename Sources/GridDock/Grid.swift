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
    /// pleasant shape on this screen; a shorter last row is stretched to the full width.
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
        let rows = Int(ceil(Double(n) / Double(best.cols)))
        var cells: [CGRect] = []
        for r in 0..<rows {
            let inRow = min(best.cols, n - r * best.cols)
            for c in 0..<inRow {
                cells.append(CGRect(x: CGFloat(c) / CGFloat(inRow), y: CGFloat(r) / CGFloat(rows),
                                    width: 1 / CGFloat(inRow), height: 1 / CGFloat(rows)))
            }
        }
        return GridLayout(name: "Auto (\(n))", cells: cells)
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
