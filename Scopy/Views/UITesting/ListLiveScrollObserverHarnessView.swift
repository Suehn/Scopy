#if DEBUG
import AppKit
import SwiftUI

@MainActor
struct ListLiveScrollObserverHarnessView: View {
    private enum AccessibilityID {
        static let harness = "UITest.ListLiveScrollObserverHarness"
        static let scrollView = "UITest.ListLiveScrollObserverHarness.ScrollView"
        static let verticalScroller = "UITest.ListLiveScrollObserverHarness.VerticalScroller"
        static let horizontalScroller = "UITest.ListLiveScrollObserverHarness.HorizontalScroller"
        static let observerAttached = "UITest.ListLiveScrollObserverHarness.ObserverAttached"
        static let pointerStartCount = "UITest.ListLiveScrollObserverHarness.PointerStartCount"
        static let pointerEndCount = "UITest.ListLiveScrollObserverHarness.PointerEndCount"
        static let pointerActiveCount = "UITest.ListLiveScrollObserverHarness.PointerActiveCount"
        static let liveScrollStartCount = "UITest.ListLiveScrollObserverHarness.LiveScrollStartCount"
        static let liveScrollEndCount = "UITest.ListLiveScrollObserverHarness.LiveScrollEndCount"
    }

    @State private var pointerCounts: PointerInteractionCounts
    @State private var interactionCoordinator: HistoryListInteractionCoordinator
    @State private var isObserverAttached = false
    @State private var liveScrollStartCount = 0
    @State private var liveScrollEndCount = 0

    init() {
        let counts = PointerInteractionCounts()
        _pointerCounts = State(initialValue: counts)
        _interactionCoordinator = State(initialValue: HistoryListInteractionCoordinator(
            passivePathSnapshotSink: { counts.record($0) }
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("List Live Scroll Observer Harness")
                .font(.headline)
                .accessibilityIdentifier(AccessibilityID.harness)

            LegacyScrollView(
                scrollViewAccessibilityIdentifier: AccessibilityID.scrollView,
                verticalScrollerAccessibilityIdentifier: AccessibilityID.verticalScroller,
                horizontalScrollerAccessibilityIdentifier: AccessibilityID.horizontalScroller
            )
            .background(
                ListLiveScrollObserverView(
                    interactionCoordinator: interactionCoordinator,
                    onScrollStart: {
                        liveScrollStartCount += 1
                        interactionCoordinator.beginScrolling()
                    },
                    onScrollEnd: {
                        liveScrollEndCount += 1
                        interactionCoordinator.endScrolling()
                    },
                    onScrollViewAttach: { _ in
                        Task { @MainActor in
                            isObserverAttached = true
                        }
                    }
                )
            )
            .frame(minWidth: 760, minHeight: 500)

            HStack(spacing: 16) {
                counterText(
                    "attached=\(isObserverAttached ? 1 : 0)",
                    identifier: AccessibilityID.observerAttached
                )
                counterText(
                    "start=\(pointerCounts.started)",
                    identifier: AccessibilityID.pointerStartCount
                )
                counterText(
                    "end=\(pointerCounts.ended)",
                    identifier: AccessibilityID.pointerEndCount
                )
                counterText(
                    "active=\(pointerCounts.active)",
                    identifier: AccessibilityID.pointerActiveCount
                )
                counterText(
                    "liveStart=\(liveScrollStartCount)",
                    identifier: AccessibilityID.liveScrollStartCount
                )
                counterText(
                    "liveEnd=\(liveScrollEndCount)",
                    identifier: AccessibilityID.liveScrollEndCount
                )
            }
            .font(.system(.body, design: .monospaced))
        }
        .padding(20)
    }

    private func counterText(_ value: String, identifier: String) -> some View {
        Text(value)
            .accessibilityIdentifier(identifier)
    }

}

/// Counts pointer-interaction starts and ends from the coordinator's passive-path snapshots.
@MainActor
@Observable
private final class PointerInteractionCounts {
    private(set) var started = 0
    private(set) var ended = 0
    private(set) var active = 0

    func record(_ snapshot: HistoryListInteractionCoordinator.PassivePathSnapshot) {
        guard snapshot.pointerInteractionCount != active else { return }
        if snapshot.pointerInteractionCount > active { started += 1 } else { ended += 1 }
        active = snapshot.pointerInteractionCount
    }
}

private struct LegacyScrollView: NSViewRepresentable {
    let scrollViewAccessibilityIdentifier: String
    let verticalScrollerAccessibilityIdentifier: String
    let horizontalScrollerAccessibilityIdentifier: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.scrollerStyle = .legacy
        scrollView.autohidesScrollers = false

        let verticalScroller = NSScroller()
        verticalScroller.scrollerStyle = .legacy
        configureAccessibility(
            for: verticalScroller,
            identifier: verticalScrollerAccessibilityIdentifier,
            label: "Vertical scroller"
        )
        scrollView.verticalScroller = verticalScroller
        scrollView.hasVerticalScroller = true
        verticalScroller.isHidden = false
        verticalScroller.alphaValue = 1

        let horizontalScroller = NSScroller()
        horizontalScroller.scrollerStyle = .legacy
        configureAccessibility(
            for: horizontalScroller,
            identifier: horizontalScrollerAccessibilityIdentifier,
            label: "Horizontal scroller"
        )
        scrollView.horizontalScroller = horizontalScroller
        scrollView.hasHorizontalScroller = true
        horizontalScroller.isHidden = false
        horizontalScroller.alphaValue = 1

        let documentView = HarnessDocumentView(
            frame: NSRect(x: 0, y: 0, width: 1_800, height: 1_400)
        )
        scrollView.documentView = documentView
        configureAccessibility(
            for: scrollView,
            identifier: scrollViewAccessibilityIdentifier,
            label: "Legacy scroll view"
        )

        positionKnobsNearCenter(in: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        scrollView.scrollerStyle = .legacy
        scrollView.autohidesScrollers = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        configureAccessibility(
            for: scrollView,
            identifier: scrollViewAccessibilityIdentifier,
            label: "Legacy scroll view"
        )
        if let verticalScroller = scrollView.verticalScroller {
            verticalScroller.isHidden = false
            verticalScroller.alphaValue = 1
            verticalScroller.isEnabled = true
            configureAccessibility(
                for: verticalScroller,
                identifier: verticalScrollerAccessibilityIdentifier,
                label: "Vertical scroller"
            )
        }
        if let horizontalScroller = scrollView.horizontalScroller {
            horizontalScroller.isHidden = false
            horizontalScroller.alphaValue = 1
            horizontalScroller.isEnabled = true
            configureAccessibility(
                for: horizontalScroller,
                identifier: horizontalScrollerAccessibilityIdentifier,
                label: "Horizontal scroller"
            )
        }
        scrollView.layoutSubtreeIfNeeded()
        scrollView.reflectScrolledClipView(scrollView.contentView)
        scrollView.verticalScroller?.isEnabled = true
        scrollView.horizontalScroller?.isEnabled = true
    }

    private func configureAccessibility(
        for view: NSView,
        identifier: String,
        label: String
    ) {
        view.identifier = NSUserInterfaceItemIdentifier(identifier)
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityLabel(label)
    }

    private func positionKnobsNearCenter(in scrollView: NSScrollView) {
        scrollView.layoutSubtreeIfNeeded()
        let documentSize = scrollView.documentView?.bounds.size ?? .zero
        let viewportSize = scrollView.contentView.bounds.size
        let centeredOrigin = NSPoint(
            x: max(0, (documentSize.width - viewportSize.width) / 2),
            y: max(0, (documentSize.height - viewportSize.height) / 2)
        )
        scrollView.contentView.scroll(to: centeredOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

private final class HarnessDocumentView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 20, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ]
        let string = "Real NSScrollView / NSScroller integration surface"
        string.draw(
            in: NSRect(x: 500, y: 620, width: 800, height: 60),
            withAttributes: attributes
        )
    }
}
#endif
