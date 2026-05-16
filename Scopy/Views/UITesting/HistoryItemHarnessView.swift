import AppKit
import SwiftUI
import ScopyKit
import ScopyUISupport

@MainActor
struct HistoryItemHarnessView: View {
    private enum Scenario: String {
        case image
        case inlineImage = "inline-image"
        case file
        case markdownFile = "markdown-file"
        case markdownText = "markdown-text"
        case plainText = "plain-text"
    }

    @State private var selectCount = 0
    @State private var codexPasteCount = 0
    @State private var airDropCount = 0
    @State private var openFolderCount = 0
    @State private var optimizeCount = 0
    @State private var pinCount = 0
    @State private var updateNoteCount = 0
    @State private var activePopover: HoverPreviewPopoverKind?
    @State private var popoverRequest = "none"
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
        settings.showImageThumbnails = scenario == .image || scenario == .inlineImage
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
                    onSelectOptimizedForCodex: { codexPasteCount += 1 },
                    onSendViaAirDrop: { airDropCount += 1 },
                    onOpenContainingFolder: { openFolderCount += 1 },
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
                    requestPopover: { kind in
                        popoverRequest = Self.popoverName(kind)
                        activePopover = kind
                    },
                    dismissOtherPopovers: {
                        popoverRequest = "dismiss-other"
                        activePopover = nil
                    }
                )
                .environment(settingsViewModel)
            }

            VStack(alignment: .leading, spacing: ScopySpacing.xs) {
                Text("select=\(selectCount)")
                    .accessibilityIdentifier("UITest.HistoryItemHarness.SelectCount")
                Text("codexPaste=\(codexPasteCount)")
                    .accessibilityIdentifier("UITest.HistoryItemHarness.CodexPasteCount")
                Text("airDrop=\(airDropCount)")
                    .accessibilityIdentifier("UITest.HistoryItemHarness.AirDropCount")
                Text("openFolder=\(openFolderCount)")
                    .accessibilityIdentifier("UITest.HistoryItemHarness.OpenFolderCount")
                Text("optimize=\(optimizeCount)")
                    .accessibilityIdentifier("UITest.HistoryItemHarness.OptimizeCount")
                Text("pin=\(pinCount)")
                    .accessibilityIdentifier("UITest.HistoryItemHarness.PinCount")
                Text("noteUpdates=\(updateNoteCount)")
                    .accessibilityIdentifier("UITest.HistoryItemHarness.NoteUpdateCount")
                Text("popover=\(Self.popoverName(activePopover))")
                    .accessibilityIdentifier("UITest.HistoryItemHarness.ActivePopover")
                Text("popoverRequest=\(popoverRequest)")
                    .accessibilityIdentifier("UITest.HistoryItemHarness.PopoverRequest")
            }
            .font(ScopyTypography.caption)
            .foregroundStyle(ScopyColors.mutedText)

            Text("History Item Harness")
                .opacity(0.001)
                .accessibilityIdentifier("UITest.HistoryItemHarness")
        }
        .padding(ScopySpacing.lg)
        .frame(minWidth: 880, minHeight: 340, alignment: .topLeading)
        .background(profileSampler)
    }

    @ViewBuilder
    private var profileSampler: some View {
        if ScrollPerformanceProfile.isEnabled {
            TimelineView(.animation) { context in
                Color.clear
                    .onChange(of: context.date) { _, newValue in
                        ScrollPerformanceProfile.shared.recordFrameTick(newValue)
                    }
            }
            .onAppear {
                ScrollPerformanceProfile.shared.scrollDidStart()
            }
            .onDisappear {
                ScrollPerformanceProfile.shared.scrollDidEnd()
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private static func scenarioFromEnvironment() -> Scenario {
        let raw = ProcessInfo.processInfo.environment["SCOPY_UITEST_HISTORY_ITEM_SCENARIO"] ?? ""
        return Scenario(rawValue: raw) ?? .image
    }

    private static func popoverName(_ kind: HoverPreviewPopoverKind?) -> String {
        switch kind {
        case .image:
            return "image"
        case .text:
            return "text"
        case .file:
            return "file"
        case nil:
            return "none"
        }
    }

    private static func makeItem(for scenario: Scenario) -> ClipboardItemDTO {
        let now = Date()
        switch scenario {
        case .image:
            let path = makeHarnessImagePath()
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
                thumbnailPath: path,
                storageRef: path
            )
        case .inlineImage:
            let path = makeHarnessImagePath()
            return ClipboardItemDTO(
                id: UUID(),
                type: .image,
                contentHash: "history-item-harness-inline-image",
                plainText: "Harness inline image item",
                note: nil,
                appBundleID: "com.scopy.tests",
                createdAt: now.addingTimeInterval(-150),
                lastUsedAt: now.addingTimeInterval(-18),
                isPinned: false,
                sizeBytes: 2_048,
                fileSizeBytes: nil,
                thumbnailPath: path,
                storageRef: nil
            )
        case .file:
            let path = makeHarnessFilePath()
            return ClipboardItemDTO(
                id: UUID(),
                type: .file,
                contentHash: "history-item-harness-file",
                plainText: path,
                note: nil,
                appBundleID: "com.scopy.tests",
                createdAt: now.addingTimeInterval(-180),
                lastUsedAt: now.addingTimeInterval(-20),
                isPinned: false,
                sizeBytes: 64,
                fileSizeBytes: 64,
                thumbnailPath: nil,
                storageRef: path
            )
        case .markdownFile:
            let path = makeHarnessMarkdownFilePath()
            return ClipboardItemDTO(
                id: UUID(),
                type: .file,
                contentHash: "history-item-harness-markdown-file",
                plainText: path,
                note: nil,
                appBundleID: "com.scopy.tests",
                createdAt: now.addingTimeInterval(-210),
                lastUsedAt: now.addingTimeInterval(-24),
                isPinned: false,
                sizeBytes: 256,
                fileSizeBytes: 256,
                thumbnailPath: nil,
                storageRef: path
            )
        case .markdownText:
            return ClipboardItemDTO(
                id: UUID(),
                type: .text,
                contentHash: "history-item-harness-markdown",
                plainText: """
# Harness

- [x] markdown export eligible
- [ ] pending follow-up
  - nested detail

Inline math: $E = mc^2$.[^harness]

<details open>
<summary>点击展开</summary>

- 列表
- **强调**

</details>

术语
: 定义内容

| col | value |
| --- | --- |
| alpha | $\\alpha$ |

[^harness]: Footnote text for the history item harness.
""",
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

    private static func makeHarnessFilePath() -> String {
        let directory = URL(fileURLWithPath: "/tmp/scopy_history_item_harness", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("airdrop-folder-action.txt")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? "Scopy file menu harness\n".write(to: url, atomically: true, encoding: .utf8)
        }
        return url.path
    }

    private static func makeHarnessMarkdownFilePath() -> String {
        let directory = URL(fileURLWithPath: "/tmp/scopy_history_item_harness", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("hover-preview-markdown-file.md")
        let markdown = """
# Markdown File Harness

- file-backed preview
- should open before render completes

Inline math: $a^2 + b^2 = c^2$
"""
        try? markdown.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private static func makeHarnessImagePath() -> String {
        let directory = URL(fileURLWithPath: "/tmp/scopy_history_item_harness", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("hover-profile-image.png")
        if !FileManager.default.fileExists(atPath: url.path),
           let data = makeHarnessImageData(size: 256) {
            try? data.write(to: url, options: .atomic)
        }
        return url.path
    }

    private static func makeHarnessImageData(size: Int) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(calibratedHue: 0.58, saturation: 0.55, brightness: 0.92, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        NSColor.white.withAlphaComponent(0.6).setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 24, y: 48))
        path.line(to: NSPoint(x: 112, y: 206))
        path.line(to: NSPoint(x: 232, y: 72))
        path.lineWidth = 12
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }
}
