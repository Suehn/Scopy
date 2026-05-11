import AppKit
import CoreGraphics
import Foundation
import ScopyKit
import ScopyUISupport

private struct SendableCGImage: @unchecked Sendable {
    let image: CGImage
}

private actor PreviewTaskBudget {
    static let shared = PreviewTaskBudget(limit: 4)

    private let limit: Int
    private var inFlight: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquireIfNeeded() async {
        guard PerfFeatureFlags.previewTaskBudgetEnabled else { return }
        if inFlight < limit {
            inFlight += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func releaseIfNeeded() async {
        guard PerfFeatureFlags.previewTaskBudgetEnabled else { return }
        if let continuation = waiters.first {
            waiters.removeFirst()
            continuation.resume()
            return
        }
        inFlight = max(0, inFlight - 1)
    }
}

private func runBudgetedDetached<T: Sendable>(
    priority: TaskPriority,
    operation: @escaping @Sendable () async -> T
) async -> T {
    await PreviewTaskBudget.shared.acquireIfNeeded()
    let result = await Task.detached(priority: priority, operation: operation).value
    await PreviewTaskBudget.shared.releaseIfNeeded()
    return result
}

enum HistoryHoverPreviewPipeline {
    static let maxMarkdownPreviewBytes = 200_000
    static let markdownFilePreviewCacheTTL: TimeInterval = 3 * 3600

    struct ImageRequest {
        let itemID: UUID
        let contentHash: String
        let storageRef: String?
        let delay: TimeInterval
        let scale: CGFloat
        let targetWidthPoints: CGFloat
        let maxLongSidePixels: Int
    }

    struct FileRequest {
        let itemID: UUID
        let contentHash: String
        let previewInfo: FilePreviewInfo
        let isMarkdown: Bool
        let delay: TimeInterval
        let scale: CGFloat
        let targetWidthPoints: CGFloat
        let targetHeightPoints: CGFloat
        let maxLongSidePixels: Int
    }

    struct TextRequest {
        let item: ClipboardItemDTO
        let delay: TimeInterval
    }

    struct MarkdownFileRequest {
        let cacheKey: String
        let url: URL
        let delay: TimeInterval
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
        let shouldPrefetchImage: Bool
    }

    struct TextPreviewState {
        let text: String?
        let isMarkdown: Bool
        let markdownHTML: String?
        let markdownContentSize: CGSize?
        let markdownHasHorizontalOverflow: Bool

        static let empty = TextPreviewState(
            text: nil,
            isMarkdown: false,
            markdownHTML: nil,
            markdownContentSize: nil,
            markdownHasHorizontalOverflow: false
        )
    }

    struct MarkdownRenderRequest {
        enum Target {
            case text(cacheKey: String)
            case file(cacheKey: String)
        }

        let source: String
        let context: MarkdownRenderContext
        let target: Target

        var renderCacheKey: String {
            switch target {
            case .text(let cacheKey), .file(let cacheKey):
                return MarkdownRenderCacheKey.make(contentHash: cacheKey, context: context)
            }
        }
    }

    enum Event {
        case present(HoverPreviewPopoverKind)
        case image(CGImage?)
        case text(TextPreviewState)
        case markdownHTML(String)
        case renderMarkdown(MarkdownRenderRequest)
    }

    @MainActor
    static func imageRequest(item: ClipboardItemDTO, delay: TimeInterval) -> ImageRequest {
        ImageRequest(
            itemID: item.id,
            contentHash: item.contentHash,
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
        delay: TimeInterval
    ) -> FileRequest {
        FileRequest(
            itemID: item.id,
            contentHash: item.contentHash,
            previewInfo: previewInfo,
            isMarkdown: isMarkdown,
            delay: delay,
            scale: HoverPreviewScreenMetrics.activeBackingScaleFactor(),
            targetWidthPoints: HoverPreviewScreenMetrics.maxPopoverWidthPoints(),
            targetHeightPoints: HoverPreviewScreenMetrics.maxPopoverHeightPoints(),
            maxLongSidePixels: HoverPreviewImageQualityPolicy.maxSidePixels
        )
    }

    static func textRequest(item: ClipboardItemDTO, delay: TimeInterval) -> TextRequest {
        TextRequest(item: item, delay: delay)
    }

    static func markdownFileRequest(fileRequest: FileRequest) -> MarkdownFileRequest {
        MarkdownFileRequest(
            cacheKey: markdownFileCacheKey(itemID: fileRequest.itemID, contentHash: fileRequest.contentHash),
            url: fileRequest.previewInfo.url,
            delay: fileRequest.delay
        )
    }

    static func imagePlan(for request: ImageRequest) -> ImagePlan {
        let delay = delayNanos(for: request.delay)
        let targetWidthPixels = max(1, Int(request.targetWidthPoints * request.scale))
        return ImagePlan(
            delayNanos: delay,
            prefetchDelayNanos: min(50_000_000, delay),
            cacheKey: "\(cacheKeyBase(itemID: request.itemID, contentHash: request.contentHash))|w\(targetWidthPixels)",
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
            prefetchDelayNanos: min(50_000_000, delay),
            cacheKey: "file|\(cacheKeyBase(itemID: request.itemID, contentHash: request.contentHash))|\(kindToken)|w\(targetWidthPixels)",
            targetWidthPixels: targetWidthPixels,
            quickLookMaxSidePixels: max(targetWidthPixels, targetHeightPixels),
            maxLongSidePixels: request.maxLongSidePixels,
            shouldPrefetchImage: request.previewInfo.kind == .image || request.previewInfo.kind == .video
        )
    }

    static func markdownFileCacheKey(itemID: UUID, contentHash: String) -> String {
        "file|\(cacheKeyBase(itemID: itemID, contentHash: contentHash))"
    }

    @MainActor
    static func run(
        request: Request,
        getImageData: @escaping () async -> Data? = { nil },
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
                    isCurrent: isCurrent,
                    emit: emit
                )
            } else {
                await runFilePreview(request: fileRequest, isCurrent: isCurrent, emit: emit)
            }
        case .markdownFile(let request):
            await runMarkdownFilePreview(request: request, isCurrent: isCurrent, emit: emit)
        case .text(let textRequest):
            await runTextPreview(request: textRequest, isCurrent: isCurrent, emit: emit)
        }
    }

    static func makeMarkdownRenderTask(
        request: MarkdownRenderRequest,
        isCurrent: @escaping @MainActor () -> Bool,
        emit: @escaping @MainActor (Event) -> Void
    ) -> Task<Void, Never> {
        Task(priority: .utility) {
            guard !Task.isCancelled else { return }
            guard await MainActor.run(body: isCurrent) else { return }
            let html = await renderMarkdownHTML(request.source, context: request.context)
            guard !Task.isCancelled, !html.isEmpty else { return }
            updateMarkdownCache(html: html, request: request)
            await MainActor.run {
                guard isCurrent() else { return }
                emit(.markdownHTML(html))
            }
        }
    }

    @MainActor
    private static func runImagePreview(
        request: ImageRequest,
        getImageData: @escaping () async -> Data?,
        isCurrent: @escaping @MainActor () -> Bool,
        emit: @escaping @MainActor (Event) -> Void
    ) async {
        let plan = imagePlan(for: request)
        let storageRef = request.storageRef

        let preparedPreviewImage: Task<CGImage?, Never> = Task(priority: .userInitiated) { @MainActor () -> CGImage? in
            if plan.prefetchDelayNanos > 0 {
                try? await Task.sleep(nanoseconds: plan.prefetchDelayNanos)
            }
            guard !Task.isCancelled, isCurrent() else { return nil }

            if let cached = HoverPreviewImageCache.shared.image(forKey: plan.cacheKey) {
                emit(.image(cached))
                return cached
            }

            let cgImage: CGImage?
            if let storageRef, !storageRef.isEmpty {
                let sendable = await runBudgetedDetached(priority: .userInitiated) { () async -> SendableCGImage? in
                    guard let image = HoverPreviewLoader.makePreviewCGImage(
                        fromFileAtPath: storageRef,
                        targetWidthPixels: plan.targetWidthPixels,
                        maxLongSidePixels: plan.maxLongSidePixels
                    ) else {
                        return nil
                    }
                    return SendableCGImage(image: image)
                }
                cgImage = sendable?.image
            } else {
                guard let data = await getImageData() else { return nil }
                let sendable = await runBudgetedDetached(priority: .userInitiated) { () async -> SendableCGImage? in
                    guard let image = HoverPreviewLoader.makePreviewCGImage(
                        from: data,
                        targetWidthPixels: plan.targetWidthPixels,
                        maxLongSidePixels: plan.maxLongSidePixels
                    ) else {
                        return nil
                    }
                    return SendableCGImage(image: image)
                }
                cgImage = sendable?.image
            }

            guard !Task.isCancelled, isCurrent() else { return nil }
            if let cgImage {
                HoverPreviewImageCache.shared.setImage(cgImage, forKey: plan.cacheKey)
            }
            emit(.image(cgImage))
            return cgImage
        }
        defer { preparedPreviewImage.cancel() }

        try? await Task.sleep(nanoseconds: plan.delayNanos)
        guard !Task.isCancelled, isCurrent() else { return }
        emit(.present(.image))

        if let cgImage = await preparedPreviewImage.value {
            guard !Task.isCancelled, isCurrent() else { return }
            emit(.image(cgImage))
        }
    }

    @MainActor
    private static func runFilePreview(
        request: FileRequest,
        isCurrent: @escaping @MainActor () -> Bool,
        emit: @escaping @MainActor (Event) -> Void
    ) async {
        let plan = filePlan(for: request)
        let previewInfo = request.previewInfo
        let scale = request.scale

        let preparedPreviewImage: Task<CGImage?, Never> = Task(priority: .userInitiated) { @MainActor () -> CGImage? in
            guard plan.shouldPrefetchImage else { return nil }
            if plan.prefetchDelayNanos > 0 {
                try? await Task.sleep(nanoseconds: plan.prefetchDelayNanos)
            }
            guard !Task.isCancelled, isCurrent() else { return nil }

            if let cached = HoverPreviewImageCache.shared.image(forKey: plan.cacheKey) {
                emit(.image(cached))
                return cached
            }

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
            }

            let cgImage = sendable?.image
            guard !Task.isCancelled, isCurrent() else { return nil }
            if let cgImage {
                HoverPreviewImageCache.shared.setImage(cgImage, forKey: plan.cacheKey)
            }
            emit(.image(cgImage))
            return cgImage
        }
        defer { preparedPreviewImage.cancel() }

        try? await Task.sleep(nanoseconds: plan.delayNanos)
        guard !Task.isCancelled, isCurrent() else { return }
        emit(.present(.file))

        if let cgImage = await preparedPreviewImage.value {
            guard !Task.isCancelled, isCurrent() else { return }
            emit(.image(cgImage))
        }
    }

    @MainActor
    private static func runMarkdownFilePreview(
        request: MarkdownFileRequest,
        isCurrent: @escaping @MainActor () -> Bool,
        emit: @escaping @MainActor (Event) -> Void
    ) async {
        try? await Task.sleep(nanoseconds: delayNanos(for: request.delay))
        guard !Task.isCancelled, isCurrent() else { return }

        let now = Date()
        let cachedEntry = MarkdownPreviewCache.shared.filePreview(forKey: request.cacheKey)
        if let cachedEntry,
           now.timeIntervalSince(cachedEntry.fetchedAt) < markdownFilePreviewCacheTTL {
            let context = MarkdownRenderContextResolver.defaultContext(for: cachedEntry.text)
            let renderCacheKey = MarkdownRenderCacheKey.make(contentHash: request.cacheKey, context: context)
            let cachedHTML = MarkdownPreviewCache.shared.html(forKey: renderCacheKey)
            emitCachedFilePreview(cachedEntry, renderCacheKey: renderCacheKey, emit: emit)
            if cachedHTML == nil, cachedEntry.text.utf16.count <= maxMarkdownPreviewBytes {
                emit(markdownRenderEvent(source: cachedEntry.text, target: .file(cacheKey: request.cacheKey)))
            }
            return
        } else if let cachedEntry {
            let context = MarkdownRenderContextResolver.defaultContext(for: cachedEntry.text)
            let renderCacheKey = MarkdownRenderCacheKey.make(contentHash: request.cacheKey, context: context)
            let cachedHTML = MarkdownPreviewCache.shared.html(forKey: renderCacheKey)
            let cachedMetrics = MarkdownPreviewCache.shared.metrics(forKey: renderCacheKey)
            emit(
                .text(
                    TextPreviewState(
                        text: cachedEntry.text,
                        isMarkdown: true,
                        markdownHTML: cachedHTML,
                        markdownContentSize: cachedMetrics?.size,
                        markdownHasHorizontalOverflow: cachedMetrics?.hasHorizontalOverflow ?? false
                    )
                )
            )
            emit(.present(.file))
        }

        let previewText: String? = await runBudgetedDetached(priority: .utility) {
            FilePreviewSupport.readTextFile(url: request.url, maxBytes: maxMarkdownPreviewBytes)
        }

        guard !Task.isCancelled, isCurrent() else { return }
        guard let rawText = previewText else {
            if cachedEntry != nil {
                MarkdownPreviewCache.shared.updateFilePreviewFetchedAt(now, forKey: request.cacheKey)
            } else {
                emit(.text(.empty))
                emit(.present(.file))
            }
            return
        }

        let preview = rawText.isEmpty ? "(Empty)" : rawText
        emit(
            .text(
                TextPreviewState(
                    text: preview,
                    isMarkdown: true,
                    markdownHTML: nil,
                    markdownContentSize: nil,
                    markdownHasHorizontalOverflow: false
                )
            )
        )
        emit(.present(.file))

        guard preview.utf16.count <= maxMarkdownPreviewBytes else { return }

        let context = MarkdownRenderContextResolver.defaultContext(for: preview)
        let renderCacheKey = MarkdownRenderCacheKey.make(contentHash: request.cacheKey, context: context)
        let cachedHTML: String? = (cachedEntry?.text == preview) ? MarkdownPreviewCache.shared.html(forKey: renderCacheKey) : nil
        let cachedMetrics: MarkdownContentMetrics? = (cachedEntry?.text == preview) ? MarkdownPreviewCache.shared.metrics(forKey: renderCacheKey) : nil
        MarkdownPreviewCache.shared.setFilePreview(
            MarkdownPreviewCache.FilePreviewEntry(text: preview, html: nil, metrics: nil, fetchedAt: now),
            forKey: request.cacheKey
        )

        if let cachedHTML {
            emit(.markdownHTML(cachedHTML))
            if let cachedMetrics {
                let stableMetrics = stableMetrics(from: cachedMetrics, text: preview)
                emit(
                    .text(
                        TextPreviewState(
                            text: preview,
                            isMarkdown: true,
                            markdownHTML: cachedHTML,
                            markdownContentSize: stableMetrics.size,
                            markdownHasHorizontalOverflow: stableMetrics.hasHorizontalOverflow
                        )
                    )
                )
                MarkdownPreviewCache.shared.setMetrics(stableMetrics, forKey: renderCacheKey)
            }
            return
        }

        emit(markdownRenderEvent(source: preview, target: .file(cacheKey: request.cacheKey)))
    }

    @MainActor
    private static func runTextPreview(
        request: TextRequest,
        isCurrent: @escaping @MainActor () -> Bool,
        emit: @escaping @MainActor (Event) -> Void
    ) async {
        try? await Task.sleep(nanoseconds: delayNanos(for: request.delay))
        guard !Task.isCancelled, isCurrent() else { return }

        let item = request.item
        let preview = item.plainText.isEmpty ? "(Empty)" : item.plainText
        let isMarkdown = await resolveMarkdownCapability(item: item, preview: preview)
        guard !Task.isCancelled, isCurrent() else { return }
        HistoryItemPresentationCache.shared.storeMarkdownExportCapability(isMarkdown, for: item)

        emit(
            .text(
                TextPreviewState(
                    text: preview,
                    isMarkdown: isMarkdown,
                    markdownHTML: nil,
                    markdownContentSize: nil,
                    markdownHasHorizontalOverflow: false
                )
            )
        )
        if !isMarkdown {
            emit(.present(.text))
            return
        }

        guard preview.utf16.count <= maxMarkdownPreviewBytes else { return }

        let cacheKey = item.contentHash
        let context = MarkdownRenderContextResolver.defaultContext(for: preview)
        let renderCacheKey = MarkdownRenderCacheKey.make(contentHash: cacheKey, context: context)
        if !renderCacheKey.isEmpty,
           let cachedHTML = MarkdownPreviewCache.shared.html(forKey: renderCacheKey),
           let cachedMetrics = MarkdownPreviewCache.shared.metrics(forKey: renderCacheKey) {
            let stableMetrics = stableMetrics(from: cachedMetrics, text: preview)
            emit(
                .text(
                    TextPreviewState(
                        text: preview,
                        isMarkdown: true,
                        markdownHTML: cachedHTML,
                        markdownContentSize: stableMetrics.size,
                        markdownHasHorizontalOverflow: stableMetrics.hasHorizontalOverflow
                    )
                )
            )
            MarkdownPreviewCache.shared.setMetrics(stableMetrics, forKey: renderCacheKey)
            emit(.present(.text))
            return
        }

        if !renderCacheKey.isEmpty, let cached = MarkdownPreviewCache.shared.html(forKey: renderCacheKey) {
            emit(.markdownHTML(cached))
            return
        }

        emit(markdownRenderEvent(source: preview, target: .text(cacheKey: cacheKey)))
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
            ScrollPerformanceProfile.recordMetric(
                name: "text.markdown_detect_ms",
                elapsedMs: (CFAbsoluteTimeGetCurrent() - profileStart) * 1000
            )
        }
        return computed
    }

    @MainActor
    private static func emitCachedFilePreview(
        _ entry: MarkdownPreviewCache.FilePreviewEntry,
        renderCacheKey: String,
        emit: @escaping @MainActor (Event) -> Void
    ) {
        let cachedHTML = MarkdownPreviewCache.shared.html(forKey: renderCacheKey)
        let cachedStableMetrics: MarkdownContentMetrics?
        if let metrics = MarkdownPreviewCache.shared.metrics(forKey: renderCacheKey) {
            cachedStableMetrics = stableMetrics(from: metrics, text: entry.text)
        } else {
            cachedStableMetrics = nil
        }
        emit(
            .text(
                TextPreviewState(
                    text: entry.text,
                    isMarkdown: true,
                    markdownHTML: cachedHTML,
                    markdownContentSize: cachedStableMetrics?.size,
                    markdownHasHorizontalOverflow: cachedStableMetrics?.hasHorizontalOverflow ?? false
                )
            )
        )
        if let cachedStableMetrics {
            MarkdownPreviewCache.shared.setMetrics(cachedStableMetrics, forKey: renderCacheKey)
        }
        emit(.present(.file))
    }

    private static func renderMarkdownHTML(_ source: String, context: MarkdownRenderContext) async -> String {
        await runBudgetedDetached(priority: .utility) {
            if ScrollPerformanceProfile.isEnabled {
                let start = CFAbsoluteTimeGetCurrent()
                let html = MarkdownHTMLRenderer.render(markdown: source, context: context).html
                let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
                ScrollPerformanceProfile.recordMetric(name: "hover.markdown_render_ms", elapsedMs: elapsed)
                return html
            }
            return MarkdownHTMLRenderer.render(markdown: source, context: context).html
        }
    }

    private static func markdownRenderEvent(source: String, target: MarkdownRenderRequest.Target) -> Event {
        Event.renderMarkdown(
            MarkdownRenderRequest(
                source: source,
                context: MarkdownRenderContextResolver.defaultContext(for: source),
                target: target
            )
        )
    }

    private static func updateMarkdownCache(html: String, request: MarkdownRenderRequest) {
        let renderCacheKey = request.renderCacheKey
        guard !renderCacheKey.isEmpty else { return }
        switch request.target {
        case .text:
            MarkdownPreviewCache.shared.setHTML(html, forKey: renderCacheKey)
        case .file(let cacheKey):
            guard let current = MarkdownPreviewCache.shared.filePreview(forKey: cacheKey),
                  current.text == request.source else { return }
            MarkdownPreviewCache.shared.setHTML(html, forKey: renderCacheKey)
        }
    }

    static func stableMetrics(from metrics: MarkdownContentMetrics, text: String) -> MarkdownContentMetrics {
        let maxWidth: CGFloat = HoverPreviewScreenMetrics.maxPopoverWidthPoints()
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let padding: CGFloat = ScopySpacing.md
        let fallbackWidth = HoverPreviewTextSizing.preferredWidth(
            for: text,
            font: font,
            padding: padding,
            maxWidth: maxWidth
        )
        let stableWidth: CGFloat = {
            let width = metrics.size.width
            guard width.isFinite, width > 0 else { return fallbackWidth }
            if width < 40 { return fallbackWidth }
            if fallbackWidth.isFinite, fallbackWidth > 0, width < fallbackWidth * 0.5 { return fallbackWidth }
            return min(maxWidth, width)
        }()
        let stableSize = CGSize(width: max(1, stableWidth), height: metrics.size.height)
        return MarkdownContentMetrics(size: stableSize, hasHorizontalOverflow: metrics.hasHorizontalOverflow)
    }

    private static func delayNanos(for delay: TimeInterval) -> UInt64 {
        guard delay.isFinite, delay > 0 else { return 0 }
        return UInt64(delay * 1_000_000_000)
    }

    private static func cacheKeyBase(itemID: UUID, contentHash: String) -> String {
        contentHash.isEmpty ? itemID.uuidString : contentHash
    }
}
