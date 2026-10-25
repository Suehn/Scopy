import XCTest
@testable import Scopy

@MainActor
final class HistoryRowLiveStateFanoutTests: XCTestCase {
    func testUpdateNotifiesOnlyTheRowsThatChange() {
        let fanout = HistoryRowLiveStateFanout()
        let a = UUID(), b = UUID(), c = UUID()
        var log: [String] = []
        fanout.register(.init(itemID: a)) { log.append("a:\($0.isSelected)") }
        fanout.register(.init(itemID: b)) { log.append("b:\($0.isSelected)") }
        fanout.register(.init(itemID: c)) { log.append("c:\($0.isSelected)") }

        fanout.update(selectedID: a, follow: false)
        fanout.update(selectedID: b, follow: true)
        fanout.update(selectedID: b, follow: true)
        fanout.update(selectedID: nil, follow: false)

        XCTAssertEqual(log, ["a:true", "a:false", "b:true", "b:false"])
        XCTAssertNil(fanout.selectedID)
    }

    func testRegisterReportsCurrentSelectionAndUnregisterStopsDelivery() {
        let fanout = HistoryRowLiveStateFanout()
        let a = UUID()
        fanout.update(selectedID: a, follow: false)
        var received: [HistoryRowLiveState] = []
        let token = HistoryRowLiveStateFanout.RegistrationToken(itemID: a)

        XCTAssertTrue(fanout.register(token) { received.append($0) }.isSelected)
        XCTAssertFalse(fanout.register(.init(itemID: UUID())) { _ in }.isSelected)
        fanout.unregister(token)
        fanout.update(selectedID: nil, follow: false)

        XCTAssertTrue(received.isEmpty)
        XCTAssertFalse(fanout.state(for: a).isSelected)
    }

    func testSelectionChangedCallbackCarriesFollowFlag() {
        let fanout = HistoryRowLiveStateFanout()
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

    func testDisappearingRowCannotUnregisterItsReplacement() {
        let fanout = HistoryRowLiveStateFanout()
        let itemID = UUID()
        let oldRow = HistoryRowLiveStateFanout.RegistrationToken(itemID: itemID)
        let newRow = HistoryRowLiveStateFanout.RegistrationToken(itemID: itemID)
        var oldValues: [HistoryRowLiveState] = []
        var newValues: [HistoryRowLiveState] = []

        fanout.register(oldRow) { oldValues.append($0) }
        fanout.register(newRow) { newValues.append($0) }
        fanout.unregister(oldRow)
        fanout.update(selectedID: itemID, follow: false)
        fanout.updateQuickSlots([itemID: 1])
        fanout.updatePresentedPreview(.init(itemID: itemID, kind: .text))

        XCTAssertTrue(oldValues.isEmpty)
        XCTAssertEqual(newValues.count, 3)
        XCTAssertTrue(newValues.last?.isSelected == true)
        XCTAssertEqual(newValues.last?.quickSlot, 1)
        XCTAssertEqual(newValues.last?.presentedPreview, .text)

        fanout.unregister(newRow)
        fanout.update(selectedID: nil, follow: false)
        XCTAssertEqual(newValues.count, 3)
    }
}
