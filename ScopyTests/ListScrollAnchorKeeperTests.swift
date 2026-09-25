import AppKit
import XCTest

@testable import Scopy

@MainActor
final class ListScrollAnchorKeeperTests: XCTestCase {
    /// A table whose rows report the heights in `heights`, like the List's table answering with
    /// measured heights for on-screen rows and estimates for the rest.
    private final class Rows: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var heights: [CGFloat]
        init(heights: [CGFloat]) { self.heights = heights }
        func numberOfRows(in tableView: NSTableView) -> Int { heights.count }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { heights[row] }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { NSView() }
    }

    private func makeTable(rows: Rows) -> (NSScrollView, NSTableView) {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let tableView = NSTableView(frame: NSRect(x: 0, y: 0, width: 300, height: 0))
        tableView.addTableColumn(NSTableColumn(identifier: .init("c")))
        tableView.headerView = nil
        tableView.dataSource = rows
        tableView.delegate = rows
        scrollView.documentView = tableView
        tableView.reloadData()
        tableView.layoutSubtreeIfNeeded()
        return (scrollView, tableView)
    }

    func testRowUnderTheTopEdgeStaysInPlaceWhenRowsAboveChangeHeight() {
        // 200 measured rows of 43 pt; the keeper anchors to row 100 scrolled 10 pt into it.
        let rows = Rows(heights: Array(repeating: 43, count: 200))
        let (scrollView, tableView) = makeTable(rows: rows)
        let keeper = ListScrollAnchorKeeper()
        keeper.scrollView = scrollView
        let ids = (0..<200).map { _ in UUID() }
        keeper.itemID = { row in ids[row] }
        keeper.row = { id in ids.firstIndex(of: id) }
        let rowTop = tableView.rect(ofRow: 100).origin.y
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: rowTop + 10))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        keeper.projectionWillChange()
        // The table re-queries every height and the fifty rows above fall back to a 24 pt estimate.
        for row in 0..<50 { rows.heights[row] = 24 }
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(0..<50))
        tableView.layoutSubtreeIfNeeded()

        XCTAssertEqual(scrollView.contentView.bounds.origin.y, tableView.rect(ofRow: 100).origin.y + 10, accuracy: 0.5,
                       "The document frame change restores row 100 to 10 pt above the top edge")
        XCTAssertEqual(tableView.rect(ofRow: 100).origin.y, rowTop - 50 * 19, accuracy: 0.5)
    }

    func testRowShiftedByAnInsertionAboveIsFoundByItsItem() {
        let rows = Rows(heights: Array(repeating: 43, count: 200))
        let (scrollView, tableView) = makeTable(rows: rows)
        let keeper = ListScrollAnchorKeeper()
        keeper.scrollView = scrollView
        var ids = (0..<200).map { _ in UUID() }
        keeper.itemID = { row in ids[row] }
        keeper.row = { id in ids.firstIndex(of: id) }
        let anchorID = ids[100]
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: tableView.rect(ofRow: 100).origin.y + 10))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        keeper.projectionWillChange()
        // A new row lands in front; the anchored item is row 101 now.
        ids.insert(UUID(), at: 0)
        rows.heights.insert(80, at: 0)
        tableView.insertRows(at: IndexSet(integer: 0))
        tableView.layoutSubtreeIfNeeded()

        XCTAssertEqual(scrollView.contentView.bounds.origin.y, tableView.rect(ofRow: 101).origin.y + 10, accuracy: 0.5)
        XCTAssertEqual(ids[101], anchorID)
    }

    func testReplacedRowsAreNotRestored() {
        let rows = Rows(heights: Array(repeating: 43, count: 200))
        let (scrollView, tableView) = makeTable(rows: rows)
        let keeper = ListScrollAnchorKeeper()
        keeper.scrollView = scrollView
        keeper.itemID = { _ in UUID() }
        keeper.row = { _ in nil }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: tableView.rect(ofRow: 100).origin.y))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        keeper.projectionWillChange()
        rows.heights = Array(repeating: 43, count: 20)
        tableView.reloadData()
        tableView.layoutSubtreeIfNeeded()

        XCTAssertLessThan(scrollView.contentView.bounds.origin.y, 43 * 20, "A search result page starts where the table put it")
    }
}
