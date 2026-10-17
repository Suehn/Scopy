import AppKit
import Observation
import SwiftUI
import XCTest
import ScopyKit

@testable import Scopy

@MainActor
final class HistoryListHoverWebViewTests: XCTestCase {
    /// Every parent body run builds a new `HistoryListView` value. The list keeps one hover
    /// WebView across those rebuilds instead of building another one each time and dropping it.
    func testRebuildingTheListViewBuildsNoFurtherHoverWebView() async {
        let service = TestMockClipboardService()
        service.setItemCount(3)
        let appState = AppState.forTesting(service: service)
        addTeardownBlock { await appState.stop() }
        await appState.historyViewModel.load()

        let parent = ListParentState()
        let createdBeforeList = MarkdownPreviewWebViewController.createdCountForTesting
        let host = NSHostingView(
            rootView: ListParent(state: parent)
                .environment(appState.historyViewModel)
                .environment(appState.settingsViewModel)
        )
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 480)
        await render(host) {
            parent.renderedGeneration == 0 &&
                MarkdownPreviewWebViewController.createdCountForTesting > createdBeforeList
        }
        let createdForList = MarkdownPreviewWebViewController.createdCountForTesting

        for generation in 1...3 {
            parent.generation = generation
            await render(host) { parent.renderedGeneration == generation }
            XCTAssertEqual(parent.renderedGeneration, generation, "The parent body ran again")
        }

        XCTAssertEqual(MarkdownPreviewWebViewController.createdCountForTesting, createdForList)
    }

    private func render(_ host: NSView, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 10_000_000)
        } while !condition() && Date() < deadline
    }
}

@Observable
@MainActor
private final class ListParentState {
    var generation = 0
    @ObservationIgnored private(set) var renderedGeneration = -1

    func markRendered(_ generation: Int) {
        renderedGeneration = generation
    }
}

private struct ListParent: View {
    let state: ListParentState
    @FocusState private var searchFocused: Bool

    var body: some View {
        let _ = state.markRendered(state.generation)
        HistoryListView(searchFocused: $searchFocused, openSettings: nil)
    }
}
