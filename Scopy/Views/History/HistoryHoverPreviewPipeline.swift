import AppKit
import CoreGraphics
import Foundation
import ScopyKit
import ScopyUISupport

private struct SendableCGImage: @unchecked Sendable {
    let image: CGImage
}

enum HistoryHoverPreviewPipeline {
    static let maxMarkdownPreviewBytes = 200_000
    static let markdownFilePreviewCacheTTL: TimeInterval = 3 * 3600

    // Bound queued decode, read, and render work so cancelled hover sessions cannot accumulate.
    private static let previewTaskPool = AsyncPermitPool(limit: 4, maxPending: 8)

    private struct MarkdownRenderCallbacks: @unchecked Sendable {
        let isCurrent: @MainActor () -> Bool
        let emit: @MainActor (Event) -> Void
    }

    struct ImageRequest {
        /// Content identity captured before asynchronous preparation starts.
        let revision: ClipboardItemContentRevision
        let storageRef: String?
        let delay: TimeInterval
        let scale: CGFloat
        let targetWidthPoints: CGFloat
        let maxLongSidePixels: Int
    }

    struct FileRequest {
        /// Content identity captured before asynchronous preparation starts.
        let revision: ClipboardItemContentRevision
        let previewInfo: FilePreviewInfo
        let isMarkdown: Bool
        let delay: TimeInterval
        let markdownLayoutScale: MarkdownChatGPTLayoutScalePercent
        let scale: CGFloat
        let targetWidthPoints: CGFloat
        let targetHeightPoints: CGFloat
        let maxLongSidePixels: Int
    }

    struct TextRequest {
        let item: ClipboardItemDTO
        let delay: TimeInterval
        let markdownLayoutScale: MarkdownChatGPTLayoutScalePercent
    }

    struct MarkdownFileRequest {
        let cacheKey: String
        let url: URL
        let delay: TimeInterval
        let markdownLayoutScale: MarkdownChatGPTLayoutScalePercent
    }

    enum Request {
        case image(ImageRequest)
        case file(FileRequest)
        case markdownFile(MarkdownFileRequest)
        case text(TextRequest)
    }

    struct ImagePlan: Equatable {
        let delayNanos: UInt64
        let prefetchDelayNanos: UInt64
        let cacheKey: String
        let targetWidthPixels: Int
        let maxLongSidePixels: Int
    }

    struct FilePlan: Equatable {
        let delayNanos: UInt64
        let prefetchDelayNanos: UInt64
        let cacheKey: String
        let targetWidthPixels: Int
        let quickLookMaxSidePixels: Int
        let maxLongSidePixels: Int
    }

    struct TextPreviewState {
        let content: HoverPreviewTextContent?
        var markdownContentSize: CGSize? = nil
        var markdownHasHorizontalOverflow = false

        static let empty = TextPreviewState(content: nil)
    }

    struct MarkdownRenderRequest {
        enum Target {
            case text
            case file(cacheKey: String)
        }

        let source: String
        let layoutScale: MarkdownChatGPTLayoutScalePercent
        let target: Target
    }

    enum Event {
        case present(HoverPreviewPopoverKind)
        case image(CGImage?)
        /// Oriented pixel size from the image header, known before the popover opens so the
        /// popover keeps its size when the decoded image arrives.
        case imagePixelSize(CGSize)
        /// Whether the previewed file exists, resolved before the popover opens.
        case fileAvailability(Bool)
        case text(TextPreviewState)
        case markdownDocument(PreparedMarkdownDocument)
        case renderMarkdown(MarkdownRenderRequest)
        /// The document is ready before the preview delay elapsed; the shared WebView may load it
        /// offscreen so the popover opens with the final layout.
        case prewarmMarkdownDocument(PreparedMarkdownDocument)
    }

    /// Hovering starts preview work only after this long, so passing over rows costs nothing;
    /// the popover itself still waits for the configured preview delay.
    static let prefetchDelayNanos: UInt64 = 300_000_000

    @MainActor
    static func imageRequest(item: ClipboardItemDTO, delay: TimeInterval) -> ImageRequest {
        ImageRequest(
            revision: ClipboardItemContentRevision(item: item),
            storageRef: item.storageRef,
            delay: delay,
            scale: HoverPreviewScreenMetrics.activeBackingScaleFactor(),
            targetWidthPoints: HoverPreviewScreenMetrics.maxPopoverWidthPoints(),
            maxLongSidePixels: HoverPreviewImageQualityPolicy.maxSidePixels
        )
    }

    @MainActor
    static func fileRequest(
        item: ClipboardItemDTO,
        previewInfo: FilePreviewInfo,
        isMarkdown: Bool,
        delay: TimeInterval,
        settings: SettingsDTO = .default
    ) -> FileRequest {
        FileRequest(
            revision: ClipboardItemContentRevision(item: item),
            previewInfo: previewInfo,
            isMarkdown: isMarkdown,
            delay: delay,
            markdownLayoutScale: MarkdownPreviewLayoutScalePreference.active(settings: settings),
            scale: HoverPreviewScreenMetrics.activeBackingScaleFactor(),
            targetWidthPoints: HoverPreviewScreenMetrics.maxPopoverWidthPoints(),
            targetHeightPoints: HoverPreviewScreenMetrics.maxPopoverHeightPoints(),
            maxLongSidePixels: HoverPreviewImageQualityPolicy.maxSidePixels
        )
    }

    static func textRequest(
        item: ClipboardItemDTO,
        delay: TimeInterval,
        settings: SettingsDTO = .default
    ) -> TextRequest {
        TextRequest(
            item: item,
            delay: delay,
            markdownLayoutScale: MarkdownPreviewLayoutScalePreference.active(settings: settings)
        )
    }

    static func markdownFileRequest(fileRequest: FileRequest) -> MarkdownFileRequest {
        MarkdownFileRequest(
            cacheKey: markdownFileCacheKey(revision: fileRequest.revision),
            url: fileRequest.previewInfo.url,
            delay: fileRequest.delay,
            markdownLayoutScale: fileRequest.markdownLayoutScale
        )
    }

    static func imagePlan(for request: ImageRequest) -> ImagePlan {
        let delay = delayNanos(for: request.delay)
        let targetWidthPixels = max(1, Int(request.targetWidthPoints * request.scale))
        return ImagePlan(
            delayNanos: delay,
            prefetchDelayNanos: min(prefetchDelayNanos, delay),
            cacheKey: "\(request.revision.cacheKey)|w\(targetWidthPixels)",
            targetWidthPixels: targetWidthPixels,
            maxLongSidePixels: request.maxLongSidePixels
        )
    }

    static func filePlan(for request: FileRequest) -> FilePlan {
        let delay = delayNanos(for: request.delay)
        let targetWidthPixels = max(1, Int(request.targetWidthPoints * request.scale))
        let targetHeightPixels = max(1, Int(request.targetHeightPoints * request.scale))
        let kindToken = request.previewInfo.kind.rawValue
        return FilePlan(
            delayNanos: delay,
            prefetchDelayNanos: min(prefetchDelayNanos, delay),
            cacheKey: "file|\(request.revision.cacheKey)|\(kindToken)|w\(targetWidthPixels)",
            targetWidthPixels: targetWidthPixels,
            quickLookMaxSidePixels: max(targetWidthPixels, targetHeightPixels),
            maxLongSidePixels: request.maxLongSidePixels
        )
    }

    static func markdownFileCacheKey(revision: ClipboardItemContentRevision) -> String {
        "file|\(revision.cacheKey)"
    }

    @MainActor
    static func run(
        request: Request,
        getImageData: @escaping @MainActor () async -> Data? = { nil },
        readTextFile: @escaping (URL, Int) async -> String? = { url, maxBytes in
            await runBudgetedDetached(priority: .utility) {
                FilePreviewSupport.readTextFile(url: url, maxBytes: maxBytes)
            } ?? nil
        },
        isCurrent: @escaping @MainActor () -> Bool,
        emit: @escaping @MainActor (Event) -> Void
    ) async {
        switch request {
        case .image(let imageRequest):
            await runImagePreview(
                request: imageRequest,
                getImageData: getImageData,
                isCurrent: isCurrent,
                emit: emit
            )
        case .file(let fileRequest):
            if fileRequest.isMarkdown {
                await runMarkdownFilePreview(
                    request: markdownFileRequest(fileRequest: fileRequest),
                    readTextFile: readTextFile,
                    isCurrent: isCurrent,
                    emit: emit
                )
            } else {
                await runFilePreview(request: fileRequest, isCurrent: isCurrent, emit: emit)
            }
        case .markdownFile(let request):
            await runMarkdownFilePreview(
                request: request,
                readTextFile: readTextFile,
                isCurrent: isCurrent,
                emit: emit
            )
        case .text(let textRequest):
            await runTextPreview(request: textRequest, isCurrent: isCurrent, emit: emit)
        }
    }

    static func makeMarkdownRenderTask(
        request: MarkdownRenderRequest,
        isCurrent: @escaping @MainActor () -> Bool,
        emit: @escaping @MainActor (Event) -> Void,
        prepareDocument: @escaping @Sendable (String, MarkdownChatGPTLayoutScalePercent) async -> PreparedMarkdownDocument? = { source, layoutScale in
            await HistoryHoverPreviewPipeline.prepareMarkdownDocument(source, layoutScale: layoutScale)
        }
    ) -> Task<Void, Never> {
        let callbacks = MarkdownRenderCallbacks(isCurrent: isCurrent, emit: emit)
        return Task(priority: .utility) { @MainActor in
            guard !Task.isCancelled else { return }
            guard let document = await prepareDocument(request.source, request.layoutScale),
                  !Task.isCancelled else { return }
            logHoverStage("html rendered \(document.html.utf8.count) bytes")
            if case .file(let cacheKey) = request.target,
               let current = MarkdownPreviewCache.shared.filePreview(forKey: cacheKey),
               current.text == document.source {
                MarkdownPreviewCache.shared.setFilePreview(
                    .init(text: current.text, document: document, fetchedAt: current.fetchedAt),
                    forKey: cacheKey
                )
            }
            guard callbacks.isCurrent() else { return }
            callbacks.emit(.markdownDocument(document))
        }
    }

    @MainActor
    private static func runImagePreview(
        request: ImageRequest,
        getImageData: @escaping @MainActor () async -> Data?,
        isCurrent: @escaping @MainActor () -> Bool,
        emit: @escaping @MainActor (Event) -> Void
    ) async {
        let plan = imagePlan(for: request)
        let storageRef = request.storageRef

        async let preparation: Void = prepareImagePreview(
            plan: plan, storageRef: storageRef, getImageData: getImageData,
            isCurrent: isCurrent, emit: emit
        )
        try? await Task.sleep(nanoseconds: plan.delayNanos)
        guard !Task.isCancelled, isCurrent() else { return }
        emit(.present(.image))
        await preparation
    }

    @MainActor
    private static func prepareImagePreview(
        plan: ImagePlan,
        storageRef: String?,
        getImageData: @escaping @MainActor () async -> Data?,
        isCurrent: @escaping @MainActor () -> Bool,
        emit: @escaping @MainActor (Event) -> Void
    ) async {
        if plan.prefetchDelayNanos > 0 {
            try? await Task.sleep(nanoseconds: plan.prefetchDelayNanos)
        }
        guard !Task.isCancelled, isCurrent() else { return }

        if let cached = HoverPreviewImageCache.shared.image(forKey: plan.cacheKey) {
            emit(.image(cached))
            return
        }

        let cgImage: CGImage?
        if let storageRef, !storageRef.isEmpty {
            let pixelSize = await runBudgetedDetached(priority: .userInitiated) {
                HoverPreviewLoader.displayPixelSize(fromFileAtPath: storageRef)
            } ?? nil
            guard !Task.isCancelled, isCurrent() else { return }
            if let pixelSize { emit(.imagePixelSize(pixelSize)) }
            let sendable = await runBudgetedDetached(priority: .userInitiated) { () async -> SendableCGImage? in
                guard let image = HoverPreviewLoader.makePreviewCGImage(
                    fromFileAtPath: storageRef,
                    targetWidthPixels: plan.targetWidthPixels,
                    maxLongSidePixels: plan.maxLongSidePixels
                ) else {
                    return nil
                }
                return SendableCGImage(image: image)
            } ?? nil
            cgImage = sendable?.image
        } else {
            guard let data = await getImageData(), !Task.isCancelled, isCurrent() else { return }
            let pixelSize = await runBudgetedDetached(priority: .userInitiated) {
                HoverPreviewLoader.displayPixelSize(from: data)
            } ?? nil
            guard !Task.isCancelled, isCurrent() else { return }
            if let pixelSize { emit(.imagePixelSize(pixelSize)) }
            let sendable = await runBudgetedDetached(priority: .userInitiated) { () async -> SendableCGImage? in
                guard let image = HoverPreviewLoader.makePreviewCGImage(
                    from: data,
                    targetWidthPixels: plan.targetWidthPixels,
                    maxLongSidePixels: plan.maxLongSidePixels
                ) else {
                    return nil
                }
                return SendableCGImage(image: image)
            } ?? nil
            cgImage = sendable?.image
        }

        guard !Task.isCancelled, isCurrent() else { return }
        if let cgImage {
            HoverPreviewImageCache.shared.setImage(cgImage, forKey: plan.cacheKey)
        }
        emit(.image(cgImage))
    }

    @MainActor
    private static func runFilePreview(
        request: FileRequest,
        isCurrent: @escaping @MainActor () -> Bool,
        emit: @escaping @MainActor (Event) -> Void
    ) async {
        let plan = filePlan(for: request)
        async let preparation: Void = prepareFilePreview(
            plan: plan, previewInfo: request.previewInfo, scale: request.scale,
            isCurrent: isCurrent, emit: emit
        )
        try? await Task.sleep(nanoseconds: plan.delayNanos)
        guard !Task.isCancelled, isCurrent() else { return }
        emit(.present(.file))
        await preparation
    }

    @MainActor
    private static func prepareFilePreview(
        plan: FilePlan,
        previewInfo: FilePreviewInfo,
        scale: CGFloat,
        isCurrent: @escaping @MainActor () -> Bool,
        emit: @escaping @MainActor (Event) -> Void
    ) async {
        if plan.prefetchDelayNanos > 0 {
            try? await Task.sleep(nanoseconds: plan.prefetchDelayNanos)
        }
        guard !Task.isCancelled, isCurrent() else { return }

        let path = previewInfo.url.path
        let exists = await runBudgetedDetached(priority: .userInitiated) {
            FileManager.default.fileExists(atPath: path)
        }
        guard !Task.isCancelled, isCurrent(), let exists else { return }
        emit(.fileAvailability(exists))
        guard exists else { return }

        if let cached = HoverPreviewImageCache.shared.image(forKey: plan.cacheKey) {
            emit(.image(cached))
            return
        }

        if previewInfo.kind == .image {
            let pixelSize = await runBudgetedDetached(priority: .userInitiated) {
                HoverPreviewLoader.displayPixelSize(fromFileAtPath: path)
            } ?? nil
            guard !Task.isCancelled, isCurrent() else { return }
            if let pixelSize { emit(.imagePixelSize(pixelSize)) }
        }

        // Hover uses a QuickLook still; the live QuickLook view belongs to a pinned window.
        let sendable = await runBudgetedDetached(priority: .userInitiated) { () async -> SendableCGImage? in
            let cgImage: CGImage?
            switch previewInfo.kind {
            case .image:
                cgImage = HoverPreviewLoader.makePreviewCGImage(
                    fromFileAtPath: previewInfo.url.path,
                    targetWidthPixels: plan.targetWidthPixels,
                    maxLongSidePixels: plan.maxLongSidePixels
                )
            case .video:
                cgImage = FilePreviewSupport.makeVideoPreviewCGImage(
                    from: previewInfo.url,
                    maxSidePixels: plan.maxLongSidePixels
                )
            case .other:
                cgImage = await FilePreviewSupport.makeQuickLookPreviewCGImage(
                    from: previewInfo.url,
                    maxSidePixels: plan.quickLookMaxSidePixels,
                    scale: scale
                )
            }
            guard let cgImage else { return nil }
            return SendableCGImage(image: cgImage)
        } ?? nil

        let cgImage = sendable?.image
        guard !Task.isCancelled, isCurrent() else { return }
        if let cgImage {
            HoverPreviewImageCache.shared.setImage(cgImage, forKey: plan.cacheKey)
        }
        emit(.image(cgImage))
    }

    @MainActor
    private static func runMarkdownFilePreview(
        request: MarkdownFileRequest,
        readTextFile: @escaping (URL, Int) async -> String?,
        isCurrent: @escaping @MainActor () -> Bool,
        emit: @escaping @MainActor (Event) -> Void
    ) async {
        try? await Task.sleep(nanoseconds: delayNanos(for: request.delay))
        guard !Task.isCancelled, isCurrent() else { return }

        let now = Date()
        let cachedEntry = MarkdownPreviewCache.shared.filePreview(forKey: request.cacheKey)
        if let cachedEntry,
           now.timeIntervalSince(cachedEntry.fetchedAt) < markdownFilePreviewCacheTTL {
            let document = cachedEntry.text.utf16.count <= maxMarkdownPreviewBytes
                ? await prepareMarkdownDocument(cachedEntry.text, layoutScale: request.markdownLayoutScale)
                : nil
            guard !Task.isCancelled, isCurrent() else { return }
            if let document {
                MarkdownPreviewCache.shared.setFilePreview(
                    .init(text: cachedEntry.text, document: document, fetchedAt: cachedEntry.fetchedAt),
                    forKey: request.cacheKey
                )
            }
            emit(.text(markdownTextState(source: cachedEntry.text, document: document)))
            emit(.present(.file))
            if document == nil, cachedEntry.text.utf16.count <= maxMarkdownPreviewBytes {
                emit(.renderMarkdown(.init(
                    source: cachedEntry.text,
                    layoutScale: request.markdownLayoutScale,
                    target: .file(cacheKey: request.cacheKey)
                )))
            }
            return
        }

        if let cachedEntry {
            emit(.text(markdownTextState(source: cachedEntry.text, document: cachedEntry.document)))
        } else {
            emit(.text(TextPreviewState(content: .markdownSource(nil))))
        }
        emit(.present(.file))

        let previewText = await readTextFile(request.url, maxMarkdownPreviewBytes)
        guard !Task.isCancelled, isCurrent() else { return }
        guard let rawText = previewText else {
            if cachedEntry != nil {
                MarkdownPreviewCache.shared.updateFilePreviewFetchedAt(now, forKey: request.cacheKey)
            } else {
                emit(.text(.empty))
            }
            return
        }

        let preview = rawText.isEmpty ? "(Empty)" : rawText
        let previousDocument = cachedEntry?.text == preview ? cachedEntry?.document : nil
        MarkdownPreviewCache.shared.setFilePreview(
            .init(text: preview, document: previousDocument, fetchedAt: now),
            forKey: request.cacheKey
        )
        emit(.text(markdownTextState(source: preview, document: previousDocument)))
        guard preview.utf16.count <= maxMarkdownPreviewBytes else { return }
        emit(.renderMarkdown(.init(
            source: preview,
            layoutScale: request.markdownLayoutScale,
            target: .file(cacheKey: request.cacheKey)
        )))
    }

    /// Uptime when the current text/Markdown hover started; the WebView logs its stages against it.
    @MainActor static private(set) var textHoverStartedAt: CFTimeInterval = 0

    @MainActor
    static func logHoverStage(_ stage: String) {
        let elapsed = (ProcessInfo.processInfo.systemUptime - textHoverStartedAt) * 1000
        ScopyLog.ui.info("Hover preview \(stage, privacy: .public) at \(elapsed, format: .fixed(precision: 0), privacy: .public) ms")
    }

    @MainActor
    private static func runTextPreview(
        request: TextRequest,
        isCurrent: @escaping @MainActor () -> Bool,
        emit: @escaping @MainActor (Event) -> Void
    ) async {
        let startedAt = ProcessInfo.processInfo.systemUptime
        textHoverStartedAt = startedAt
        logHoverStage("start text \(request.item.plainText.utf8.count) bytes")
        let delay = delayNanos(for: request.delay)
        try? await Task.sleep(nanoseconds: min(prefetchDelayNanos, delay))
        guard !Task.isCancelled, isCurrent() else { return }

        let item = request.item
        let preview = item.plainText.isEmpty ? "(Empty)" : item.plainText
        let isMarkdown = await resolveMarkdownCapability(item: item, preview: preview)
        guard !Task.isCancelled, isCurrent() else { return }
        logHoverStage("detected markdown=\(isMarkdown)")
        HistoryItemPresentationCache.shared.storeMarkdownExportCapability(isMarkdown, for: item)

        // Prepare the entire value during the delay. The eventual owner receives exactly this
        // context and identity even if another preview enriches the same source meanwhile.
        var document: PreparedMarkdownDocument?
        if isMarkdown, preview.utf16.count <= maxMarkdownPreviewBytes {
            document = await prepareMarkdownDocument(preview, layoutScale: request.markdownLayoutScale)
            guard !Task.isCancelled, isCurrent() else { return }
            if let document, MarkdownPreviewCache.shared.metrics(forKey: document.renderKey) == nil {
                emit(.prewarmMarkdownDocument(document))
            }
        }

        let elapsedNanos = UInt64(max(0, ProcessInfo.processInfo.systemUptime - startedAt) * 1_000_000_000)
        if delay > elapsedNanos {
            try? await Task.sleep(nanoseconds: delay - elapsedNanos)
        }
        guard !Task.isCancelled, isCurrent() else { return }
        logHoverStage("delay elapsed")

        let state = isMarkdown
            ? markdownTextState(source: preview, document: document)
            : TextPreviewState(content: .plain(preview))
        emit(.text(state))
        emit(.present(.text))
        logHoverStage("popover requested")

        // The bounded pool may reject prefetch work. The visible preview gets another chance.
        if isMarkdown, document == nil, preview.utf16.count <= maxMarkdownPreviewBytes {
            emit(.renderMarkdown(.init(
                source: preview,
                layoutScale: request.markdownLayoutScale,
                target: .text
            )))
        }
    }

    @MainActor
    private static func resolveMarkdownCapability(item: ClipboardItemDTO, preview: String) async -> Bool {
        let presentationCache = HistoryItemPresentationCache.shared
        if let cached = presentationCache.cachedMarkdownExportCapability(for: item) {
            return cached
        }

        let metricsEnabled = ScrollPerformanceProfile.isEnabled
        let profileStart = metricsEnabled ? CFAbsoluteTimeGetCurrent() : nil
        let computed = await Task.detached(priority: .utility) {
            MarkdownDetector.isLikelyMarkdown(preview)
        }.value
        if let profileStart {
            ScrollPerformanceProfile.recordTiming(
                name: "text.markdown_detect_ms",
                elapsedMs: (CFAbsoluteTimeGetCurrent() - profileStart) * 1000
            )
        }
        return computed
    }

    @MainActor
    private static func markdownTextState(
        source: String,
        document: PreparedMarkdownDocument?
    ) -> TextPreviewState {
        guard let document else { return TextPreviewState(content: .markdownSource(source)) }
        let metrics = MarkdownPreviewCache.shared.metrics(forKey: document.renderKey).map {
            stableMetrics(from: $0, text: document.source)
        }
        return TextPreviewState(
            content: .markdown(document),
            markdownContentSize: metrics?.size,
            markdownHasHorizontalOverflow: metrics?.hasHorizontalOverflow ?? false
        )
    }

    private static func prepareMarkdownDocument(
        _ source: String,
        layoutScale: MarkdownChatGPTLayoutScalePercent
    ) async -> PreparedMarkdownDocument? {
        await runBudgetedDetached(priority: .utility) {
            await PreparedMarkdownDocument.prepare(source: source, layoutScale: layoutScale) { elapsedMs in
                if ScrollPerformanceProfile.isEnabled {
                    ScrollPerformanceProfile.recordTiming(name: "hover.markdown_render_ms", elapsedMs: elapsedMs)
                }
            }
        }
    }

    private static func runBudgetedDetached<T: Sendable>(
        priority: TaskPriority,
        operation: @escaping @Sendable () async -> T
    ) async -> T? {
        await runBudgetedDetached(using: previewTaskPool, priority: priority, operation: operation)
    }

    static func runBudgetedDetached<T: Sendable>(
        using pool: AsyncPermitPool,
        priority: TaskPriority,
        operation: @escaping @Sendable () async -> T
    ) async -> T? {
        guard await pool.acquire() else { return nil }
        guard !Task.isCancelled else {
            await pool.release()
            return nil
        }

        let worker = Task<T?, Never>.detached(priority: priority) {
            guard !Task.isCancelled else { return nil }
            return await operation()
        }
        let result = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        // Cancellation requests the worker to stop; the permit remains held until it actually
        // returns, including synchronous ImageIO work that cannot be interrupted mid-decode.
        await pool.release()
        return Task.isCancelled ? nil : result
    }

    static func stableMetrics(from metrics: MarkdownContentMetrics, text _: String) -> MarkdownContentMetrics {
        let maxWidth: CGFloat = HoverPreviewScreenMetrics.maxMarkdownPopoverWidthPoints()
        let stableSize = CGSize(width: max(1, maxWidth), height: metrics.size.height)
        return MarkdownContentMetrics(
            size: stableSize,
            hasHorizontalOverflow: metrics.hasHorizontalOverflow,
            renderSucceeded: metrics.renderSucceeded,
            renderErrorReason: metrics.renderErrorReason,
            renderID: metrics.renderID
        )
    }

    private static func delayNanos(for delay: TimeInterval) -> UInt64 {
        guard delay.isFinite, delay > 0 else { return 0 }
        return UInt64(delay * 1_000_000_000)
    }

}
