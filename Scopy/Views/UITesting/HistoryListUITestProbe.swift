import AppKit
import SwiftUI

enum HistoryListUITestRuntime {
    static let imageTargetID = UUID(
        uuidString: "53504359-1001-4000-8000-000000000001"
    )!
    static let fileTargetID = UUID(
        uuidString: "53504359-1001-4000-8000-000000000002"
    )!

    static let namespace: String? = {
        guard let rawValue = ProcessInfo.processInfo.environment[
            "SCOPY_UITEST_HISTORY_LIST_NAMESPACE"
        ] else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }()

    static let isEnabled: Bool = {
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains("--uitesting")
            && processInfo.arguments.contains("--history-list-retained-interaction")
            && processInfo.environment["SCOPY_UITEST_HISTORY_LIST_INTEGRATION"] == "1"
            && namespace != nil
    }()

    static func notificationName(_ command: String) -> Notification.Name? {
        guard let namespace else { return nil }
        return Notification.Name(
            "org.scopy.uitest.history-list.\(namespace).\(command)"
        )
    }
}

@MainActor
final class HistoryListUITestProbe: NSObject, ObservableObject {
    enum AccessibilityID {
        static let attached = "UITest.HistoryListProbe.Attached"
        static let scrollStartCount = "UITest.HistoryListProbe.ScrollStartCount"
        static let scrollEndCount = "UITest.HistoryListProbe.ScrollEndCount"
        static let fileAppearCount = "UITest.HistoryListProbe.FileAppearCount"
        static let fileDisappearCount = "UITest.HistoryListProbe.FileDisappearCount"
        static let mockPersistedNote = "UITest.HistoryListProbe.MockPersistedNote"
        static let modelPersistedNote = "UITest.HistoryListProbe.ModelPersistedNote"
    }

    static let shared = HistoryListUITestProbe()

    @Published private(set) var attachCount = 0
    @Published private(set) var scrollStartCount = 0
    @Published private(set) var scrollEndCount = 0
    @Published private(set) var fileAppearCount = 0
    @Published private(set) var fileDisappearCount = 0
    @Published private(set) var mockPersistedNote = ""
    @Published private(set) var modelPersistedNote = ""

    private weak var scrollView: NSScrollView?

    private override init() {
        precondition(
            HistoryListUITestRuntime.isEnabled,
            "HistoryListUITestProbe must only be instantiated by its triple-gated UI test"
        )
        super.init()
        installCommandObservers()
    }

    func attach(scrollView: NSScrollView) {
        guard self.scrollView !== scrollView else { return }
        self.scrollView = scrollView
        attachCount += 1
    }

    func recordProductionScrollStart() {
        scrollStartCount += 1
    }

    func recordProductionScrollEnd() {
        scrollEndCount += 1
    }

    func recordRowAppeared(itemID: UUID) {
        guard itemID == HistoryListUITestRuntime.fileTargetID else { return }
        fileAppearCount += 1
    }

    func recordRowDisappeared(itemID: UUID) {
        guard itemID == HistoryListUITestRuntime.fileTargetID else { return }
        fileDisappearCount += 1
    }

    func recordModelPersistedNote(_ note: String) {
        modelPersistedNote = note
    }

    private func installCommandObservers() {
        let center = DistributedNotificationCenter.default()
        if let name = HistoryListUITestRuntime.notificationName("scroll-start") {
            center.addObserver(
                self,
                selector: #selector(handleScrollStartCommand(_:)),
                name: name,
                object: nil
            )
        }
        if let name = HistoryListUITestRuntime.notificationName("scroll-end") {
            center.addObserver(
                self,
                selector: #selector(handleScrollEndCommand(_:)),
                name: name,
                object: nil
            )
        }
        if let name = HistoryListUITestRuntime.notificationName("jump-top") {
            center.addObserver(
                self,
                selector: #selector(handleJumpTopCommand(_:)),
                name: name,
                object: nil
            )
        }
        if let name = HistoryListUITestRuntime.notificationName("jump-bottom") {
            center.addObserver(
                self,
                selector: #selector(handleJumpBottomCommand(_:)),
                name: name,
                object: nil
            )
        }
        if let name = HistoryListUITestRuntime.notificationName("mock-note-persisted") {
            center.addObserver(
                self,
                selector: #selector(handleMockNotePersisted(_:)),
                name: name,
                object: nil
            )
        }
    }

    @objc private func handleScrollStartCommand(_ notification: Notification) {
        guard let scrollView else { return }
        NotificationCenter.default.post(
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView
        )
    }

    @objc private func handleScrollEndCommand(_ notification: Notification) {
        guard let scrollView else { return }
        NotificationCenter.default.post(
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView
        )
    }

    @objc private func handleJumpTopCommand(_ notification: Notification) {
        jump(toBottom: false)
    }

    @objc private func handleJumpBottomCommand(_ notification: Notification) {
        jump(toBottom: true)
    }

    @objc private func handleMockNotePersisted(_ notification: Notification) {
        guard notification.object as? String
                == HistoryListUITestRuntime.fileTargetID.uuidString,
              let note = notification.userInfo?["note"] as? String else { return }
        mockPersistedNote = note
    }

    private func jump(toBottom: Bool) {
        guard let scrollView, let documentView = scrollView.documentView else { return }

        NotificationCenter.default.post(
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView
        )

        let clipView = scrollView.contentView
        let documentBounds = documentView.bounds
        let maximumY = max(
            documentBounds.minY,
            documentBounds.maxY - clipView.bounds.height
        )
        let targetY = toBottom ? maximumY : documentBounds.minY
        clipView.scroll(
            to: NSPoint(x: clipView.bounds.origin.x, y: targetY)
        )
        scrollView.reflectScrolledClipView(clipView)

        DispatchQueue.main.async { [weak self, weak scrollView] in
            guard let self, self.scrollView === scrollView, let scrollView else { return }
            NotificationCenter.default.post(
                name: NSScrollView.didEndLiveScrollNotification,
                object: scrollView
            )
        }
    }
}

struct HistoryListUITestProbeAccessibilityView: View {
    @ObservedObject var probe: HistoryListUITestProbe

    var body: some View {
        ZStack {
            probeValue(
                identifier: HistoryListUITestProbe.AccessibilityID.attached,
                value: probe.attachCount > 0 ? "1" : "0"
            )
            probeValue(
                identifier: HistoryListUITestProbe.AccessibilityID.scrollStartCount,
                value: "\(probe.scrollStartCount)"
            )
            probeValue(
                identifier: HistoryListUITestProbe.AccessibilityID.scrollEndCount,
                value: "\(probe.scrollEndCount)"
            )
            probeValue(
                identifier: HistoryListUITestProbe.AccessibilityID.fileAppearCount,
                value: "\(probe.fileAppearCount)"
            )
            probeValue(
                identifier: HistoryListUITestProbe.AccessibilityID.fileDisappearCount,
                value: "\(probe.fileDisappearCount)"
            )
            probeValue(
                identifier: HistoryListUITestProbe.AccessibilityID.mockPersistedNote,
                value: probe.mockPersistedNote
            )
            probeValue(
                identifier: HistoryListUITestProbe.AccessibilityID.modelPersistedNote,
                value: probe.modelPersistedNote
            )
        }
        .frame(width: 1, height: 1)
        .opacity(0.01)
        .allowsHitTesting(false)
    }

    private func probeValue(identifier: String, value: String) -> some View {
        Text(value)
            .font(.system(size: 1))
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(identifier)
            .accessibilityValue(value)
    }
}
