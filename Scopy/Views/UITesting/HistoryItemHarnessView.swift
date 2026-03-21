import SwiftUI
import ScopyKit

@MainActor
struct HistoryItemHarnessView: View {
    private enum Scenario: String {
        case image
        case markdownText = "markdown-text"
        case plainText = "plain-text"
    }

    @State private var selectCount = 0
    @State private var optimizeCount = 0
    @State private var pinCount = 0
    @State private var updateNoteCount = 0
    @State private var activePopover: HoverPreviewPopoverKind?
    @State private var settingsViewModel: SettingsViewModel
    @State private var settings: SettingsDTO
    @State private var isKeyboardSelected: Bool
    @State private var interactionCoordinator = HistoryListInteractionCoordinator()

    private let item: ClipboardItemDTO
    private let markdownWebViewController = MarkdownPreviewWebViewController()

    init() {
        _settingsViewModel = State(initialValue: SettingsViewModel(service: ClipboardServiceFactory.create(useMock: true)))
        let scenario = Self.scenarioFromEnvironment()
        let item = Self.makeItem(for: scenario)
        let keyboardSelected = ProcessInfo.processInfo.environment["SCOPY_UITEST_HISTORY_ITEM_KEYBOARD_SELECTED"] != "0"
        var settings = SettingsDTO.default
        settings.showImageThumbnails = scenario == .image
        settings.imagePreviewDelay = 0

        self.item = item
        _settings = State(initialValue: settings)
        _isKeyboardSelected = State(initialValue: keyboardSelected)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ScopySpacing.md) {
            VStack(spacing: 0) {
                HistoryItemView(
                    item: item,
                    isKeyboardSelected: isKeyboardSelected,
                    settings: settings,
                    onSelect: { selectCount += 1 },
                    onSelectOptimizedForCodex: { selectCount += 1 },
                    onHoverSelect: { _ in },
                    onTogglePin: { pinCount += 1 },
                    onDelete: { },
                    onUpdateNote: { _ in updateNoteCount += 1 },
                    onOptimizeImage: {
                        optimizeCount += 1
                        return ImageOptimizationOutcomeDTO(
                            result: .optimized,
                            originalBytes: 2_048,
                            optimizedBytes: 1_024
                        )
                    },
                    getImageData: { nil },
                    markdownWebViewController: markdownWebViewController,
                    interactionCoordinator: interactionCoordinator,
                    isImagePreviewPresented: activePopover == .image,
                    isTextPreviewPresented: activePopover == .text,
                    isFilePreviewPresented: activePopover == .file,
                    requestPopover: { kind in activePopover = kind },
                    dismissOtherPopovers: { activePopover = nil }
                )
                .environment(settingsViewModel)
            }

            VStack(alignment: .leading, spacing: ScopySpacing.xs) {
                Text("select=\(selectCount)")
                    .accessibilityIdentifier("UITest.HistoryItemHarness.SelectCount")
                Text("optimize=\(optimizeCount)")
                    .accessibilityIdentifier("UITest.HistoryItemHarness.OptimizeCount")
                Text("pin=\(pinCount)")
                    .accessibilityIdentifier("UITest.HistoryItemHarness.PinCount")
                Text("noteUpdates=\(updateNoteCount)")
                    .accessibilityIdentifier("UITest.HistoryItemHarness.NoteUpdateCount")
            }
            .font(ScopyTypography.caption)
            .foregroundStyle(ScopyColors.mutedText)

            Text("History Item Harness")
                .opacity(0.001)
                .accessibilityIdentifier("UITest.HistoryItemHarness")
        }
        .padding(ScopySpacing.lg)
        .frame(minWidth: 880, minHeight: 340, alignment: .topLeading)
    }

    private static func scenarioFromEnvironment() -> Scenario {
        let raw = ProcessInfo.processInfo.environment["SCOPY_UITEST_HISTORY_ITEM_SCENARIO"] ?? ""
        return Scenario(rawValue: raw) ?? .image
    }

    private static func makeItem(for scenario: Scenario) -> ClipboardItemDTO {
        let now = Date()
        switch scenario {
        case .image:
            return ClipboardItemDTO(
                id: UUID(),
                type: .image,
                contentHash: "history-item-harness-image",
                plainText: "Harness image item",
                note: nil,
                appBundleID: "com.scopy.tests",
                createdAt: now.addingTimeInterval(-120),
                lastUsedAt: now.addingTimeInterval(-15),
                isPinned: false,
                sizeBytes: 2_048,
                fileSizeBytes: nil,
                thumbnailPath: nil,
                storageRef: nil
            )
        case .markdownText:
            return ClipboardItemDTO(
                id: UUID(),
                type: .text,
                contentHash: "history-item-harness-markdown",
                plainText: "# Harness\n\n- markdown export eligible",
                note: nil,
                appBundleID: "com.scopy.tests",
                createdAt: now.addingTimeInterval(-240),
                lastUsedAt: now.addingTimeInterval(-30),
                isPinned: false,
                sizeBytes: 512,
                fileSizeBytes: nil,
                thumbnailPath: nil,
                storageRef: nil
            )
        case .plainText:
            return ClipboardItemDTO(
                id: UUID(),
                type: .text,
                contentHash: "history-item-harness-plain",
                plainText: "Just a short plain text sentence.",
                note: nil,
                appBundleID: "com.scopy.tests",
                createdAt: now.addingTimeInterval(-360),
                lastUsedAt: now.addingTimeInterval(-45),
                isPinned: false,
                sizeBytes: 128,
                fileSizeBytes: nil,
                thumbnailPath: nil,
                storageRef: nil
            )
        }
    }
}
