import XCTest
@testable import Scopy

@MainActor
final class HistoryRowSelectionFanoutTests: XCTestCase {
    func testUpdateNotifiesOnlyTheRowsThatChange() {
        let fanout = HistoryRowSelectionFanout()
        let a = UUID(), b = UUID(), c = UUID()
        var log: [String] = []
        fanout.register(itemID: a) { log.append("a:\($0)") }
        fanout.register(itemID: b) { log.append("b:\($0)") }
        fanout.register(itemID: c) { log.append("c:\($0)") }

        fanout.update(selectedID: a, follow: false)
        fanout.update(selectedID: b, follow: true)
        fanout.update(selectedID: b, follow: true)
        fanout.update(selectedID: nil, follow: false)

        XCTAssertEqual(log, ["a:true", "a:false", "b:true", "b:false"])
        XCTAssertNil(fanout.selectedID)
    }

    func testRegisterReportsCurrentSelectionAndUnregisterStopsDelivery() {
        let fanout = HistoryRowSelectionFanout()
        let a = UUID()
        fanout.update(selectedID: a, follow: false)
        var received: [Bool] = []

        XCTAssertTrue(fanout.register(itemID: a) { received.append($0) })
        XCTAssertFalse(fanout.register(itemID: UUID()) { _ in })
        fanout.unregister(itemID: a)
        fanout.update(selectedID: nil, follow: false)

        XCTAssertTrue(received.isEmpty)
        XCTAssertFalse(fanout.isSelected(a))
    }

    func testSelectionChangedCallbackCarriesFollowFlag() {
        let fanout = HistoryRowSelectionFanout()
        let a = UUID()
        var calls: [(UUID?, Bool)] = []
        fanout.onSelectionChanged = { calls.append(($0, $1)) }

        fanout.update(selectedID: a, follow: true)
        fanout.update(selectedID: a, follow: true)
        fanout.update(selectedID: nil, follow: false)

        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].0, a)
        XCTAssertTrue(calls[0].1)
        XCTAssertNil(calls[1].0)
        XCTAssertFalse(calls[1].1)
    }
}
