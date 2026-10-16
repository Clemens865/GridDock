import XCTest
@testable import GridDock

final class GridTests: XCTestCase {
    /// Rows of the auto grid, top to bottom, as window counts.
    private func rowShape(_ n: Int) -> [Int] {
        let layout = GridLayout.auto(count: n, screenAspect: 16.0 / 10.0)
        let rows = Dictionary(grouping: layout.cells) { ($0.minY * 1000).rounded() }
        return rows.keys.sorted().map { rows[$0]!.count }
    }

    func testAutoGridShapes() {
        XCTAssertEqual(rowShape(1), [1])
        XCTAssertEqual(rowShape(2), [2])
        XCTAssertEqual(rowShape(3), [3])
        XCTAssertEqual(rowShape(4), [2, 2])
        XCTAssertEqual(rowShape(5), [3, 2])
        XCTAssertEqual(rowShape(7), [4, 3])
        XCTAssertEqual(rowShape(9), [3, 3, 3])
    }

    func testAutoGridCoversScreenWithoutOverlap() {
        for n in 1...16 {
            let cells = GridLayout.auto(count: n).cells
            XCTAssertEqual(cells.count, n)
            let area = cells.reduce(0) { $0 + $1.width * $1.height }
            XCTAssertEqual(area, 1, accuracy: 0.0001, "auto(\(n)) should fill the screen exactly")
            for i in cells.indices { for j in cells.indices where i < j {
                XCTAssertLessThan(cells[i].intersection(cells[j]).width * cells[i].intersection(cells[j]).height, 0.0001)
            } }
        }
    }

    func testResolveNames() {
        XCTAssertEqual(GridLayout.resolve("3 × 2")?.cells.count, 6)
        XCTAssertEqual(GridLayout.resolve("5x3")?.cells.count, 15)
        XCTAssertEqual(GridLayout.resolve("Main + 4")?.cells.count, 5)
        XCTAssertEqual(GridLayout.resolve("Auto (7)")?.cells.count, 7)
        XCTAssertNil(GridLayout.resolve("13x2"))
        XCTAssertNil(GridLayout.resolve("nonsense"))
    }

    func testBalancedChunks() {
        XCTAssertEqual(GridLayout.balancedChunks(Array(1...14), perPage: 6).map(\.count), [5, 5, 4])
        XCTAssertEqual(GridLayout.balancedChunks(Array(1...6), perPage: 6).map(\.count), [6])
        XCTAssertEqual(GridLayout.balancedChunks(Array(1...7), perPage: 6).map(\.count), [4, 3])
        XCTAssertEqual(GridLayout.balancedChunks(Array(1...14), perPage: 6).flatMap { $0 }, Array(1...14))
        XCTAssertTrue(GridLayout.balancedChunks([Int](), perPage: 6).isEmpty)
    }

    func testCellKeys() {
        XCTAssertEqual(CellKeys.label(0), "1")
        XCTAssertEqual(CellKeys.label(9), "0")
        XCTAssertEqual(CellKeys.label(10), "A")
        XCTAssertEqual(CellKeys.index(for: "a"), 10)
        XCTAssertEqual(CellKeys.index(for: "0"), 9)
        XCTAssertNil(CellKeys.index(for: "#"))
    }
}

final class ProjectNameTests: XCTestCase {
    func testProjectNames() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(AutoArrange.projectName(forPath: home + "/Documents/Software-Projects/TaxMex"), "TaxMex")
        XCTAssertEqual(AutoArrange.projectName(forPath: home + "/Documents/Software-Projects/Atelier/packages/app"), "Atelier")
        XCTAssertEqual(AutoArrange.projectName(forPath: "/tmp/scratch"), "scratch")
        XCTAssertNil(AutoArrange.projectName(forPath: home))
        XCTAssertNil(AutoArrange.projectName(forPath: ""))
    }
}

final class DragSnapTests: XCTestCase {
    private let start = CGRect(x: 100, y: 100, width: 800, height: 600)

    func testWindowMoveIsDetected() {
        let moved = start.offsetBy(dx: 30, dy: 10)
        XCTAssertEqual(DragSnap.classify(start: start, now: moved, mouseTravel: 32), .windowMove)
    }

    func testClickOnToolbarOrMenuIsNotAMove() {
        // Cursor wiggles a few pixels, window stays put: keep waiting, don't show the grid.
        XCTAssertEqual(DragSnap.classify(start: start, now: start, mouseTravel: 8), .undecided)
        // Long drag inside the window (text selection, tab drag, menu tracking): never a move.
        XCTAssertEqual(DragSnap.classify(start: start, now: start, mouseTravel: 120), .other)
    }

    func testResizeIsNotAMove() {
        let resized = CGRect(x: 80, y: 100, width: 820, height: 600)
        XCTAssertEqual(DragSnap.classify(start: start, now: resized, mouseTravel: 20), .resize)
    }
}

final class GapFillTests: XCTestCase {
    private let grid = GridLayout.uniform("3 × 2", cols: 3, rows: 2)

    func testWindowAboveGrowsIntoEmptyCell() {
        // Your screenshot: 5 windows in 3 × 2, bottom-right empty → top-right grows down.
        let spans: [Set<Int>] = [[0], [1], [2], [3], [4]]
        XCTAssertEqual(grid.filling(spans), [[0], [1], [2, 5], [3], [4]])
    }

    func testLeftNeighbourGrowsWhenNothingAbove() {
        let spans: [Set<Int>] = [[0, 3], [1, 4], [2]]
        XCTAssertEqual(grid.filling(spans)[2], [2, 5])
        let bottom: [Set<Int>] = [[0, 1, 2], [3], [4]]
        XCTAssertEqual(grid.filling(bottom), [[0, 1, 2], [3], [4, 5]])
    }

    func testBlockedCellsAndNonRectanglesStayEmpty() {
        let spans: [Set<Int>] = [[0], [1], [2], [3], [4]]
        XCTAssertEqual(grid.filling(spans, blocked: [5]), spans)
        // Cell 1 is empty; the tall windows beside it can't take it and stay rectangles, so the one below does.
        let tall: [Set<Int>] = [[0, 3], [2, 5], [4]]
        XCTAssertEqual(grid.filling(tall), [[0, 3], [2, 5], [4, 1]])
    }

    func testAutoGridHasNoHoles() {
        for n in 1...12 {
            let layout = GridLayout.auto(count: n, screenAspect: 16.0 / 10.0)
            let area = layout.cells.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
            XCTAssertEqual(area, 1, accuracy: 1e-6, "auto(\(n)) leaves a hole")
        }
    }
}

final class TilingTests: XCTestCase {
    // 1 = TL, 2 = BL, 3 = TR, 4 = BR
    private func twoByTwo() -> Tile {
        Tile(.h, [Tile(.v, [Tile(win: 1), Tile(win: 2)]), Tile(.v, [Tile(win: 3), Tile(win: 4)])])
    }
    private func assertRect(_ r: CGRect?, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, line: UInt = #line) {
        guard let r else { return XCTFail("missing", line: line) }
        XCTAssertEqual(r.minX, x, accuracy: 0.01, line: line); XCTAssertEqual(r.minY, y, accuracy: 0.01, line: line)
        XCTAssertEqual(r.width, w, accuracy: 0.01, line: line); XCTAssertEqual(r.height, h, accuracy: 0.01, line: line)
    }

    func testPullingTopRightDownPushesThrough() {
        // Your 2 × 2 example: pull the top-right window's bottom edge down to the bottom.
        let t = twoByTwo()
        let start = CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5), now = CGRect(x: 0.5, y: 0, width: 0.5, height: 0.95)
        let plan = TileGestures.resize(t, window: 3, from: start, to: now, shared: true, name: { "\($0)" })!
        XCTAssertEqual(plan.rule, .takeover)
        let r = plan.tree!.solve().rects
        assertRect(r[1], 0, 0, 2.0 / 3, 0.5)
        assertRect(r[2], 0, 0.5, 1.0 / 3, 0.5)
        assertRect(r[4], 1.0 / 3, 0.5, 1.0 / 3, 0.5)
        assertRect(r[3], 2.0 / 3, 0, 1.0 / 3, 1)
    }

    func testResizeMovesSharedBoundaryAndSnaps() {
        let plan = TileGestures.resize(twoByTwo(), window: 1, from: CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
                                       to: CGRect(x: 0, y: 0, width: 0.65, height: 0.5), shared: true, name: { "\($0)" })!
        XCTAssertEqual(plan.rule, .resize)
        let r = plan.tree!.solve().rects
        assertRect(r[1], 0, 0, 2.0 / 3, 0.5)          // snapped to ⅔
        assertRect(r[2], 0, 0.5, 2.0 / 3, 0.5)        // the whole column follows
        assertRect(r[3], 2.0 / 3, 0, 1.0 / 3, 0.5)
    }

    func testDropRules() {
        let name = { (i: Int) in "\(i)" }
        let edge = TileGestures.drop(twoByTwo(), moving: 4, at: CGPoint(x: 0.99, y: 0.5), shared: true, name: name)
        XCTAssertEqual(edge.rule, .edge)
        assertRect(edge.tree!.solve().rects[4], 2.0 / 3, 0, 1.0 / 3, 1)
        let swap = TileGestures.drop(twoByTwo(), moving: 4, at: CGPoint(x: 0.25, y: 0.25), shared: true, name: name)
        XCTAssertEqual(swap.rule, .swap)
        assertRect(swap.tree!.solve().rects[4], 0, 0, 0.5, 0.5)
        let split = TileGestures.drop(twoByTwo(), moving: 3, at: CGPoint(x: 0.25, y: 0.45), shared: true, name: name)
        XCTAssertEqual(split.rule, .split)
        assertRect(split.tree!.solve().rects[3], 0, 1.0 / 3, 0.5, 1.0 / 3)
        let back = TileGestures.drop(twoByTwo(), moving: 3, at: CGPoint(x: 0.75, y: 0.25), shared: true, name: name)
        XCTAssertEqual(back.rule, .cancel)
    }

    func testBuildFromFrames() {
        let rects: [Int: CGRect] = [1: CGRect(x: 0, y: 0, width: 2.0 / 3, height: 0.5), 2: CGRect(x: 0, y: 0.5, width: 1.0 / 3, height: 0.5),
                                    4: CGRect(x: 1.0 / 3, y: 0.5, width: 1.0 / 3, height: 0.5), 3: CGRect(x: 2.0 / 3, y: 0, width: 1.0 / 3, height: 1)]
        let t = Tile.build(rects)!
        for (k, r) in t.solve().rects { assertRect(r, rects[k]!.minX, rects[k]!.minY, rects[k]!.width, rects[k]!.height) }
        XCTAssertNil(Tile.build([1: CGRect(x: 0, y: 0, width: 0.6, height: 0.6), 2: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)]))
    }
}
