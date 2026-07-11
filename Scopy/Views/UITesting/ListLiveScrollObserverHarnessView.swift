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

    @State private var interactionCoordinator = HistoryListInteractionCoordinator()
    @State private var interactionObservation: HistoryListInteractionObservation?
    @State private var isObserverAttached = false
    @State private var pointerStartCount = 0
    @State private var pointerEndCount = 0
    @State private var pointerActiveCount = 0
    @State private var liveScrollStartCount = 0
    @State private var liveScrollEndCount = 0

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
                    "start=\(pointerStartCount)",
                    identifier: AccessibilityID.pointerStartCount
                )
                counterText(
                    "end=\(pointerEndCount)",
                    identifier: AccessibilityID.pointerEndCount
                )
                counterText(
                    "active=\(pointerActiveCount)",
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
        .onAppear {
            installInteractionObservationIfNeeded()
        }
        .onDisappear {
            interactionObservation?.cancel()
            interactionObservation = nil
        }
    }

    private func counterText(_ value: String, identifier: String) -> some View {
        Text(value)
            .accessibilityIdentifier(identifier)
    }

    private func installInteractionObservationIfNeeded() {
        guard interactionObservation == nil else { return }
        interactionObservation = interactionCoordinator.observe { event in
            switch event {
            case .pointerInteractionStarted:
                pointerStartCount += 1
            case .pointerInteractionEnded:
                pointerEndCount += 1
            default:
                break
            }
            pointerActiveCount = interactionCoordinator.isPointerInteractionActive ? 1 : 0
        }
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
