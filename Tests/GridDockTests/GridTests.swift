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
