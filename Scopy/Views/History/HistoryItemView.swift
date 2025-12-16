import SwiftUI
import AppKit
import ImageIO
import ScopyKit
import ScopyUISupport

// MARK: - History Item View (v0.9.3 - 性能优化版)

/// 单个历史项视图 - 实现 Equatable 以优化重绘
/// v0.9.3: 使用局部悬停状态 + 防抖 + Equatable 优化滚动性能
struct HistoryItemView: View, Equatable {
    let item: ClipboardItemDTO
    let isKeyboardSelected: Bool
    let isScrolling: Bool
    let settings: SettingsDTO

    // 回调闭包 - 不参与 Equatable 比较
    let onSelect: () -> Void
    let onHoverSelect: (UUID) -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void
    let getImageData: () async -> Data?

    // 局部状态 - 悬停不触发全局重绘
    @State private var isHovering = false
    @State private var hoverDebounceTask: Task<Void, Never>?
    @State private var hoverPreviewTask: Task<Void, Never>?
    @State private var hoverMarkdownTask: Task<Void, Never>?
    @State private var markdownWebViewController: MarkdownPreviewWebViewController?
    // v0.24: 延迟隐藏预览，避免 popover 触发 hover false 导致闪烁
    @State private var hoverExitTask: Task<Void, Never>?
    @State private var isPopoverHovering = false
    @State private var showPreview = false
    // v0.15: Text preview state
    @State private var showTextPreview = false
    @StateObject private var previewModel = HoverPreviewModel()

    // MARK: - Equatable

    nonisolated static func == (lhs: HistoryItemView, rhs: HistoryItemView) -> Bool {
        lhs.item.id == rhs.item.id &&
        lhs.item.lastUsedAt == rhs.item.lastUsedAt &&
        lhs.item.isPinned == rhs.item.isPinned &&
        lhs.item.thumbnailPath == rhs.item.thumbnailPath &&
        lhs.isKeyboardSelected == rhs.isKeyboardSelected &&
        lhs.isScrolling == rhs.isScrolling &&
        lhs.settings.showImageThumbnails == rhs.settings.showImageThumbnails &&
        lhs.settings.thumbnailHeight == rhs.settings.thumbnailHeight
    }

    // MARK: - Computed Properties

    private var backgroundColor: Color {
        if isKeyboardSelected {
            return ScopyColors.selection
        } else if isHovering {
            return ScopyColors.hover
        } else {
            return Color.clear
        }
    }

    /// v0.12: 优先使用预加载缓存，避免主线程阻塞
    private var appIcon: NSImage? {
        guard let bundleID = item.appBundleID else { return nil }
        return IconService.shared.icon(bundleID: bundleID)
    }

    private var thumbnailHeight: CGFloat {
        CGFloat(settings.thumbnailHeight)
    }

    private var previewDelay: TimeInterval {
        settings.imagePreviewDelay
    }

    private var showThumbnails: Bool {
        settings.showImageThumbnails
    }

    /// v0.21: 使用预计算的 metadata，避免视图渲染时 O(n) 字符串操作
    private var metadataText: String {
        item.metadata
    }

    /// v0.15: Simplified content view - removed app icon, using new metadata format
    @ViewBuilder
    private var contentView: some View {
        switch item.type {
        case .image where showThumbnails:
            // v0.15.1: 图片有缩略图时，只显示缩略图和大小，不显示 "Image" 标题
            HStack(spacing: ScopySpacing.md) {
                HistoryItemThumbnailView(thumbnailPath: item.thumbnailPath, height: thumbnailHeight, isScrolling: isScrolling)
                Text(metadataText)
                    .font(.system(size: 10))
                    .foregroundStyle(ScopyColors.mutedText)
                    .lineLimit(1)
            }
        case .file:
            VStack(alignment: .leading, spacing: ScopySpacing.xxs) {
                HStack(spacing: ScopySpacing.sm) {
                    Image(systemName: ScopyIcons.file)
                        .foregroundStyle(Color.accentColor)
                    Text(item.title)
                        .font(ScopyTypography.body)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(metadataText)
                    .font(.system(size: 10))  // v0.15.1: 比主内容小2号
                    .foregroundStyle(ScopyColors.mutedText)
                    .lineLimit(1)
                    .padding(.leading, ScopySpacing.md)  // v0.15.1: 缩进两格
            }
        case .image:
            VStack(alignment: .leading, spacing: ScopySpacing.xxs) {
                HStack(spacing: ScopySpacing.sm) {
                    Image(systemName: ScopyIcons.image)
                        .foregroundStyle(.green)
                    Text(item.title)
                        .font(ScopyTypography.body)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(metadataText)
                    .font(.system(size: 10))  // v0.15.1: 比主内容小2号
                    .foregroundStyle(ScopyColors.mutedText)
                    .lineLimit(1)
                    .padding(.leading, ScopySpacing.md)  // v0.15.1: 缩进两格
            }
        default:
            VStack(alignment: .leading, spacing: ScopySpacing.xxs) {
                Text(item.title)
                    .font(ScopyTypography.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(metadataText)
                    .font(.system(size: 10))  // v0.15: 比主内容小2号
                    .foregroundStyle(ScopyColors.mutedText)
                    .lineLimit(1)
                    .padding(.leading, ScopySpacing.md)  // v0.15: 缩进两格
            }
        }
    }

    // MARK: - Body

    var body: some View {
        HStack(alignment: .center, spacing: ScopySpacing.sm) {
            // Pin 标记：左侧颜色条
            if item.isPinned {
                Capsule()
                    .fill(ScopyColors.selectionBorder)
                    .frame(width: ScopySize.Width.pinIndicator, height: ScopySize.Height.pinIndicator)
            }

            // App 图标 (v0.15: 保留图标，只移除元数据中的应用名称)
            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: ScopySize.Icon.listApp, height: ScopySize.Icon.listApp)
                    .cornerRadius(ScopySize.Corner.sm)
            } else {
                Image(systemName: ScopyIcons.app)
                    .font(.system(size: ScopySize.Icon.sm))
                    .foregroundStyle(ScopyColors.mutedText)
                    .frame(width: ScopySize.Icon.listApp, height: ScopySize.Icon.listApp)
            }

            contentView

            Spacer(minLength: ScopySpacing.md)

            HStack(alignment: .center, spacing: ScopySpacing.sm) {
                if item.isPinned {
                    Image(systemName: ScopyIcons.pin)
                        .font(.system(size: ScopySize.Icon.pin))
                        .foregroundStyle(.orange)
                }

                Text(relativeTime)
                    .font(ScopyTypography.microMono)
                    .foregroundStyle(ScopyColors.mutedText)
            }
        }
        .padding(.horizontal, ScopySpacing.md)
        .padding(.vertical, ScopySpacing.sm)
        .frame(minHeight: item.type == .image && showThumbnails ? thumbnailHeight + ScopySpacing.lg : ScopySize.Height.listItem)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ScopySize.Corner.lg, style: .continuous)
                .fill(backgroundColor)
        )
        // v0.10.3: 键盘选中时添加边框
        .overlay(
            RoundedRectangle(cornerRadius: ScopySize.Corner.lg, style: .continuous)
                .stroke(isKeyboardSelected ? ScopyColors.selectionBorder : Color.clear, lineWidth: ScopySize.Stroke.medium)
        )
        // v0.10.3: 添加选中/悬停态过渡动效
        .animation(isScrolling ? nil : .easeInOut(duration: 0.15), value: isHovering)
        .animation(isScrolling ? nil : .easeInOut(duration: 0.15), value: isKeyboardSelected)
        .padding(.horizontal, ScopySpacing.md) // Outer padding for floating effect
        .onTapGesture {
            onSelect()
        }
        // v0.9.3: 局部悬停状态 + 防抖更新全局选中
        // v0.10.3: 使用 Task 替代 Timer，自动取消防止泄漏
        // v0.15: 添加文本预览支持
        .onHover { hovering in
            if isScrolling {
                if isHovering {
                    isHovering = false
                }
                return
            }

            isHovering = hovering

            // 取消之前的防抖任务
            hoverDebounceTask?.cancel()
            // 取消之前的退出清理任务
            hoverExitTask?.cancel()
            hoverExitTask = nil

            if hovering {
                // 静止 150ms 后才更新全局选中状态
                if !isScrolling {
                    hoverDebounceTask = Task {
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            onHoverSelect(item.id)
                        }
                    }
                }

                // 图片预览任务
                if item.type == .image && showThumbnails {
                    startPreviewTask()
                }
                // v0.15: 文本预览任务
                else if item.type == .text || item.type == .rtf || item.type == .html {
                    startTextPreviewTask()
                }
	            } else {
	                // v0.24: popover 出现/消失时可能短暂触发 hover false，做 120ms 退出防抖
	                hoverExitTask = Task {
	                    try? await Task.sleep(nanoseconds: 120_000_000)
	                    guard !Task.isCancelled else { return }
	                    await MainActor.run {
	                        guard !self.isHovering, !self.isPopoverHovering else { return }
	                        self.cancelPreviewTask()
	                        self.showPreview = false
	                        self.showTextPreview = false
	                        self.previewModel.previewCGImage = nil
	                        self.previewModel.text = nil  // v0.15: Reset text preview content
	                        self.previewModel.markdownHTML = nil
	                        self.previewModel.markdownContentSize = nil
	                        self.previewModel.isMarkdown = false
	                        self.markdownWebViewController = nil
	                    }
	                }
	            }
	        }
        .popover(isPresented: $showPreview, arrowEdge: .trailing) {
            HistoryItemImagePreviewView(model: previewModel, thumbnailPath: item.thumbnailPath)
                .onHover { hovering in
                    isPopoverHovering = hovering
                    if hovering {
                        hoverExitTask?.cancel()
                        hoverExitTask = nil
                    } else if !isHovering {
                        // popover 退出且行未悬停时，触发同样的延迟清理
                        hoverExitTask?.cancel()
                        hoverExitTask = Task {
                            try? await Task.sleep(nanoseconds: 120_000_000)
                            guard !Task.isCancelled else { return }
                            await MainActor.run {
                                guard !self.isHovering, !self.isPopoverHovering else { return }
                                self.cancelPreviewTask()
                                self.showPreview = false
                                self.previewModel.previewCGImage = nil
                            }
                        }
                    }
                }
        }
	        .popover(isPresented: $showTextPreview, arrowEdge: .trailing) {
	            HistoryItemTextPreviewView(model: previewModel, markdownWebViewController: markdownWebViewController)
	                .onHover { hovering in
	                    isPopoverHovering = hovering
	                    if hovering {
                        hoverExitTask?.cancel()
                        hoverExitTask = nil
                    } else if !isHovering {
                        hoverExitTask?.cancel()
                        hoverExitTask = Task {
                            try? await Task.sleep(nanoseconds: 120_000_000)
                            guard !Task.isCancelled else { return }
                            await MainActor.run {
                                guard !self.isHovering, !self.isPopoverHovering else { return }
                                self.cancelPreviewTask()
                                self.showTextPreview = false
                                self.previewModel.text = nil
	                                self.previewModel.markdownHTML = nil
	                                self.previewModel.markdownContentSize = nil
	                                self.previewModel.isMarkdown = false
	                                self.markdownWebViewController = nil
	                            }
	                        }
	                    }
	                }
	        }
        .contextMenu {
            Button("Copy") {
                onSelect()
            }
            Button(item.isPinned ? "Unpin" : "Pin") {
                onTogglePin()
            }
            Divider()
            Button("Delete", role: .destructive) {
                onDelete()
            }
        }
        // v0.17: 增强任务清理 - 确保视图消失时释放所有任务引用
	        .onDisappear {
            hoverDebounceTask?.cancel()
            hoverDebounceTask = nil
            hoverExitTask?.cancel()
            hoverExitTask = nil
            cancelPreviewTask()
            // 清理状态，防止内存泄漏
            previewModel.previewCGImage = nil
            previewModel.text = nil
	            previewModel.markdownHTML = nil
	            previewModel.markdownContentSize = nil
	            previewModel.markdownHasHorizontalOverflow = false
	            previewModel.isMarkdown = false
	            markdownWebViewController = nil
	        }
	        .onChange(of: isScrolling) { _, newValue in
            guard newValue else { return }
            isHovering = false
            hoverDebounceTask?.cancel()
            hoverDebounceTask = nil
            hoverExitTask?.cancel()
            hoverExitTask = nil
            cancelPreviewTask()
            showPreview = false
            showTextPreview = false
            isPopoverHovering = false
            previewModel.previewCGImage = nil
            previewModel.text = nil
	            previewModel.markdownHTML = nil
	            previewModel.markdownContentSize = nil
	            previewModel.markdownHasHorizontalOverflow = false
	            previewModel.isMarkdown = false
	            markdownWebViewController = nil
	        }
	        .background(markdownPreMeasureView)
	    }

    @ViewBuilder
    private var markdownPreMeasureView: some View {
        if isHovering,
           previewModel.isMarkdown,
           !showTextPreview,
           previewModel.markdownContentSize == nil,
           let html = previewModel.markdownHTML,
           let text = previewModel.text
        {
            let maxWidth: CGFloat = HoverPreviewScreenMetrics.maxPopoverWidthPoints()
            let containerWidth = max(1, maxWidth)

            if let controller = markdownWebViewController {
                MarkdownPreviewMeasurer(
                    controller: controller,
                    html: html,
                    containerWidth: containerWidth,
                    settleNanoseconds: 90_000_000,
                    onStableMetrics: { metrics in
                        guard self.isHovering else { return }
                        guard self.previewModel.markdownHTML == html else { return }
                        guard self.previewModel.text == text else { return }
                        self.previewModel.markdownContentSize = metrics.size
                        self.previewModel.markdownHasHorizontalOverflow = metrics.hasHorizontalOverflow
                        self.showTextPreview = true
                    }
                )
            }
        }
    }

    // MARK: - Preview Task
    // v0.10.3: 使用 Task 替代 Timer，自动取消防止泄漏

    /// v0.12: 完善取消检查，获取数据后也检查取消状态
    /// v0.22: 确保在创建新任务前取消旧任务，防止快速悬停时任务累积导致内存泄漏
    private func startPreviewTask() {
        // 先取消旧任务，防止多个任务同时运行
        hoverPreviewTask?.cancel()
        hoverPreviewTask = nil

        hoverPreviewTask = Task(priority: .userInitiated) { @MainActor in
            let delayNanos = UInt64(previewDelay * 1_000_000_000)
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            let targetWidthPoints = ScopySize.Width.previewMax
            let targetWidthPixels = max(1, Int(targetWidthPoints * scale))
            let maxLongSidePixels = 12_000

            // v0.43.6: 预取 preview 数据（在 hover delay 内完成 IO/downsample），减少 popover 出现后的等待与“重悬停才显示”的体感。
            let prefetchDelayNanos: UInt64 = min(50_000_000, delayNanos)
            let storageRef = item.storageRef
            let preparedPreviewImage: Task<CGImage?, Never> = Task(priority: .userInitiated) { @MainActor in
                if prefetchDelayNanos > 0 {
                    try? await Task.sleep(nanoseconds: prefetchDelayNanos)
                }
                guard !Task.isCancelled else { return nil }
                guard !isScrolling else { return nil }
                guard isHovering else { return nil }

                let cgImage: CGImage?
                if let storageRef, !storageRef.isEmpty {
                    cgImage = await Task.detached(priority: .userInitiated) {
                        Self.makePreviewCGImage(fromFileAtPath: storageRef, targetWidthPixels: targetWidthPixels, maxLongSidePixels: maxLongSidePixels)
                    }.value
                } else {
                    guard let data = await getImageData() else { return nil }
                    cgImage = await Task.detached(priority: .userInitiated) {
                        Self.makePreviewCGImage(from: data, targetWidthPixels: targetWidthPixels, maxLongSidePixels: maxLongSidePixels)
                    }.value
                }

                guard !Task.isCancelled else { return nil }
                guard !isScrolling else { return nil }
                guard isHovering else { return nil }
                previewModel.previewCGImage = cgImage
                return cgImage
            }
            defer { preparedPreviewImage.cancel() }

            try? await Task.sleep(nanoseconds: delayNanos)
            guard !Task.isCancelled else { return }
            guard !isScrolling else { return }
            guard isHovering else { return }

            self.showPreview = true

            if let cgImage = await preparedPreviewImage.value {
                guard !Task.isCancelled else { return }
                previewModel.previewCGImage = cgImage
            }

        }
    }

    nonisolated private static func makePreviewCGImage(from data: Data, targetWidthPixels: Int, maxLongSidePixels: Int) -> CGImage? {
        guard targetWidthPixels > 0, maxLongSidePixels > 0 else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return makePreviewCGImage(from: source, targetWidthPixels: targetWidthPixels, maxLongSidePixels: maxLongSidePixels)
    }

    nonisolated private static func makePreviewCGImage(fromFileAtPath path: String, targetWidthPixels: Int, maxLongSidePixels: Int) -> CGImage? {
        guard targetWidthPixels > 0, maxLongSidePixels > 0 else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return makePreviewCGImage(from: source, targetWidthPixels: targetWidthPixels, maxLongSidePixels: maxLongSidePixels)
    }

    nonisolated private static func makePreviewCGImage(from source: CGImageSource, targetWidthPixels: Int, maxLongSidePixels: Int) -> CGImage? {
        let requestedMax = computeRequestedMaxPixelSize(
            source: source,
            targetWidthPixels: targetWidthPixels,
            maxLongSidePixels: maxLongSidePixels
        )
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: requestedMax,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    nonisolated private static func computeRequestedMaxPixelSize(
        source: CGImageSource,
        targetWidthPixels: Int,
        maxLongSidePixels: Int
    ) -> Int {
        let fallback = min(maxLongSidePixels, max(targetWidthPixels, 1))
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return fallback
        }
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard w > 0, h > 0 else { return fallback }

        let expectedScaledHeight = Int((Double(h) * Double(targetWidthPixels) / Double(w)).rounded(.up))
        let requested = max(targetWidthPixels, expectedScaledHeight)
        return min(maxLongSidePixels, max(1, requested))
    }

    private func cancelPreviewTask() {
        hoverPreviewTask?.cancel()
        hoverPreviewTask = nil
        hoverMarkdownTask?.cancel()
        hoverMarkdownTask = nil
    }

    // MARK: - Text Preview (v0.15)

    /// v0.15.1: Start text preview task - uses `plainText` (full content) and lazily upgrades to Markdown preview when detected.
    /// v0.22: 确保在创建新任务前取消旧任务，防止快速悬停时任务累积导致内存泄漏
    private func startTextPreviewTask() {
        // 先取消旧任务，防止多个任务同时运行
        hoverPreviewTask?.cancel()
        hoverPreviewTask = nil
        hoverMarkdownTask?.cancel()
        hoverMarkdownTask = nil

        hoverPreviewTask = Task(priority: .userInitiated) { @MainActor in
            // Wait for preview delay
            let delayNanos = UInt64(previewDelay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delayNanos)
            guard !Task.isCancelled else { return }
            guard !isScrolling else { return }
            guard isHovering else { return }

            let text = item.plainText
            let preview = text.isEmpty ? "(Empty)" : text

            let isMarkdown = MarkdownDetector.isLikelyMarkdown(preview)
            if self.isHovering {
                self.previewModel.text = preview
                self.previewModel.isMarkdown = isMarkdown
                self.previewModel.markdownHTML = nil
                self.previewModel.markdownContentSize = nil
                self.previewModel.markdownHasHorizontalOverflow = false
                self.showTextPreview = !isMarkdown
            }

            guard isMarkdown else { return }
            // Avoid heavy Markdown -> HTML render for very large clipboard payloads.
            guard preview.utf16.count <= 200_000 else { return }

            let cacheKey = item.contentHash
            if let cached = MarkdownPreviewCache.shared.html(forKey: cacheKey) {
                if self.isHovering, self.previewModel.text == preview {
                    self.previewModel.markdownHTML = cached
                    if self.markdownWebViewController == nil {
                        self.markdownWebViewController = MarkdownPreviewWebViewController()
                    }
                }
                return
            }

            hoverMarkdownTask = Task.detached(priority: .utility) {
                let html = MarkdownHTMLRenderer.render(markdown: preview)
                MarkdownPreviewCache.shared.setHTML(html, forKey: cacheKey)
                await MainActor.run {
                    guard self.isHovering, self.previewModel.text == preview else { return }
                    self.previewModel.markdownHTML = html
                    if self.markdownWebViewController == nil {
                        self.markdownWebViewController = MarkdownPreviewWebViewController()
                    }
                }
            }
        }
    }

    // MARK: - Relative Time Formatting

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    /// v0.21: 缓存当前时间引用，避免每次渲染创建新 Date
    /// v0.23: 修复缓存实现 - 在锁外获取时间戳，锁内只做比较和更新
    private static var cachedNow: Date = Date()
    private static var cachedNowTimestamp: TimeInterval = Date().timeIntervalSince1970
    private static let relativeTimeLock = NSLock()

    private var relativeTime: String {
        // v0.23: 在锁外获取当前时间戳，避免在锁内创建 Date 对象
        let currentTimestamp = Date().timeIntervalSince1970

        // 使用锁保护静态缓存的读写
        let now = Self.relativeTimeLock.withLock { () -> Date in
            // 每 30 秒更新一次 cachedNow
            if currentTimestamp - Self.cachedNowTimestamp > 30 {
                Self.cachedNow = Date(timeIntervalSince1970: currentTimestamp)
                Self.cachedNowTimestamp = currentTimestamp
            }
            return Self.cachedNow
        }

        return Self.relativeFormatter.localizedString(for: item.lastUsedAt, relativeTo: now)
    }

    /// v0.12: 使用全局缓存获取应用名称，避免重复调用 NSWorkspace
    private func appName(for bundleID: String) -> String {
        return IconService.shared.appName(bundleID: bundleID)
    }

    private func formatBytes(_ bytes: Int) -> String {
        Localization.formatBytes(bytes)
    }
}

private struct MarkdownPreviewMeasurer: View {
    let controller: MarkdownPreviewWebViewController
    let html: String
    let containerWidth: CGFloat
    let settleNanoseconds: UInt64
    let onStableMetrics: @MainActor (MarkdownContentMetrics) -> Void

    @State private var pendingMetrics: MarkdownContentMetrics?
    @State private var settleTask: Task<Void, Never>?

    var body: some View {
        ReusableMarkdownPreviewWebView(
            controller: controller,
            html: html,
            shouldScroll: false,
            onContentSizeChange: { metrics in
                pendingMetrics = metrics
                settleTask?.cancel()
                settleTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: settleNanoseconds)
                    guard !Task.isCancelled else { return }
                    guard let final = pendingMetrics else { return }
                    onStableMetrics(final)
                }
            }
        )
        .frame(width: max(1, containerWidth), height: 1)
        .opacity(0.001)
        .allowsHitTesting(false)
        .onDisappear {
            settleTask?.cancel()
            settleTask = nil
        }
    }
}
