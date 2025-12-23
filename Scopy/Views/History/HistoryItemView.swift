import SwiftUI
import AppKit
import ImageIO
import ScopyKit
import ScopyUISupport

// MARK: - History Item View (v0.9.3 - 性能优化版)

private struct SendableCGImage: @unchecked Sendable {
    let image: CGImage
}

/// 单个历史项视图 - 实现 Equatable 以优化重绘
/// v0.9.3: 使用局部悬停状态 + 防抖 + Equatable 优化滚动性能
@MainActor
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
    let markdownWebViewController: MarkdownPreviewWebViewController
    let isImagePreviewPresented: Bool
    let isTextPreviewPresented: Bool
    let requestPopover: (HoverPreviewPopoverKind?) -> Void
    let dismissOtherPopovers: () -> Void

    // 局部状态 - 悬停不触发全局重绘
    @State private var isHovering = false
    @State private var hoverDebounceTask: Task<Void, Never>?
    @State private var hoverPreviewTask: Task<Void, Never>?
    @State private var hoverMarkdownTask: Task<Void, Never>?
    // v0.24: 延迟隐藏预览，避免 popover 触发 hover false 导致闪烁
    @State private var hoverExitTask: Task<Void, Never>?
    @State private var isPopoverHovering = false
    @State private var imagePopoverToken = UUID()
    @State private var textPopoverToken = UUID()
    // v0.15: Text preview state
    @StateObject private var previewModel = HoverPreviewModel()
    @State private var relativeTimeText: String = ""
    @State private var isUITestTapPreviewEnabled: Bool = false

    init(
        item: ClipboardItemDTO,
        isKeyboardSelected: Bool,
        isScrolling: Bool,
        settings: SettingsDTO,
        onSelect: @escaping () -> Void,
        onHoverSelect: @escaping (UUID) -> Void,
        onTogglePin: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        getImageData: @escaping () async -> Data?,
        markdownWebViewController: MarkdownPreviewWebViewController,
        isImagePreviewPresented: Bool,
        isTextPreviewPresented: Bool,
        requestPopover: @escaping (HoverPreviewPopoverKind?) -> Void,
        dismissOtherPopovers: @escaping () -> Void
    ) {
        self.item = item
        self.isKeyboardSelected = isKeyboardSelected
        self.isScrolling = isScrolling
        self.settings = settings
        self.onSelect = onSelect
        self.onHoverSelect = onHoverSelect
        self.onTogglePin = onTogglePin
        self.onDelete = onDelete
        self.getImageData = getImageData
        self.markdownWebViewController = markdownWebViewController
        self.isImagePreviewPresented = isImagePreviewPresented
        self.isTextPreviewPresented = isTextPreviewPresented
        self.requestPopover = requestPopover
        self.dismissOtherPopovers = dismissOtherPopovers
        _relativeTimeText = State(initialValue: Self.makeRelativeTimeString(for: item.lastUsedAt))
    }

    // MARK: - Equatable

    nonisolated static func == (lhs: HistoryItemView, rhs: HistoryItemView) -> Bool {
        lhs.item.id == rhs.item.id &&
        lhs.item.lastUsedAt == rhs.item.lastUsedAt &&
        lhs.item.isPinned == rhs.item.isPinned &&
        lhs.item.thumbnailPath == rhs.item.thumbnailPath &&
        lhs.isKeyboardSelected == rhs.isKeyboardSelected &&
        lhs.isScrolling == rhs.isScrolling &&
        lhs.isImagePreviewPresented == rhs.isImagePreviewPresented &&
        lhs.isTextPreviewPresented == rhs.isTextPreviewPresented &&
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

    @ViewBuilder
    var body: some View {
        if isScrolling {
            rowContent
        } else {
            rowContent.onHover(perform: handleHover)
        }
    }

    private var rowContent: some View {
        let imageToken = imagePopoverToken
        let textToken = textPopoverToken

        return HStack(alignment: .center, spacing: ScopySpacing.sm) {
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

                Text(relativeTimeText.isEmpty ? relativeTime : relativeTimeText)
                    .font(ScopyTypography.microMono)
                    .foregroundStyle(ScopyColors.mutedText)
            }
        }
        .padding(.horizontal, ScopySpacing.md)
        .padding(.vertical, ScopySpacing.sm)
        .frame(minHeight: item.type == .image && showThumbnails ? thumbnailHeight + ScopySpacing.lg : ScopySize.Height.listItem)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isKeyboardSelected || isHovering {
                RoundedRectangle(cornerRadius: ScopySize.Corner.lg, style: .continuous)
                    .fill(backgroundColor)
            }
        }
        // v0.10.3: 键盘选中时添加边框
        .overlay {
            if isKeyboardSelected {
                RoundedRectangle(cornerRadius: ScopySize.Corner.lg, style: .continuous)
                    .stroke(ScopyColors.selectionBorder, lineWidth: ScopySize.Stroke.medium)
            }
        }
        // v0.10.3: 添加选中/悬停态过渡动效
        .animation(isScrolling ? nil : .easeInOut(duration: 0.15), value: isHovering)
        .animation(isScrolling ? nil : .easeInOut(duration: 0.15), value: isKeyboardSelected)
        .padding(.horizontal, ScopySpacing.md) // Outer padding for floating effect
        .onTapGesture {
            if isUITestTapPreviewEnabled {
                // UI 测试预览模式下避免关闭面板，允许预览弹窗出现
                dismissOtherPopovers()
                isHovering = true
                isPopoverHovering = true
                if item.type == .image && showThumbnails {
                    startPreviewTask()
                } else if item.type == .text || item.type == .rtf || item.type == .html {
                    startTextPreviewTask()
                }
            } else {
                onSelect()
            }
        }
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--uitesting") {
                isUITestTapPreviewEnabled = (ProcessInfo.processInfo.environment["SCOPY_UITEST_OPEN_PREVIEW_ON_TAP"] == "1")
            } else {
                isUITestTapPreviewEnabled = false
            }
        }
        .onChange(of: item.lastUsedAt) { _, _ in
            updateRelativeTimeText()
        }
        .popover(
            isPresented: Binding(
                get: { isImagePreviewPresented },
                set: { presented in
                    if presented {
                        requestPopover(.image)
                        return
                    }
                    // Ignore delayed dismiss callbacks from a previous popover session.
                    guard imageToken == imagePopoverToken else { return }
                    requestPopover(nil)
                }
            ),
            arrowEdge: .trailing
        ) {
            HistoryItemImagePreviewView(model: previewModel, thumbnailPath: item.thumbnailPath)
                .background(
                    PopoverWindowCloseObserver {
                        // `onHover(false)` / `onDisappear` is not guaranteed to run when the system dismisses a popover.
                        // Observe the underlying popover window close to keep state in sync.
                        guard imageToken == imagePopoverToken else { return }
                        isPopoverHovering = false
                        DispatchQueue.main.async {
                            guard imageToken == imagePopoverToken else { return }
                            if !isHovering {
                                resetPreviewState(hidePopovers: true)
                            }
                        }
                    }
                    .allowsHitTesting(false)
                )
                .onHover { hovering in
                    isPopoverHovering = hovering
                    if hovering {
                        cancelHoverExitTask()
                    } else if !isHovering {
                        // popover 退出且行未悬停时，触发同样的延迟清理
                        scheduleHoverExitCleanup()
                    }
                }
                .onDisappear {
                    // `onHover(false)` is not guaranteed to fire when the popover is dismissed by the system.
                    // Keep local/global state in sync so the same row can be re-presented reliably.
                    guard imageToken == imagePopoverToken else { return }
                    isPopoverHovering = false
                    DispatchQueue.main.async {
                        guard imageToken == imagePopoverToken else { return }
                        if !isHovering {
                            resetPreviewState(hidePopovers: true)
                        }
                    }
                }
        }
        .popover(
            isPresented: Binding(
                get: { isTextPreviewPresented },
                set: { presented in
                    if presented {
                        requestPopover(.text)
                        return
                    }
                    // Ignore delayed dismiss callbacks from a previous popover session.
                    guard textToken == textPopoverToken else { return }
                    requestPopover(nil)
                }
            ),
            arrowEdge: .trailing
        ) {
            HistoryItemTextPreviewView(model: previewModel, markdownWebViewController: markdownWebViewController)
                .background(
                    PopoverWindowCloseObserver {
                        // `onHover(false)` / `onDisappear` is not guaranteed to run when the system dismisses a popover.
                        // Observe the underlying popover window close to keep state in sync.
                        guard textToken == textPopoverToken else { return }
                        isPopoverHovering = false
                        DispatchQueue.main.async {
                            guard textToken == textPopoverToken else { return }
                            if !isHovering {
                                resetPreviewState(hidePopovers: true)
                            }
                        }
                    }
                    .allowsHitTesting(false)
                )
                .onHover { hovering in
                    isPopoverHovering = hovering
                    if hovering {
                        cancelHoverExitTask()
                    } else if !isHovering {
                        scheduleHoverExitCleanup()
                    }
                }
                .onDisappear {
                    // `onHover(false)` is not guaranteed to fire when the popover is dismissed by the system.
                    // Keep local/global state in sync so the same row can be re-presented reliably.
                    guard textToken == textPopoverToken else { return }
                    isPopoverHovering = false
                    DispatchQueue.main.async {
                        guard textToken == textPopoverToken else { return }
                        if !isHovering {
                            resetPreviewState(hidePopovers: true)
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
            cancelHoverTasks()
            resetPreviewState(hidePopovers: true)
        }
        .onChange(of: isScrolling) { _, newValue in
            if !newValue {
                updateRelativeTimeText()
                return
            }
            guard shouldResetPreviewOnScroll else { return }
            isHovering = false
            cancelHoverTasks()
            resetPreviewState(hidePopovers: true)
        }
        .background {
            if isImagePreviewPresented || isTextPreviewPresented {
                ScrollWheelDismissMonitor(
                    isActive: true,
                    onScrollWheel: dismissPreviewForScrollWheel
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .background(markdownPreMeasureView)
    }

    private func handleHover(_ hovering: Bool) {
        if isScrolling {
            if isHovering {
                isHovering = false
            }
            return
        }

        if hovering {
            dismissOtherPopovers()
        }
        isHovering = hovering

        cancelHoverDebounceTask()
        cancelHoverExitTask()

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
            cancelPreviewTask()
            scheduleHoverExitCleanup()
        }
    }

    @ViewBuilder
    private var markdownPreMeasureView: some View {
        if isHovering,
           previewModel.isMarkdown,
           (!isTextPreviewPresented || markdownWebViewController.webView.superview == nil),
           previewModel.markdownContentSize == nil,
           let html = previewModel.markdownHTML,
           let text = previewModel.text
        {
            let maxWidth: CGFloat = HoverPreviewScreenMetrics.maxPopoverWidthPoints()
            let containerWidth = max(1, maxWidth)
            let cacheKey = item.contentHash
            let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            let padding: CGFloat = ScopySpacing.md
            let fallbackWidth = HoverPreviewTextSizing.preferredWidth(
                for: text,
                font: font,
                padding: padding,
                maxWidth: maxWidth
            )

            MarkdownPreviewMeasurer(
                controller: markdownWebViewController,
                html: html,
                containerWidth: containerWidth,
                settleNanoseconds: 90_000_000,
                onStableMetrics: { metrics in
                    guard self.isHovering else { return }
                    guard self.previewModel.markdownHTML == html else { return }
                    guard self.previewModel.text == text else { return }
                    let stableWidth: CGFloat = {
                        let w = metrics.size.width
                        guard w.isFinite, w > 0 else { return fallbackWidth }
                        if w < 40 { return fallbackWidth }
                        if fallbackWidth.isFinite, fallbackWidth > 0, w < fallbackWidth * 0.5 { return fallbackWidth }
                        return min(maxWidth, w)
                    }()
                    let stableSize = CGSize(width: max(1, stableWidth), height: metrics.size.height)
                    let stableMetrics = MarkdownContentMetrics(size: stableSize, hasHorizontalOverflow: metrics.hasHorizontalOverflow)
                    self.previewModel.markdownContentSize = stableMetrics.size
                    self.previewModel.markdownHasHorizontalOverflow = stableMetrics.hasHorizontalOverflow
                    if !cacheKey.isEmpty {
                        MarkdownPreviewCache.shared.setMetrics(stableMetrics, forKey: cacheKey)
                    }
                    self.requestPopover(.text)
                }
            )
        }
    }

    // MARK: - Preview Task
    // v0.10.3: 使用 Task 替代 Timer，自动取消防止泄漏

    /// v0.12: 完善取消检查，获取数据后也检查取消状态
    /// v0.22: 确保在创建新任务前取消旧任务，防止快速悬停时任务累积导致内存泄漏
    private func startPreviewTask() {
        // 在启动新一轮预览任务时立即刷新 token，避免上一轮 popover 的延迟 dismiss 回调
        // 反过来把新任务/新状态清掉，导致“快速关闭后再打开不弹出”。
        imagePopoverToken = UUID()

        // 先取消旧任务，防止多个任务同时运行
        hoverPreviewTask?.cancel()
        hoverPreviewTask = nil

        hoverPreviewTask = Task(priority: .userInitiated) { @MainActor in
            let delayNanos = UInt64(previewDelay * 1_000_000_000)
            let scale = HoverPreviewScreenMetrics.activeBackingScaleFactor()
            let targetWidthPoints = HoverPreviewScreenMetrics.maxPopoverWidthPoints()
            let targetWidthPixels = max(1, Int(targetWidthPoints * scale))
            let maxLongSidePixels = HoverPreviewImageQualityPolicy.maxSidePixels
            let cacheKeyBase = item.contentHash.isEmpty ? item.id.uuidString : item.contentHash
            let previewCacheKey = "\(cacheKeyBase)|w\(targetWidthPixels)"

            // v0.43.6: 预取 preview 数据（在 hover delay 内完成 IO/downsample），减少 popover 出现后的等待与“重悬停才显示”的体感。
            let prefetchDelayNanos: UInt64 = min(50_000_000, delayNanos)
            let storageRef = item.storageRef
            let preparedPreviewImage: Task<CGImage?, Never> = Task(priority: .userInitiated) { @MainActor () -> CGImage? in
                if prefetchDelayNanos > 0 {
                    try? await Task.sleep(nanoseconds: prefetchDelayNanos)
                }
                guard !Task.isCancelled else { return nil }
                guard !isScrolling else { return nil }
                guard isHovering else { return nil }

                if let cached = HoverPreviewImageCache.shared.image(forKey: previewCacheKey) {
                    previewModel.previewCGImage = cached
                    return cached
                }

                let cgImage: CGImage?
                if let storageRef, !storageRef.isEmpty {
                    let sendable = await Task.detached(priority: .userInitiated) { () -> SendableCGImage? in
                        guard let image = Self.makePreviewCGImage(
                            fromFileAtPath: storageRef,
                            targetWidthPixels: targetWidthPixels,
                            maxLongSidePixels: maxLongSidePixels
                        ) else {
                            return nil
                        }
                        return SendableCGImage(image: image)
                    }.value
                    cgImage = sendable?.image
                } else {
                    guard let data = await getImageData() else { return nil }
                    let sendable = await Task.detached(priority: .userInitiated) { () -> SendableCGImage? in
                        guard let image = Self.makePreviewCGImage(
                            from: data,
                            targetWidthPixels: targetWidthPixels,
                            maxLongSidePixels: maxLongSidePixels
                        ) else {
                            return nil
                        }
                        return SendableCGImage(image: image)
                    }.value
                    cgImage = sendable?.image
                }

                guard !Task.isCancelled else { return nil }
                guard !isScrolling else { return nil }
                guard isHovering else { return nil }
                if let cgImage {
                    HoverPreviewImageCache.shared.setImage(cgImage, forKey: previewCacheKey)
                }
                previewModel.previewCGImage = cgImage
                return cgImage
            }
            defer { preparedPreviewImage.cancel() }

            try? await Task.sleep(nanoseconds: delayNanos)
            guard !Task.isCancelled else { return }
            guard !isScrolling else { return }
            guard isHovering else { return }

            self.requestPopover(.image)

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
        if ScrollPerformanceProfile.isEnabled {
            let start = CFAbsoluteTimeGetCurrent()
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            if image != nil {
                let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
                ScrollPerformanceProfile.recordMetric(name: "hover.preview_image_decode_ms", elapsedMs: elapsed)
            }
            return image
        }
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
        let plan = HoverPreviewImageQualityPolicy.plan(
            sourceWidthPixels: w,
            sourceHeightPixels: h,
            idealTargetWidthPixels: targetWidthPixels,
            maxSidePixels: maxLongSidePixels
        )
        return min(maxLongSidePixels, max(1, plan.maxPixelSize))
    }

    private func cancelPreviewTask() {
        hoverPreviewTask?.cancel()
        hoverPreviewTask = nil
        hoverMarkdownTask?.cancel()
        hoverMarkdownTask = nil
    }

    private func cancelHoverDebounceTask() {
        hoverDebounceTask?.cancel()
        hoverDebounceTask = nil
    }

    private func cancelHoverExitTask() {
        hoverExitTask?.cancel()
        hoverExitTask = nil
    }

    private func cancelHoverTasks() {
        cancelHoverDebounceTask()
        cancelHoverExitTask()
    }

    private func resetPreviewModel() {
        previewModel.reset()
    }

    private func resetPreviewState(hidePopovers: Bool) {
        cancelPreviewTask()
        if hidePopovers {
            requestPopover(nil)
        }
        isPopoverHovering = false
        resetPreviewModel()
    }

    private var shouldResetPreviewOnScroll: Bool {
        if isHovering || isPopoverHovering || isImagePreviewPresented || isTextPreviewPresented {
            return true
        }
        if hoverPreviewTask != nil || hoverMarkdownTask != nil {
            return true
        }
        if hoverDebounceTask != nil || hoverExitTask != nil {
            return true
        }
        if previewModel.previewCGImage != nil || previewModel.text != nil || previewModel.markdownHTML != nil {
            return true
        }
        if previewModel.isExporting || previewModel.exportSuccess || previewModel.exportFailed || previewModel.exportErrorMessage != nil {
            return true
        }
        return false
    }

    private func scheduleHoverExitCleanup() {
        cancelHoverExitTask()
        hoverExitTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            guard !self.isHovering, !self.isPopoverHovering else { return }
            self.resetPreviewState(hidePopovers: true)
        }
    }

    private func dismissPreviewForScrollWheel() {
        guard shouldResetPreviewOnScroll else { return }
        guard !isPopoverHovering else { return }
        isHovering = false
        cancelHoverTasks()
        resetPreviewState(hidePopovers: true)
    }

    // MARK: - Text Preview (v0.15)

    /// v0.15.1: Start text preview task - uses `plainText` (full content) and lazily upgrades to Markdown preview when detected.
    /// v0.22: 确保在创建新任务前取消旧任务，防止快速悬停时任务累积导致内存泄漏
    private func startTextPreviewTask() {
        // 在启动新一轮预览任务时立即刷新 token，避免上一轮 popover 的延迟 dismiss 回调
        // 反过来把新任务/新状态清掉，导致“快速关闭后再打开不弹出”。
        textPopoverToken = UUID()

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
                if !isMarkdown {
                    self.requestPopover(.text)
                }
            }

            guard isMarkdown else { return }
            // Avoid heavy Markdown -> HTML render for very large clipboard payloads.
            guard preview.utf16.count <= 200_000 else { return }

            let cacheKey = item.contentHash
            if !cacheKey.isEmpty,
               let cachedHTML = MarkdownPreviewCache.shared.html(forKey: cacheKey),
               let cachedMetrics = MarkdownPreviewCache.shared.metrics(forKey: cacheKey)
            {
                if self.isHovering, self.previewModel.text == preview {
                    // Fast-path: reuse cached metrics to avoid waiting for WebKit to re-emit identical size messages.
                    let maxWidth: CGFloat = HoverPreviewScreenMetrics.maxPopoverWidthPoints()
                    let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                    let padding: CGFloat = ScopySpacing.md
                    let fallbackWidth = HoverPreviewTextSizing.preferredWidth(
                        for: preview,
                        font: font,
                        padding: padding,
                        maxWidth: maxWidth
                    )
                    let stableWidth: CGFloat = {
                        let w = cachedMetrics.size.width
                        guard w.isFinite, w > 0 else { return fallbackWidth }
                        if w < 40 { return fallbackWidth }
                        if fallbackWidth.isFinite, fallbackWidth > 0, w < fallbackWidth * 0.5 { return fallbackWidth }
                        return min(maxWidth, w)
                    }()
                    let stableSize = CGSize(width: max(1, stableWidth), height: cachedMetrics.size.height)
                    let stableMetrics = MarkdownContentMetrics(size: stableSize, hasHorizontalOverflow: cachedMetrics.hasHorizontalOverflow)
                    self.previewModel.markdownHTML = cachedHTML
                    self.previewModel.markdownContentSize = stableMetrics.size
                    self.previewModel.markdownHasHorizontalOverflow = stableMetrics.hasHorizontalOverflow
                    MarkdownPreviewCache.shared.setMetrics(stableMetrics, forKey: cacheKey)
                    self.requestPopover(.text)
                }
                return
            }
            if let cached = MarkdownPreviewCache.shared.html(forKey: cacheKey) {
                if self.isHovering, self.previewModel.text == preview {
                    self.previewModel.markdownHTML = cached
                }
                return
            }

            let previewText = preview
            hoverMarkdownTask = Task(priority: .utility) { [previewText, cacheKey] in
                guard !Task.isCancelled else { return }
                let html: String
                if ScrollPerformanceProfile.isEnabled {
                    let start = CFAbsoluteTimeGetCurrent()
                    html = MarkdownHTMLRenderer.render(markdown: previewText)
                    let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
                    ScrollPerformanceProfile.recordMetric(name: "hover.markdown_render_ms", elapsedMs: elapsed)
                } else {
                    html = MarkdownHTMLRenderer.render(markdown: previewText)
                }
                guard !Task.isCancelled, !html.isEmpty else { return }
                MarkdownPreviewCache.shared.setHTML(html, forKey: cacheKey)
                await MainActor.run { [previewText] in
                    guard self.isHovering, self.previewModel.text == previewText else { return }
                    self.previewModel.markdownHTML = html
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

    private static func makeRelativeTimeString(for lastUsedAt: Date) -> String {
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

        return Self.relativeFormatter.localizedString(for: lastUsedAt, relativeTo: now)
    }

    private var relativeTime: String {
        Self.makeRelativeTimeString(for: item.lastUsedAt)
    }

    private func updateRelativeTimeText() {
        relativeTimeText = relativeTime
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

private struct ScrollWheelDismissMonitor: NSViewRepresentable {
    let isActive: Bool
    let onScrollWheel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScrollWheel: onScrollWheel)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.update(isActive: isActive)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onScrollWheel = onScrollWheel
        context.coordinator.update(isActive: isActive)
    }

    final class Coordinator {
        var onScrollWheel: () -> Void
        private var monitor: Any?

        init(onScrollWheel: @escaping () -> Void) {
            self.onScrollWheel = onScrollWheel
        }

        func update(isActive: Bool) {
            if isActive {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    self?.onScrollWheel()
                    return event
                }
            } else if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}

/// Observes the popover window closing event.
/// SwiftUI's `.popover(isPresented:)` can get out-of-sync on macOS when the system dismisses the popover without
/// driving the binding back to `false`. This observer provides a best-effort signal to reset local/global state.
private struct PopoverWindowCloseObserver: NSViewRepresentable {
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onClose: onClose)
    }

    func makeNSView(context: Context) -> WindowObservingView {
        let view = WindowObservingView(frame: .zero)
        view.onWindowDidChange = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        view.onWindowWillClear = { [weak coordinator = context.coordinator] in
            coordinator?.emitClose()
        }
        return view
    }

    func updateNSView(_ nsView: WindowObservingView, context: Context) {
        context.coordinator.onClose = onClose
        nsView.onWindowDidChange = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        nsView.onWindowWillClear = { [weak coordinator = context.coordinator] in
            coordinator?.emitClose()
        }
        context.coordinator.attach(to: nsView.window)
    }

    final class Coordinator {
        var onClose: () -> Void
        private weak var observedWindow: NSWindow?
        private var closeObserver: NSObjectProtocol?
        private var hasEmittedClose = false

        init(onClose: @escaping () -> Void) {
            self.onClose = onClose
        }

        func attach(to window: NSWindow?) {
            guard let window else { return }
            if observedWindow === window { return }
            detach()
            observedWindow = window
            hasEmittedClose = false
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.emitClose()
            }
        }

        private func detach() {
            if let closeObserver {
                NotificationCenter.default.removeObserver(closeObserver)
            }
            closeObserver = nil
            observedWindow = nil
        }

        func emitClose() {
            guard !hasEmittedClose else { return }
            hasEmittedClose = true
            onClose()
            detach()
        }

        deinit {
            detach()
        }
    }

    final class WindowObservingView: NSView {
        var onWindowDidChange: ((NSWindow?) -> Void)?
        var onWindowWillClear: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowDidChange?(window)
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil, window != nil {
                onWindowWillClear?()
            }
            super.viewWillMove(toWindow: newWindow)
        }
    }
}
