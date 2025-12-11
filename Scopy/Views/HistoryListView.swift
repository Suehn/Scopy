import SwiftUI
import AppKit

/// 历史列表视图 - 符合 v0.md 的懒加载设计
struct HistoryListView: View {
    @FocusState.Binding var searchFocused: Bool

    @Environment(AppState.self) private var appState

    var body: some View {
        if appState.items.isEmpty && !appState.isLoading {
            EmptyStateView(
                hasFilters: appState.hasActiveFilters,
                openSettings: appState.openSettingsHandler
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // v0.18: 使用 List 替代 ScrollView+LazyVStack 实现真正的视图回收
            // List 基于 NSTableView，具有视图回收能力，10k 项目内存从 ~500MB 降至 ~50MB
            ScrollViewReader { proxy in
                List {
                    // Loading indicator
                    if appState.isLoading && appState.items.isEmpty {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.vertical, ScopySpacing.md)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }

                    // v0.21: 使用局部变量缓存计算属性结果，避免多次访问触发 @Observable 追踪
                    // 这样 SwiftUI 只追踪一次 pinnedItems/unpinnedItems 访问
                    let pinned = appState.pinnedItems
                    let unpinned = appState.unpinnedItems

                    // v0.18: 不使用 Section header，改为普通行以避免黑色背景
                    // Pinned Section Header
                    if !pinned.isEmpty && appState.searchQuery.isEmpty {
                        SectionHeader(
                            title: "Pinned",
                            count: pinned.count,
                            isCollapsible: true,
                            isCollapsed: appState.isPinnedCollapsed,
                            onToggle: { appState.isPinnedCollapsed.toggle() }
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)

                        // Pinned Items
                        if !appState.isPinnedCollapsed {
                            ForEach(pinned) { item in
                                historyRow(item: item)
                            }
                        }
                    }

                    // Recent Section Header
                    SectionHeader(
                        title: "Recent",
                        count: unpinned.count,
                        performanceSummary: appState.performanceSummary
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                    // Recent Items
                    ForEach(unpinned) { item in
                        historyRow(item: item)
                    }

                    // Load More Trigger
                    if appState.canLoadMore {
                        LoadMoreTriggerView(isLoading: appState.isLoading)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .onAppear {
                                Task { await appState.loadMore() }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.automatic)
                .onChange(of: appState.selectedID) { _, newValue in
                    // 仅当键盘导航时自动滚动到选中项
                    if let id = newValue, appState.lastSelectionSource == .keyboard {
                        withAnimation(.easeInOut(duration: 0.1)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
                // 单条删除快捷键: Option+Delete
                .onKeyPress { keyPress in
                    if keyPress.key == .delete && keyPress.modifiers.contains(.option) {
                        Task { await appState.deleteSelectedItem() }
                        return .handled
                    }
                    return .ignored
                }
            }
        }
    }

    /// v0.18: 添加 List 修饰符以保持原有样式
    @ViewBuilder
    private func historyRow(item: ClipboardItemDTO) -> some View {
        HistoryItemView(
            item: item,
            isKeyboardSelected: appState.selectedID == item.id,
            settings: appState.settings,
            onSelect: { Task { await appState.select(item) } },
            onHoverSelect: { id in
                appState.selectedID = id
                appState.lastSelectionSource = .mouse
            },
            onTogglePin: { Task { await appState.togglePin(item) } },
            onDelete: { Task { await appState.delete(item) } },
            getImageData: { try? await appState.service.getImageData(itemID: item.id) }
        )
        .equatable()
        .id(item.id)
        .listRowInsets(EdgeInsets())      // 移除默认内边距
        .listRowBackground(Color.clear)    // 透明背景
        .listRowSeparator(.hidden)         // 隐藏分隔线
    }
}

// MARK: - History Item View (v0.9.3 - 性能优化版)

/// 单个历史项视图 - 实现 Equatable 以优化重绘
/// v0.9.3: 使用局部悬停状态 + 防抖 + Equatable 优化滚动性能
struct HistoryItemView: View, Equatable {
    let item: ClipboardItemDTO
    let isKeyboardSelected: Bool
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
    @State private var showPreview = false
    @State private var previewImageData: Data?
    // v0.15: Text preview state
    @State private var showTextPreview = false
    @State private var textPreviewContent: String?

    // 静态图标缓存 - 避免重复调用 NSWorkspace API
    // v0.10.4: 添加锁保护，确保线程安全
    // v0.10.8: 添加 LRU 清理，防止内存无限增长
    private static var iconCache: [String: NSImage] = [:]
    private static var iconAccessOrder: [String] = []
    private static let iconCacheLock = NSLock()
    private static let maxIconCacheSize = 50

    // v0.18: 缩略图缓存 - 避免 List 视图回收时重复磁盘 I/O
    // key: thumbnailPath, value: NSImage
    // 实测: 234 张缩略图约 5MB，1000 张约 20MB，可以大幅放宽限制
    private static var thumbnailCache: [String: NSImage] = [:]
    private static var thumbnailAccessOrder: [String] = []
    private static let thumbnailCacheLock = NSLock()
    private static let maxThumbnailCacheSize = 1000  // 约 20MB 内存，换取流畅滚动

    // MARK: - Equatable

    static func == (lhs: HistoryItemView, rhs: HistoryItemView) -> Bool {
        lhs.item.id == rhs.item.id &&
        lhs.item.lastUsedAt == rhs.item.lastUsedAt &&
        lhs.item.isPinned == rhs.item.isPinned &&
        lhs.isKeyboardSelected == rhs.isKeyboardSelected &&
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

    /// v0.12: 优先使用全局预加载缓存，避免主线程阻塞
    /// v0.17.1: 使用 withLock 统一锁策略
    private var appIcon: NSImage? {
        guard let bundleID = item.appBundleID else { return nil }

        // 优先从全局预加载缓存获取（同步，无阻塞）
        if let cached = IconCacheSync.shared.getIcon(bundleID: bundleID) {
            return cached
        }

        // 回退到本地静态缓存
        return Self.iconCacheLock.withLock {
            // 检查本地缓存
            if let cached = Self.iconCache[bundleID] {
                // 更新 LRU 访问顺序
                if let index = Self.iconAccessOrder.firstIndex(of: bundleID) {
                    Self.iconAccessOrder.remove(at: index)
                }
                Self.iconAccessOrder.append(bundleID)
                return cached
            }

            // 缓存未命中，获取图标（仅在预加载未覆盖时执行）
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                return nil
            }
            let icon = NSWorkspace.shared.icon(forFile: url.path)

            // LRU 清理：如果缓存满了，移除最旧的
            if Self.iconCache.count >= Self.maxIconCacheSize,
               let oldest = Self.iconAccessOrder.first {
                Self.iconCache.removeValue(forKey: oldest)
                Self.iconAccessOrder.removeFirst()
            }

            // 写入本地缓存
            Self.iconCache[bundleID] = icon
            Self.iconAccessOrder.append(bundleID)

            // 同时写入全局缓存，供后续使用
            IconCacheSync.shared.setIcon(icon, for: bundleID)

            return icon
        }
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
                thumbnailView
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
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .animation(.easeInOut(duration: 0.15), value: isKeyboardSelected)
        .padding(.horizontal, ScopySpacing.md) // Outer padding for floating effect
        .onTapGesture {
            onSelect()
        }
        // v0.9.3: 局部悬停状态 + 防抖更新全局选中
        // v0.10.3: 使用 Task 替代 Timer，自动取消防止泄漏
        // v0.15: 添加文本预览支持
        .onHover { hovering in
            isHovering = hovering

            // 取消之前的防抖任务
            hoverDebounceTask?.cancel()

            if hovering {
                // 静止 150ms 后才更新全局选中状态
                hoverDebounceTask = Task {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        onHoverSelect(item.id)
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
                cancelPreviewTask()
                showPreview = false
                showTextPreview = false
                previewImageData = nil    // v0.15.1: Clear image data to prevent memory leak
                textPreviewContent = nil  // v0.15: Reset text preview content
            }
        }
        .popover(isPresented: $showPreview, arrowEdge: .trailing) {
            imagePreviewView
        }
        .popover(isPresented: $showTextPreview, arrowEdge: .trailing) {
            textPreviewView
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
            cancelPreviewTask()
            // 清理状态，防止内存泄漏
            previewImageData = nil
            textPreviewContent = nil
        }
    }

    // MARK: - Thumbnail View

    /// v0.18: 从缓存获取缩略图，避免重复磁盘 I/O
    private func getCachedThumbnail(path: String) -> NSImage? {
        Self.thumbnailCacheLock.withLock {
            // 检查缓存
            if let cached = Self.thumbnailCache[path] {
                // 更新 LRU 访问顺序
                if let index = Self.thumbnailAccessOrder.firstIndex(of: path) {
                    Self.thumbnailAccessOrder.remove(at: index)
                }
                Self.thumbnailAccessOrder.append(path)
                return cached
            }

            // 缓存未命中，从磁盘加载
            guard let image = NSImage(contentsOfFile: path) else {
                return nil
            }

            // LRU 清理
            if Self.thumbnailCache.count >= Self.maxThumbnailCacheSize,
               let oldest = Self.thumbnailAccessOrder.first {
                Self.thumbnailCache.removeValue(forKey: oldest)
                Self.thumbnailAccessOrder.removeFirst()
            }

            // 写入缓存
            Self.thumbnailCache[path] = image
            Self.thumbnailAccessOrder.append(path)

            return image
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnailPath = item.thumbnailPath,
           let nsImage = getCachedThumbnail(path: thumbnailPath) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: thumbnailHeight)
                .clipShape(RoundedRectangle(cornerRadius: ScopySize.Corner.sm))
                .padding(.leading, ScopySpacing.xs)
                .padding(.vertical, ScopySpacing.xs)
        } else {
            Image(systemName: "photo")
                .frame(width: thumbnailHeight, height: thumbnailHeight)
                .padding(.leading, ScopySpacing.xs)
                .padding(.vertical, ScopySpacing.xs)
                .foregroundStyle(.green)
        }
    }

    // MARK: - Image Preview View

    @ViewBuilder
    private var imagePreviewView: some View {
        if let imageData = previewImageData,
           let nsImage = NSImage(data: imageData) {
            let maxWidth: CGFloat = ScopySize.Width.previewMax
            let originalWidth = nsImage.size.width
            let originalHeight = nsImage.size.height

            if originalWidth <= maxWidth {
                Image(nsImage: nsImage)
                    .padding(ScopySpacing.md)
            } else {
                let aspectRatio = originalWidth / originalHeight
                let displayWidth = maxWidth
                let displayHeight = displayWidth / aspectRatio

                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: displayWidth, height: displayHeight)
                    .padding(ScopySpacing.md)
            }
        } else {
            ProgressView()
                .padding()
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

        hoverPreviewTask = Task {
            // 先获取图片数据
            if let data = await getImageData() {
                // v0.12: 获取数据后检查取消状态
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    previewImageData = data
                }
            }

            // 等待预览延迟时间
            let delayNanos = UInt64(previewDelay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delayNanos)
            guard !Task.isCancelled else { return }

            // 显示预览
            await MainActor.run {
                if self.isHovering && self.previewImageData != nil {
                    self.showPreview = true
                }
            }
        }
    }

    private func cancelPreviewTask() {
        hoverPreviewTask?.cancel()
        hoverPreviewTask = nil
    }

    // MARK: - Text Preview (v0.15)

    /// v0.15.1: Start text preview task - shows first 100 + ... + last 100 chars
    /// v0.22: 确保在创建新任务前取消旧任务，防止快速悬停时任务累积导致内存泄漏
    private func startTextPreviewTask() {
        // 先取消旧任务，防止多个任务同时运行
        hoverPreviewTask?.cancel()
        hoverPreviewTask = nil

        // Generate preview content synchronously FIRST
        let text = item.plainText
        let preview: String
        if text.isEmpty {
            preview = "(Empty)"
        } else if text.count <= 200 {
            preview = text
        } else {
            let first100 = String(text.prefix(100))
            let last100 = String(text.suffix(100))
            preview = "\(first100)\n...\n\(last100)"
        }

        // Set content immediately (synchronous, on main thread)
        self.textPreviewContent = preview

        hoverPreviewTask = Task {
            // Wait for preview delay
            let delayNanos = UInt64(previewDelay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delayNanos)
            guard !Task.isCancelled else { return }

            // Show popover (content already set)
            await MainActor.run {
                if self.isHovering {
                    self.showTextPreview = true
                }
            }
        }
    }

    @ViewBuilder
    private var textPreviewView: some View {
        // v0.16.2: Text preview - 修复最后一行截断问题
        ScrollView {
            Text(textPreviewContent ?? "(Empty)")
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(ScopySpacing.md)
                .padding(.bottom, ScopySpacing.md)  // 额外底部 padding 防止截断
        }
        .frame(width: 400)
        .frame(maxHeight: 400)
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
        return IconCacheSync.shared.getAppName(bundleID: bundleID)
    }

    private func formatBytes(_ bytes: Int) -> String {
        Localization.formatBytes(bytes)
    }
}

// MARK: - Load More Trigger View

struct LoadMoreTriggerView: View {
    var isLoading: Bool

    var body: some View {
        HStack {
            Spacer()
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                Text("Loading...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Scroll for more")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(height: ScopySize.Height.loadMore)
        .padding(.vertical, ScopySpacing.xs)
    }
}

// MARK: - Section Header

private struct SectionHeader: View {
    let title: String
    let count: Int
    var performanceSummary: PerformanceSummary? = nil
    /// v0.16.2: 可折叠支持
    var isCollapsible: Bool = false
    var isCollapsed: Bool = false
    var onToggle: (() -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        HStack {
            // v0.16.2: 折叠指示器
            if isCollapsible {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ScopyColors.tertiaryText)
                    .frame(width: 12)
            }

            Text("\(title) · \(count)")
                .font(ScopyTypography.caption)
                .fontWeight(.medium)
                .foregroundStyle(ScopyColors.tertiaryText)
                .monospacedDigit()

            if let summary = performanceSummary, title == "Recent" {
                Spacer()
                HStack(spacing: ScopySpacing.md) {
                    if summary.searchSamples > 0 {
                        Text("Search: \(summary.formattedSearchAvg)")
                    }
                    if summary.loadSamples > 0 {
                        Text("Load: \(summary.formattedLoadAvg)")
                    }
                }
                .font(.system(size: ScopyTypography.Size.micro, weight: .regular, design: .monospaced))
                .foregroundStyle(ScopyColors.tertiaryText.opacity(ScopySize.Opacity.strong))
            }

            Spacer()
        }
        .padding(.horizontal, ScopySpacing.md)
        .padding(.top, ScopySpacing.md)
        .padding(.bottom, ScopySpacing.xs)
        // v0.16.2: 可点击折叠
        .background(isCollapsible && isHovered ? ScopyColors.hover.opacity(0.5) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            if isCollapsible {
                onToggle?()
            }
        }
        .onHover { hovering in
            if isCollapsible {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Empty State

private struct EmptyStateView: View {
    let hasFilters: Bool
    let openSettings: (() -> Void)?

    var body: some View {
        VStack(spacing: ScopySpacing.md) {
            Image(systemName: hasFilters ? ScopyIcons.search : ScopyIcons.tray)
                .font(.system(size: ScopySize.Icon.empty))
                .foregroundStyle(ScopyColors.mutedText)
            VStack(spacing: ScopySpacing.xs) {
                Text(hasFilters ? "No results" : "No items yet")
                    .font(ScopyTypography.title)
                Text(hasFilters ? "Try clearing filters or adjust search" : "New copies will appear here")
                    .font(ScopyTypography.caption)
                    .foregroundStyle(ScopyColors.mutedText)
            }
            if !hasFilters, let openSettings {
                Button {
                    openSettings()
                } label: {
                    Label("Open Settings", systemImage: ScopyIcons.settings)
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(ScopySpacing.xl)
    }
}
