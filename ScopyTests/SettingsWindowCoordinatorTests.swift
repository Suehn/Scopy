import XCTest

@testable import Scopy

final class SettingsWindowCoordinatorTests: XCTestCase {
    func testOldSessionDismissDoesNotCloseNewSession() {
        var gate = SettingsWindowSessionGate()
        let oldSession = gate.startSession()
        let currentSession = gate.startSession()
        var didDismiss = false

        gate.performIfCurrent(oldSession) {
            didDismiss = true
        }
        XCTAssertFalse(didDismiss)

        gate.performIfCurrent(currentSession) {
            didDismiss = true
        }
        XCTAssertTrue(didDismiss)
    }
}
