import SwiftUI
import ScopyKit
import AppKit
import Foundation

struct HistoryItemTextPreviewView: View {
    @Environment(SettingsViewModel.self) private var settingsViewModel
    /// Bumped when a link-enrichment sidecar lands for the current text so the body
    /// recomputes its render key and rebuilds the enriched document.
    @State private var linkEnrichmentRevision = 0
    let model: HoverPreviewModel
    let markdownWebViewController: MarkdownPreviewWebViewController?
    let showMarkdownPlaceholder: Bool
    let isContentCurrent: @MainActor () -> Bool
    let isExportContentCurrent: @MainActor () -> Bool
    let retainExplicitExport: @MainActor () -> Bool
    let onInteractionLifecycleChange: @MainActor () -> Void

    init(
        model: HoverPreviewModel,
        markdownWebViewController: MarkdownPreviewWebViewController?,
        showMarkdownPlaceholder: Bool = false,
        isContentCurrent: @escaping @MainActor () -> Bool = { true },
        isExportContentCurrent: @escaping @MainActor () -> Bool = { true },
        retainExplicitExport: @escaping @MainActor () -> Bool = { true },
        onInteractionLifecycleChange: @escaping @MainActor () -> Void = {}
    ) {
        self.model = model
        self.markdownWebViewController = markdownWebViewController
        self.showMarkdownPlaceholder = showMarkdownPlaceholder
        self.isContentCurrent = isContentCurrent
        self.isExportContentCurrent = isExportContentCurrent
        self.retainExplicitExport = retainExplicitExport
        self.onInteractionLifecycleChange = onInteractionLifecycleChange
        self._exportResolutionPercent = State(initialValue: Self.initialExportResolutionPercent())
        self._previewLayoutScalePercent = State(initialValue: Self.initialPreviewLayoutScalePercent())
    }

    @State private var exportResolutionPercent: Int
    @State private var previewLayoutScalePercent: Int
    @State private var hasInitializedPreviewLayoutScale = false
    @State private var overrideMarkdownHTML: String?
    @State private var overrideMarkdownRenderKey: String?
    @State private var isMarkdownLayoutScaleControlHovered = false
    @State private var isMarkdownLayoutScaleEditing = false

    private static let exportResolutionPercentUserDefaultsKey = "ScopyMarkdownExportResolutionPercent"
    private static let previewLayoutScalePercentUserDefaultsKey = "ScopyMarkdownPreviewLayoutScalePercent"
    private static let uiTestExportResolutionEnvKey = "SCOPY_UITEST_MARKDOWN_EXPORT_RESOLUTION"
    private static let markdownLayoutScaleRenderDebounceNanoseconds: UInt64 = 90_000_000

    var body: some View {
        let maxWidth: CGFloat = model.isMarkdown
            ? HoverPreviewScreenMetrics.maxMarkdownPopoverWidthPoints()
            : HoverPreviewScreenMetrics.maxPopoverWidthPoints()
        let maxHeight: CGFloat = HoverPreviewScreenMetrics.maxPopoverHeightPoints()
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let padding: CGFloat = ScopySpacing.md

        Group {
            if let text = model.text {
                let fallbackWidth = model.isMarkdown
                    ? maxWidth
                    : HoverPreviewTextSizing.preferredWidth(
                        for: text,
                        font: font,
                        padding: padding,
                        maxWidth: maxWidth
                    )
                let width: CGFloat = {
                    if model.isMarkdown {
                        return maxWidth
                    }
                    return fallbackWidth
                }()

                let measuredTextHeight: CGFloat = HoverPreviewTextSizing.preferredTextHeight(
                    for: text,
                    font: font,
                    contentWidth: max(1, width - padding * 2),
                    maxHeight: maxHeight
                )
                let textContentHeight = measuredTextHeight + padding * 2

                // Add a small buffer to avoid occasional off-by-a-few-pixels scroll for very small content.
                let markdownMeasuredHeight = model.markdownContentSize?.height
                let contentHeight = (model.isMarkdown ? (markdownMeasuredHeight ?? textContentHeight) : textContentHeight) + 4
                let clampedHeight = min(maxHeight, max(1, contentHeight))
                let shouldScroll = contentHeight > maxHeight

                if model.isMarkdown, model.markdownHTML == nil, showMarkdownPlaceholder {
                    ProgressView()
                        .frame(width: width, height: clampedHeight)
                } else if model.isMarkdown, let html = model.markdownHTML {
                    let layoutScale = activeMarkdownLayoutScale
                    let renderKey = HoverPreviewModel.markdownRenderKey(source: text, layoutScale: layoutScale)
                    let defaultRenderKey = HoverPreviewModel.markdownRenderKey(
                        source: text,
                        layoutScale: settingsMarkdownLayoutScale
                    )
                    let isLiveRender = model.isMarkdownRenderLive(for: renderKey)
                    let defaultHTMLIsFresh = model.markdownHTMLEnrichmentFingerprint
                        == HoverPreviewModel.enrichmentFingerprint(for: text)
                    let displayedDocument = displayedMarkdownDocument(
                        defaultHTML: html,
                        defaultRenderKey: defaultRenderKey,
                        layoutScale: layoutScale,
                        activeRenderKey: renderKey,
                        defaultHTMLIsFresh: defaultHTMLIsFresh
                    )
                    ZStack(alignment: .topTrailing) {
                        if let controller = markdownWebViewController {
                            ReusableMarkdownPreviewWebView(
                                controller: controller,
                                html: displayedDocument.html,
                                shouldScroll: shouldScroll,
                                onContentSizeChange: { metrics in
                                    guard !displayedDocument.isPendingActiveScale else { return }
                                    applyMarkdownMetrics(metrics, renderKey: displayedDocument.renderKey)
                                }
                            )
                            .frame(width: width, height: clampedHeight)
                            .accessibilityHidden(isUITesting)
                        } else {
                            MarkdownPreviewWebView(
                                html: displayedDocument.html,
                                shouldScroll: shouldScroll,
                                onContentSizeChange: { metrics in
                                    guard !displayedDocument.isPendingActiveScale else { return }
                                    applyMarkdownMetrics(metrics, renderKey: displayedDocument.renderKey)
                                }
                            )
                            .frame(width: width, height: clampedHeight)
                            .accessibilityHidden(isUITesting)
                        }

                        // The shield covers first paints and real reloads only. While a stale
                        // document intentionally stays on screen (scale change or enrichment
                        // upgrade in flight), the last rendered content remains visible.
                        if !isLiveRender && !displayedDocument.isPendingActiveScale {
                            markdownReadinessShield(source: text, renderKey: renderKey)
                                .zIndex(1)
                        }

                        HStack(spacing: ScopySpacing.xs) {
                            markdownLayoutScaleControl()
                            exportResolutionMenu()
                            exportButton()
                        }
                            .padding(ScopySpacing.sm)
                            .zIndex(2)
                    }
                    .task(id: renderKey) {
                        initializePreviewLayoutScaleFromSettingsIfNeeded()
                        await withTaskGroup(of: Void.self) { group in
                            if settingsViewModel.settings.linkEnrichmentEnabled {
                                let markdown = text
                                group.addTask(priority: .utility) {
                                    await LinkEnrichmentCoordinator.shared.ensureEnrichment(markdown: markdown)
                                }
                            }
                            model.prepareMarkdownRender(for: renderKey)
                            if model.markdownMetricsLayoutScalePercent != layoutScale.rawValue {
                                markMarkdownPreviewAwaitingMetrics()
                            }
                            await prepareOverrideMarkdownHTMLIfNeeded(
                                source: text,
                                defaultHTML: html,
                                layoutScale: layoutScale,
                                renderKey: renderKey
                            )
                        }
                    }
                    .accessibilityIdentifier("History.Preview.Container")
                    .onReceive(NotificationCenter.default.publisher(for: .scopyLinkEnrichmentDidUpdate)) { notification in
                        guard let key = notification.userInfo?[LinkEnrichmentNotificationKey.contentKey] as? String,
                              key == LinkEnrichmentContentKey.make(for: text)
                        else { return }
                        linkEnrichmentRevision += 1
                    }
                    .background {
                        if isUITesting {
                            Text(
                                isLiveRender
                                    ? "rendered"
                                    : (model.markdownRenderErrorReason(for: renderKey) ?? "pending")
                            )
                                .font(.system(size: 1))
                                .opacity(0.001)
                                .accessibilityIdentifier("History.Preview.RenderStatus")
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .frame(width: width, height: clampedHeight)
                } else {
                    HoverPreviewTextView(text: text, font: font, width: width, shouldScroll: shouldScroll)
                        .frame(width: width, height: clampedHeight)
                }
            } else {
                ProgressView()
                    .frame(width: maxWidth, height: min(maxHeight, 160))
            }
        }
        .accessibilityIdentifier("History.Preview.Text")
        .accessibilityElement(children: .contain)
    }

    // MARK: - Export Button

    private struct MarkdownDisplayDocument {
        let html: String
        let renderKey: String
        let isPendingActiveScale: Bool
    }

    private enum MarkdownExportResolution: Int, CaseIterable, Identifiable {
        case x1 = 100
        case x1_5 = 150
        case x2 = 200

        var id: Int { rawValue }

        var scale: CGFloat { CGFloat(rawValue) / 100 }

        var label: String {
            switch self {
            case .x1: return "1x"
            case .x1_5: return "1.5x"
            case .x2: return "2x"
            }
        }
    }

    private var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitesting")
    }

    private var exportResolution: MarkdownExportResolution {
        MarkdownExportResolution(rawValue: exportResolutionPercent) ?? .x1
    }

    private var exportResolutionScale: CGFloat {
        exportResolution.scale
    }

    private var activeMarkdownLayoutScale: MarkdownChatGPTLayoutScalePercent {
        MarkdownChatGPTLayoutScalePercent(settingsValue: previewLayoutScalePercent)
    }

    private var settingsMarkdownLayoutScale: MarkdownChatGPTLayoutScalePercent {
        MarkdownChatGPTLayoutScalePercent(
            settingsValue: settingsViewModel.settings.markdownChatGPTLayoutScalePercent
        )
    }

    private var isMarkdownLayoutScaleControlExpanded: Bool {
        isMarkdownLayoutScaleControlHovered || isMarkdownLayoutScaleEditing
    }

    private func applyMarkdownMetrics(_ metrics: MarkdownContentMetrics, renderKey: String) {
        guard isContentCurrent() else { return }
        guard let text = model.text else { return }
        guard HoverPreviewModel.markdownRenderKey(
            source: text,
            layoutScale: activeMarkdownLayoutScale
        ) == renderKey else { return }
        guard metrics.renderSucceeded else {
            model.markdownMetricsLayoutScalePercent = nil
            model.markMarkdownRenderFailed(
                for: renderKey,
                reason: metrics.renderErrorReason ?? "markdown render failed"
            )
            return
        }

        model.markdownMetricsLayoutScalePercent = activeMarkdownLayoutScale.rawValue
        model.markMarkdownRenderSucceeded(for: renderKey)

        let newHeight = metrics.size.height
        let fixedWidth = HoverPreviewScreenMetrics.maxMarkdownPopoverWidthPoints()
        model.markdownContentSize = CGSize(width: fixedWidth, height: newHeight)
        if metrics.hasHorizontalOverflow {
            model.markdownHasHorizontalOverflow = true
        }
    }

    private static func initialPreviewLayoutScalePercent() -> Int {
        if UserDefaults.standard.object(forKey: previewLayoutScalePercentUserDefaultsKey) != nil {
            let stored = UserDefaults.standard.integer(forKey: previewLayoutScalePercentUserDefaultsKey)
            return MarkdownChatGPTLayoutScalePercent(settingsValue: stored).rawValue
        }
        return MarkdownRenderLayoutConstants.defaultChatGPTLayoutScale.rawValue
    }

    private func initializePreviewLayoutScaleFromSettingsIfNeeded() {
        guard !hasInitializedPreviewLayoutScale else { return }
        hasInitializedPreviewLayoutScale = true
        if UserDefaults.standard.object(forKey: Self.previewLayoutScalePercentUserDefaultsKey) == nil {
            let settingsScale = settingsMarkdownLayoutScale
            if previewLayoutScalePercent != settingsScale.rawValue, let text = model.text {
                model.prepareMarkdownRender(
                    for: HoverPreviewModel.markdownRenderKey(source: text, layoutScale: settingsScale)
                )
                previewLayoutScalePercent = settingsScale.rawValue
            }
        }
    }

    private func selectPreviewLayoutScalePercent(_ percent: Int) {
        let normalized = MarkdownChatGPTLayoutScalePercent(settingsValue: percent).rawValue
        guard previewLayoutScalePercent != normalized else { return }
        if let text = model.text {
            model.prepareMarkdownRender(
                for: HoverPreviewModel.markdownRenderKey(
                    source: text,
                    layoutScale: MarkdownChatGPTLayoutScalePercent(settingsValue: normalized)
                )
            )
        } else {
            model.invalidateMarkdownLiveRender()
        }
        previewLayoutScalePercent = normalized
        UserDefaults.standard.set(normalized, forKey: Self.previewLayoutScalePercentUserDefaultsKey)
    }

    private func markMarkdownPreviewAwaitingMetrics() {
        model.markdownMetricsLayoutScalePercent = nil
        model.markdownHasHorizontalOverflow = false
        model.invalidateMarkdownLiveRender()
    }

    @ViewBuilder
    private func markdownReadinessShield(source: String, renderKey: String) -> some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
            if let reason = model.markdownRenderErrorReason(for: renderKey), !reason.isEmpty {
                VStack(alignment: .leading, spacing: ScopySpacing.sm) {
                    Text("Preview unavailable")
                        .font(.system(size: 13, weight: .semibold))
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(source)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(ScopySpacing.md)
            } else {
                VStack(spacing: ScopySpacing.sm) {
                    ProgressView()
                    Text("Rendering preview…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func displayedMarkdownDocument(
        defaultHTML: String,
        defaultRenderKey: String,
        layoutScale: MarkdownChatGPTLayoutScalePercent,
        activeRenderKey: String,
        defaultHTMLIsFresh: Bool
    ) -> MarkdownDisplayDocument {
        if layoutScale == settingsMarkdownLayoutScale, defaultHTMLIsFresh {
            return MarkdownDisplayDocument(
                html: defaultHTML,
                renderKey: activeRenderKey,
                isPendingActiveScale: false
            )
        }
        if overrideMarkdownRenderKey == activeRenderKey, let overrideMarkdownHTML {
            return MarkdownDisplayDocument(
                html: overrideMarkdownHTML,
                renderKey: activeRenderKey,
                isPendingActiveScale: false
            )
        }
        if let overrideMarkdownHTML, let overrideMarkdownRenderKey {
            return MarkdownDisplayDocument(
                html: overrideMarkdownHTML,
                renderKey: overrideMarkdownRenderKey,
                isPendingActiveScale: true
            )
        }
        return MarkdownDisplayDocument(
            html: defaultHTML,
            renderKey: defaultRenderKey,
            isPendingActiveScale: true
        )
    }

    private func prepareOverrideMarkdownHTMLIfNeeded(
        source: String,
        defaultHTML _: String,
        layoutScale: MarkdownChatGPTLayoutScalePercent,
        renderKey: String
    ) async {
        guard isContentCurrent() else { return }
        let defaultHTMLIsFresh = model.markdownHTMLEnrichmentFingerprint
            == HoverPreviewModel.enrichmentFingerprint(for: source)
        if layoutScale == settingsMarkdownLayoutScale, defaultHTMLIsFresh {
            overrideMarkdownHTML = nil
            overrideMarkdownRenderKey = nil
            return
        }
        if overrideMarkdownRenderKey == renderKey, overrideMarkdownHTML != nil {
            return
        }

        try? await Task.sleep(nanoseconds: Self.markdownLayoutScaleRenderDebounceNanoseconds)
        guard !Task.isCancelled else { return }

        let html = await Task.detached(priority: .userInitiated) {
            let context = MarkdownRenderContextResolver.defaultContext(
                for: source,
                layoutScale: layoutScale
            )
            return MarkdownHTMLRenderer.render(markdown: source, context: context).html
        }.value
        guard !Task.isCancelled else { return }
        guard isContentCurrent() else { return }

        guard HoverPreviewModel.markdownRenderKey(
            source: source,
            layoutScale: activeMarkdownLayoutScale
        ) == renderKey else { return }
        overrideMarkdownHTML = html
        overrideMarkdownRenderKey = renderKey
        markMarkdownPreviewAwaitingMetrics()
    }

    private static func initialExportResolutionPercent() -> Int {
        let processInfo = ProcessInfo.processInfo
        if processInfo.arguments.contains("--uitesting") {
            return parseExportResolutionPercent(from: processInfo.environment[uiTestExportResolutionEnvKey]) ?? MarkdownExportResolution.x1.rawValue
        }

        let stored = UserDefaults.standard.integer(forKey: exportResolutionPercentUserDefaultsKey)
        if let resolution = MarkdownExportResolution(rawValue: stored) {
            return resolution.rawValue
        }
        return MarkdownExportResolution.x1.rawValue
    }

    private static func parseExportResolutionPercent(from raw: String?) -> Int? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lowered = trimmed.lowercased()
        let noSuffix: String
        if lowered.hasSuffix("x") {
            noSuffix = String(lowered.dropLast())
        } else {
            noSuffix = lowered
        }

        if let percent = Int(noSuffix), percent >= 50 {
            return MarkdownExportResolution(rawValue: percent)?.rawValue
        }
        if let multiplier = Double(noSuffix), multiplier > 0 {
            let percent = Int(round(multiplier * 100))
            return MarkdownExportResolution(rawValue: percent)?.rawValue
        }
        return nil
    }

    private func persistExportResolutionPercentIfNeeded() {
        guard !isUITesting else { return }
        UserDefaults.standard.set(exportResolutionPercent, forKey: Self.exportResolutionPercentUserDefaultsKey)
    }

    @ViewBuilder
    private func markdownLayoutScaleControl() -> some View {
        let isExpanded = isMarkdownLayoutScaleControlExpanded

        HStack(spacing: ScopySpacing.xs) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(ScopyColors.mutedText)
                .frame(width: 14, height: 14)

            Text(activeMarkdownLayoutScale.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(ScopyColors.mutedText)
                .monospacedDigit()
                .frame(width: 38, alignment: .leading)

            if isExpanded {
                Slider(
                    value: markdownLayoutScaleBinding,
                    in: Double(MarkdownChatGPTLayoutScalePercent.minimumRawValue)...Double(MarkdownChatGPTLayoutScalePercent.maximumRawValue),
                    onEditingChanged: { isEditing in
                        isMarkdownLayoutScaleEditing = isEditing
                    }
                )
                .frame(width: 126)
                .accessibilityIdentifier("History.Preview.MarkdownLayoutScaleSlider")
                .accessibilityLabel("Markdown preview layout scale")
                .accessibilityValue(activeMarkdownLayoutScale.label)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
            }
        }
        .frame(height: 28)
        .padding(.horizontal, isExpanded ? 10 : 8)
        .background(
            Capsule()
                .fill(ScopyColors.secondaryBackground.opacity(isExpanded ? 0.92 : 0.72))
        )
        .overlay(
            Capsule()
                .stroke(ScopyColors.separator.opacity(isExpanded ? 0.65 : 0.35), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(isExpanded ? 0.12 : 0.06), radius: isExpanded ? 8 : 4, y: 2)
        .opacity(isExpanded ? 0.98 : 0.82)
        .animation(.easeOut(duration: 0.16), value: isExpanded)
        .onHover { isMarkdownLayoutScaleControlHovered = $0 }
        .help("Markdown preview layout scale (\(activeMarkdownLayoutScale.label))")
    }

    private var markdownLayoutScaleBinding: Binding<Double> {
        Binding(
            get: {
                Double(activeMarkdownLayoutScale.rawValue)
            },
            set: { value in
                let percent = MarkdownChatGPTLayoutScalePercent.magneticValue(from: value)
                selectPreviewLayoutScalePercent(percent)
            }
        )
    }

    @ViewBuilder
    private func exportResolutionMenu() -> some View {
        Menu {
            ForEach(MarkdownExportResolution.allCases) { resolution in
                Button {
                    exportResolutionPercent = resolution.rawValue
                    persistExportResolutionPercentIfNeeded()
                } label: {
                    HStack {
                        if exportResolutionPercent == resolution.rawValue {
                            Image(systemName: "checkmark")
                        }
                        Text(resolution.label)
                    }
                }
            }
        } label: {
            Text(exportResolution.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(ScopyColors.mutedText)
                .frame(height: 24)
                .padding(.horizontal, 8)
                .background(
                    Capsule()
                        .fill(ScopyColors.secondaryBackground.opacity(0.9))
                )
                .overlay(
                    Capsule()
                        .stroke(ScopyColors.separator.opacity(0.5), lineWidth: 0.5)
                )
        }
        .menuStyle(.borderlessButton)
        .accessibilityIdentifier("History.Preview.ExportResolutionMenu")
        .accessibilityLabel("Export resolution")
        .accessibilityValue(exportResolution.label)
        .help("Export resolution (\(exportResolution.label))")
        .disabled(model.isExporting)
    }

    @ViewBuilder
    private func exportButton() -> some View {
        Button(action: { exportToPNG() }) {
            Group {
                if model.exportSuccess {
                    Image(systemName: "checkmark")
                        .foregroundColor(.green)
                } else if model.exportFailed {
                    Image(systemName: "xmark")
                        .foregroundColor(.red)
                } else if model.isExporting {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: ScopyIcons.image)
                        .foregroundColor(ScopyColors.mutedText)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .frame(width: 24, height: 24)
        }
        .accessibilityIdentifier("History.Preview.ExportButton")
        .accessibilityLabel("Export PNG")
        .accessibilityValue(model.exportSuccess ? "success" : (model.exportFailed ? "failed" : (model.isExporting ? "exporting" : "idle")))
        .buttonStyle(.plain)
        .background(
            Circle()
                .fill(ScopyColors.secondaryBackground.opacity(0.9))
        )
        .overlay(
            Circle()
                .stroke(ScopyColors.separator.opacity(0.5), lineWidth: 0.5)
        )
        .help(exportButtonHelpText)
        .disabled(model.isExporting)
    }

    private var exportButtonHelpText: String {
        if model.isExporting { return "Exporting PNG…" }
        if model.exportSuccess, let message = model.exportSuccessMessage, !message.isEmpty {
            return message
        }
        if model.exportFailed, let message = model.exportErrorMessage, !message.isEmpty {
            return "Export failed: \(message)"
        }
        return "Export as PNG to clipboard (\(exportResolution.label))"
    }

    private func exportToPNG() {
        guard isContentCurrent() else { return }
        guard !model.isExporting else { return }
        guard let html = model.markdownHTML else { return }

        let settings = settingsViewModel.settings

        guard let exportToken = model.beginExportAction() else { return }
        guard retainExplicitExport() else {
            model.cancelExportTasks()
            onInteractionLifecycleChange()
            return
        }
        let exportResolutionLabel = exportResolution.label
        let exportResolutionScale = exportResolutionScale
        let markdownSource = model.text ?? html
        let pasteboardWriteLease = MarkdownExportService.capturePasteboardWriteLease()

        let expectedCurrent = isExportContentCurrent
        model.exportActionTask = Task { @MainActor in
            let result = await HistoryItemMarkdownExportController.exportMarkdownToClipboard(
                markdownSource: markdownSource,
                settings: settings,
                layoutScale: activeMarkdownLayoutScale,
                resolutionScale: exportResolutionScale,
                pasteboardWriteLease: pasteboardWriteLease,
                authorizePasteboardWrite: {
                    model.authorizesExportAction(token: exportToken) && expectedCurrent()
                }
            )
            guard !Task.isCancelled,
                  expectedCurrent(),
                  model.authorizesExportAction(token: exportToken),
                  model.finishExportAction(token: exportToken) else {
                _ = model.finishExportAction(token: exportToken)
                onInteractionLifecycleChange()
                return
            }

            switch result {
            case .success(let stats):
                model.exportSuccess = true
                if let percent = stats.percentSaved {
                    if percent > 0 {
                        model.exportSuccessMessage = "Exported PNG (\(exportResolutionLabel), pngquant -\(percent)%)"
                    } else {
                        model.exportSuccessMessage = "Exported PNG (\(exportResolutionLabel), pngquant no change)"
                    }
                } else {
                    model.exportSuccessMessage = "Exported PNG (\(exportResolutionLabel))"
                }
                model.exportErrorMessage = nil
                model.exportFeedbackTask?.cancel()
                model.exportFeedbackTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard !Task.isCancelled, expectedCurrent() else { return }
                    model.exportSuccess = false
                    model.exportSuccessMessage = nil
                    model.exportFeedbackTask = nil
                    onInteractionLifecycleChange()
                }
            case .failure(let error):
                model.exportFailed = true
                model.exportErrorMessage = error.localizedDescription
                ScopyLog.ui.error("Export failed: \(error.localizedDescription, privacy: .public)")
                model.exportFeedbackTask?.cancel()
                model.exportFeedbackTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard !Task.isCancelled, expectedCurrent() else { return }
                    model.exportFailed = false
                    model.exportErrorMessage = nil
                    model.exportFeedbackTask = nil
                    onInteractionLifecycleChange()
                }
            }
            onInteractionLifecycleChange()
        }
        onInteractionLifecycleChange()
    }
}

private struct HoverPreviewTextView: NSViewRepresentable {
    let text: String
    let font: NSFont
    let width: CGFloat
    let shouldScroll: Bool

    @MainActor
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = shouldScroll
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = font
        textView.textColor = NSColor.labelColor
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.textContainerInset = NSSize(width: ScopySpacing.md, height: ScopySpacing.md)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0

        scrollView.documentView = textView

        context.coordinator.scrollView = scrollView
        context.coordinator.textView = textView
        context.coordinator.scrollbarAutoHider.attach(to: scrollView)
        return scrollView
    }

    @MainActor
    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }

        nsView.hasVerticalScroller = shouldScroll
        context.coordinator.scrollbarAutoHider.attach(to: nsView)
        context.coordinator.scrollbarAutoHider.applyHiddenState()

        let availableWidth = max(1, width)
        if context.coordinator.lastWidth != availableWidth {
            context.coordinator.lastWidth = availableWidth
            textView.frame.size.width = availableWidth
            if let textContainer = textView.textContainer {
                let insets = textView.textContainerInset
                textContainer.containerSize = NSSize(
                    width: max(1, availableWidth - insets.width * 2),
                    height: .greatestFiniteMagnitude
                )
            }
        }

        if context.coordinator.lastText != text {
            context.coordinator.lastText = text
            textView.string = text
        }
    }

    @MainActor
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        weak var scrollView: NSScrollView?
        weak var textView: NSTextView?
        var lastText: String = ""
        var lastWidth: CGFloat = 0
        let scrollbarAutoHider = ScrollbarAutoHider()
    }
}
