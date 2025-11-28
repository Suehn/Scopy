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
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if appState.isLoading && appState.items.isEmpty {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.vertical, ScopySpacing.md)
                        }

                        if !appState.pinnedItems.isEmpty && appState.searchQuery.isEmpty {
                            Section(header: SectionHeader(title: "Pinned", count: appState.pinnedItems.count)) {
                                ForEach(appState.pinnedItems) { item in
                                    historyRow(item: item)
                                }
                            }
                        }

                        Section(header: SectionHeader(title: "Recent", count: appState.unpinnedItems.count, performanceSummary: appState.performanceSummary)) {
                            ForEach(appState.unpinnedItems) { item in
                                historyRow(item: item)
                            }
                        }

                        if appState.canLoadMore {
                            LoadMoreTriggerView(isLoading: appState.isLoading)
                                .onAppear {
                                    Task {
                                        await appState.loadMore()
                                    }
                                }
                        }
                    }
                }
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

    // 静态图标缓存 - 避免重复调用 NSWorkspace API
    // v0.10.4: 添加锁保护，确保线程安全
    private static var iconCache: [String: NSImage] = [:]
    private static let iconCacheLock = NSLock()

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

    /// v0.10.4: 使用锁保护静态缓存访问
    private var appIcon: NSImage? {
        guard let bundleID = item.appBundleID else { return nil }

        // 先尝试从缓存读取
        Self.iconCacheLock.lock()
        if let cached = Self.iconCache[bundleID] {
            Self.iconCacheLock.unlock()
            return cached
        }
        Self.iconCacheLock.unlock()

        // 缓存未命中，获取图标
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)

        // 写入缓存
        Self.iconCacheLock.lock()
        Self.iconCache[bundleID] = icon
        Self.iconCacheLock.unlock()

        return icon
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

    private var metadataText: String? {
        var parts: [String] = []
        if let bundleID = item.appBundleID {
            parts.append(appName(for: bundleID))
        }
        parts.append(formatBytes(item.sizeBytes))
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var contentView: some View {
        switch item.type {
        case .image where showThumbnails:
            HStack(spacing: ScopySpacing.md) {
                thumbnailView
                VStack(alignment: .leading, spacing: ScopySpacing.xs) {
                    Text(item.title)
                        .font(ScopyTypography.body)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let metadataText {
                        Text("Image · \(metadataText)")
                            .font(ScopyTypography.caption)
                            .foregroundStyle(ScopyColors.mutedText)
                            .lineLimit(1)
                    }
                }
            }
        case .file:
            VStack(alignment: .leading, spacing: ScopySpacing.xs) {
                HStack(spacing: ScopySpacing.sm) {
                    Image(systemName: ScopyIcons.file)
                        .foregroundStyle(Color.accentColor)
                    Text(item.title)
                        .font(ScopyTypography.body)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let metadataText {
                    Text(metadataText)
                        .font(ScopyTypography.caption)
                        .foregroundStyle(ScopyColors.mutedText)
                        .lineLimit(1)
                }
            }
        case .image:
            VStack(alignment: .leading, spacing: ScopySpacing.xs) {
                HStack(spacing: ScopySpacing.sm) {
                    Image(systemName: ScopyIcons.image)
                        .foregroundStyle(.green)
                    Text(item.title)
                        .font(ScopyTypography.body)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let metadataText {
                    Text("Image · \(metadataText)")
                        .font(ScopyTypography.caption)
                        .foregroundStyle(ScopyColors.mutedText)
                        .lineLimit(1)
                }
            }
        default:
            VStack(alignment: .leading, spacing: ScopySpacing.xs) {
                Text(item.title)
                    .font(ScopyTypography.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let metadataText {
                    Text(metadataText)
                        .font(ScopyTypography.caption)
                        .foregroundStyle(ScopyColors.mutedText)
                        .lineLimit(1)
                }
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

            // App 图标
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
            } else {
                cancelPreviewTask()
                showPreview = false
            }
        }
        .popover(isPresented: $showPreview, arrowEdge: .trailing) {
            imagePreviewView
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
        .onDisappear {
            hoverDebounceTask?.cancel()
            cancelPreviewTask()
        }
    }

    // MARK: - Thumbnail View

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnailPath = item.thumbnailPath,
           let nsImage = NSImage(contentsOfFile: thumbnailPath) {
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

    private func startPreviewTask() {
        cancelPreviewTask()

        hoverPreviewTask = Task {
            // 先获取图片数据
            if let data = await getImageData() {
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

    // MARK: - Relative Time Formatting

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private var relativeTime: String {
        Self.relativeFormatter.localizedString(for: item.lastUsedAt, relativeTo: Date())
    }

    private func appName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleID
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

    var body: some View {
        HStack {
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
