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
        /// The future lazy interaction session can compare this value before committing work.
        let revision: ClipboardItemContentRevision
        let storageRef: String?
        let delay: TimeInterval
        let scale: CGFloat
        let targetWidthPoints: CGFloat
        let maxLongSidePixels: Int
    }

    struct FileRequest {
        /// The future lazy interaction session can compare this value before committing work.
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
        /// Captured with `item` so cache identity and the later session guard share one snapshot.
        let revision: ClipboardItemContentRevision
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
        let shouldPrefetchImage: Bool
    }

    struct TextPreviewState {
        let text: String?
        let isMarkdown: Bool
        let markdownHTML: String?
        let markdownContentSize: CGSize?
        let markdownHasHorizontalOverflow: Bool
        /// Layout scale `markdownHTML` was rendered at.
        var layoutScale: MarkdownChatGPTLayoutScalePercent? = nil

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
        case markdownHTML(String, MarkdownChatGPTLayoutScalePercent)
        case renderMarkdown(MarkdownRenderRequest)
        /// The document is ready before the preview delay elapsed; the shared WebView may load it
        /// offscreen so the popover opens with the final layout.
        case prewarmMarkdownHTML(html: String, renderCacheKey: String)
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
            revision: ClipboardItemContentRevision(item: item),
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
            maxLongSidePixels: request.maxLongSidePixels,
            shouldPrefetchImage: request.previewInfo.kind == .image || request.previewInfo.kind == .video
        )
    }

    static func markdownFileCacheKey(revision: ClipboardItemContentRevision) -> String {
        "file|\(revision.cacheKey)"
    }

    @MainActor
    static func run(
        request: Request,
        getImageData: @escaping () async -> Data? = { nil },
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
        renderMarkdownHTML: @escaping @Sendable (String, MarkdownRenderContext) async -> String = { source, context in
            await HistoryHoverPreviewPipeline.renderMarkdownHTML(source, context: context)
        }
    ) -> Task<Void, Never> {
        let callbacks = MarkdownRenderCallbacks(isCurrent: isCurrent, emit: emit)
        return Task(priority: .utility) { @MainActor in
            guard !Task.isCancelled else { return }
            let html = await renderMarkdownHTML(request.source, request.context)
            guard !Task.isCancelled, !html.isEmpty else { return }
            logHoverStage("html rendered \(html.utf8.count) bytes")
            updateMarkdownCache(html: html, request: request)
            guard callbacks.isCurrent() else { return }
            callbacks.emit(.markdownHTML(html, request.context.layoutScale))
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
                } ?? nil
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
                } ?? nil
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
            } ?? nil

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
            let context = MarkdownRenderContextResolver.defaultContext(
                for: cachedEntry.text,
                layoutScale: request.markdownLayoutScale
            )
            let renderCacheKey = MarkdownRenderCacheKey.make(contentHash: request.cacheKey, context: context)
            let cachedHTML = MarkdownPreviewCache.shared.html(forKey: renderCacheKey)
            emitCachedFilePreview(cachedEntry, renderCacheKey: renderCacheKey, layoutScale: request.markdownLayoutScale, emit: emit)
            if cachedHTML == nil, cachedEntry.text.utf16.count <= maxMarkdownPreviewBytes {
                emit(markdownRenderEvent(
                    source: cachedEntry.text,
                    target: .file(cacheKey: request.cacheKey),
                    layoutScale: request.markdownLayoutScale
                ))
            }
            return
        } else if let cachedEntry {
            let context = MarkdownRenderContextResolver.defaultContext(
                for: cachedEntry.text,
                layoutScale: request.markdownLayoutScale
            )
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
                        markdownHasHorizontalOverflow: cachedMetrics?.hasHorizontalOverflow ?? false,
                        layoutScale: request.markdownLayoutScale
                    )
                )
            )
            emit(.present(.file))
        } else {
            emit(
                .text(
                    TextPreviewState(
                        text: nil,
                        isMarkdown: true,
                        markdownHTML: nil,
                        markdownContentSize: nil,
                        markdownHasHorizontalOverflow: false,
                        layoutScale: request.markdownLayoutScale
                    )
                )
            )
            emit(.present(.file))
        }

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
        emit(
            .text(
                TextPreviewState(
                    text: preview,
                    isMarkdown: true,
                    markdownHTML: nil,
                    markdownContentSize: nil,
                    markdownHasHorizontalOverflow: false,
                    layoutScale: request.markdownLayoutScale
                )
            )
        )

        guard preview.utf16.count <= maxMarkdownPreviewBytes else { return }

        let context = MarkdownRenderContextResolver.defaultContext(
            for: preview,
            layoutScale: request.markdownLayoutScale
        )
        let renderCacheKey = MarkdownRenderCacheKey.make(contentHash: request.cacheKey, context: context)
        let cachedHTML: String? = (cachedEntry?.text == preview) ? MarkdownPreviewCache.shared.html(forKey: renderCacheKey) : nil
        let cachedMetrics: MarkdownContentMetrics? = (cachedEntry?.text == preview) ? MarkdownPreviewCache.shared.metrics(forKey: renderCacheKey) : nil
        MarkdownPreviewCache.shared.setFilePreview(
            MarkdownPreviewCache.FilePreviewEntry(text: preview, html: nil, metrics: nil, fetchedAt: now),
            forKey: request.cacheKey
        )

        if let cachedHTML {
            emit(.markdownHTML(cachedHTML, request.markdownLayoutScale))
            if let cachedMetrics {
                let stableMetrics = stableMetrics(from: cachedMetrics, text: preview)
                emit(
                    .text(
                        TextPreviewState(
                            text: preview,
                            isMarkdown: true,
                            markdownHTML: cachedHTML,
                            markdownContentSize: stableMetrics.size,
                            markdownHasHorizontalOverflow: stableMetrics.hasHorizontalOverflow,
                            layoutScale: request.markdownLayoutScale
                        )
                    )
                )
                MarkdownPreviewCache.shared.setMetrics(stableMetrics, forKey: renderCacheKey)
            }
            return
        }

        emit(markdownRenderEvent(
            source: preview,
            target: .file(cacheKey: request.cacheKey),
            layoutScale: request.markdownLayoutScale
        ))
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
        textHoverStartedAt = ProcessInfo.processInfo.systemUptime
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

        // Build the document during the remaining delay: context and render off the main actor,
        // then let the shared WebView lay it out offscreen so the popover opens at its final size.
        var preparedHTML: String?
        var renderCacheKey = ""
        let layoutScale = request.markdownLayoutScale
        if isMarkdown, preview.utf16.count <= maxMarkdownPreviewBytes {
            let contentHash = request.revision.cacheKey
            let (context, key) = await Task.detached(priority: .userInitiated) {
                let context = MarkdownRenderContextResolver.defaultContext(for: preview, layoutScale: layoutScale)
                return (context, MarkdownRenderCacheKey.make(contentHash: contentHash, context: context))
            }.value
            guard !Task.isCancelled, isCurrent() else { return }
            renderCacheKey = key
            if !key.isEmpty, let cached = MarkdownPreviewCache.shared.html(forKey: key) {
                logHoverStage("html cache hit")
                preparedHTML = cached
            } else {
                let html = await renderMarkdownHTML(preview, context: context)
                guard !Task.isCancelled, isCurrent() else { return }
                if !html.isEmpty {
                    logHoverStage("html rendered \(html.utf8.count) bytes")
                    if !key.isEmpty { MarkdownPreviewCache.shared.setHTML(html, forKey: key) }
                    preparedHTML = html
                }
            }
            if let preparedHTML, !key.isEmpty, MarkdownPreviewCache.shared.metrics(forKey: key) == nil {
                emit(.prewarmMarkdownHTML(html: preparedHTML, renderCacheKey: key))
            }
        }

        let elapsedNanos = UInt64(max(0, ProcessInfo.processInfo.systemUptime - textHoverStartedAt) * 1_000_000_000)
        if delay > elapsedNanos {
            try? await Task.sleep(nanoseconds: delay - elapsedNanos)
        }
        guard !Task.isCancelled, isCurrent() else { return }
        logHoverStage("delay elapsed")

        var contentSize: CGSize?
        var hasHorizontalOverflow = false
        if preparedHTML != nil, !renderCacheKey.isEmpty,
           let cachedMetrics = MarkdownPreviewCache.shared.metrics(forKey: renderCacheKey) {
            let stable = stableMetrics(from: cachedMetrics, text: preview)
            contentSize = stable.size
            hasHorizontalOverflow = stable.hasHorizontalOverflow
            MarkdownPreviewCache.shared.setMetrics(stable, forKey: renderCacheKey)
            logHoverStage("metrics ready height=\(Int(stable.size.height))")
        }
        emit(
            .text(
                TextPreviewState(
                    text: preview,
                    isMarkdown: isMarkdown,
                    markdownHTML: preparedHTML,
                    markdownContentSize: contentSize,
                    markdownHasHorizontalOverflow: hasHorizontalOverflow,
                    layoutScale: request.markdownLayoutScale
                )
            )
        )
        emit(.present(.text))
        logHoverStage("popover requested")

        // The render pool was saturated during the delay: fall back to the on-demand render.
        if isMarkdown, preparedHTML == nil, preview.utf16.count <= maxMarkdownPreviewBytes {
            logHoverStage("render requested after present")
            emit(markdownRenderEvent(
                source: preview,
                target: .text(cacheKey: request.revision.cacheKey),
                layoutScale: request.markdownLayoutScale
            ))
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
    private static func emitCachedFilePreview(
        _ entry: MarkdownPreviewCache.FilePreviewEntry,
        renderCacheKey: String,
        layoutScale: MarkdownChatGPTLayoutScalePercent,
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
                ScrollPerformanceProfile.recordTiming(name: "hover.markdown_render_ms", elapsedMs: elapsed)
                return html
            }
            return MarkdownHTMLRenderer.render(markdown: source, context: context).html
        } ?? ""
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

        let result = await Task.detached(priority: priority, operation: operation).value
        await pool.release()
        return result
    }

    private static func markdownRenderEvent(
        source: String,
        target: MarkdownRenderRequest.Target,
        layoutScale: MarkdownChatGPTLayoutScalePercent
    ) -> Event {
        Event.renderMarkdown(
            MarkdownRenderRequest(
                source: source,
                context: MarkdownRenderContextResolver.defaultContext(
                    for: source,
                    layoutScale: layoutScale
                ),
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
