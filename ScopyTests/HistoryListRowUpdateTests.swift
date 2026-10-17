import AppKit
import SwiftUI
import XCTest
import ScopyKit

@testable import Scopy

@MainActor
final class HistoryListRowUpdateTests: XCTestCase {
    /// A List update must not rebuild the rows whose inputs did not change (it used to rebuild every
    /// loaded row), and a change to what one row draws must still rebuild that row, a settings
    /// change every shown row.
    func testAListUpdateRebuildsOnlyTheRowsWhoseInputsChanged() async {
        let service = TestMockClipboardService()
        service.setItemCount(400)
        let appState = AppState.forTesting(service: service)
        addTeardownBlock { await appState.stop() }
        let viewModel = appState.historyViewModel
        await viewModel.load()
        await viewModel.loadMore()
        let loadedCount = viewModel.loadedCount
        XCTAssertEqual(loadedCount, HistoryViewModel.initialPageSize + HistoryViewModel.loadMorePageSize)

        let host = NSHostingView(
            rootView: ListHost()
                .environment(viewModel)
                .environment(appState.settingsViewModel)
        )
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 480)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        addTeardownBlock { window.close() }
        let shown = await rowsBuilt(in: host) {}
        XCTAssertGreaterThan(shown, 0)

        let first = viewModel.items[0]
        let captured = ClipboardItemDTO(
            id: UUID(), type: .text, contentHash: "captured", plainText: "Captured",
            appBundleID: "com.test.app", createdAt: Date(), lastUsedAt: first.lastUsedAt.addingTimeInterval(1),
            isPinned: false, sizeBytes: 8, thumbnailPath: nil, storageRef: nil
        )
        let afterCapture = await rowsBuilt(in: host) {
            await viewModel.handleEvent(.newItem(captured))
        }
        XCTAssertEqual(viewModel.items.first?.id, captured.id)
        XCTAssertGreaterThanOrEqual(afterCapture, 1, "The captured row is built")
        XCTAssertLessThanOrEqual(afterCapture, 2, "A capture rebuilt \(afterCapture) of \(loadedCount + 1) rows")

        let target = viewModel.items[10]
        let noted = ClipboardItemDTO(
            id: target.id, type: target.type, contentHash: target.contentHash, plainText: target.plainText,
            note: "noted", appBundleID: target.appBundleID, createdAt: target.createdAt,
            lastUsedAt: target.lastUsedAt, isPinned: target.isPinned, sizeBytes: target.sizeBytes,
            thumbnailPath: target.thumbnailPath, storageRef: target.storageRef
        )
        let afterNote = await rowsBuilt(in: host) {
            await viewModel.handleEvent(.itemUpdated(noted))
        }
        XCTAssertEqual(viewModel.items[10].note, "noted")
        XCTAssertGreaterThanOrEqual(afterNote, 1, "The row whose note changed is rebuilt")
        XCTAssertLessThanOrEqual(afterNote, 2, "A note change rebuilt \(afterNote) rows")

        let afterSettings = await rowsBuilt(in: host) {
            appState.settingsViewModel.settings.thumbnailHeight += 8
        }
        XCTAssertGreaterThanOrEqual(afterSettings, shown / 2, "A settings change rebuilds every shown row")
    }

    /// Rows built while `change` runs and the list renders the result.
    private func rowsBuilt(in host: NSView, after change: () async -> Void) async -> Int {
        let before = HistoryItemView.initCountForTesting
        await change()
        let deadline = Date().addingTimeInterval(2)
        repeat {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 10_000_000)
        } while HistoryItemView.initCountForTesting == before && Date() < deadline
        // Let any further pass of the same update land before counting.
        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return HistoryItemView.initCountForTesting - before
    }
}

private struct ListHost: View {
    @FocusState private var searchFocused: Bool

    var body: some View {
        HistoryListView(searchFocused: $searchFocused, openSettings: nil)
    }
}
