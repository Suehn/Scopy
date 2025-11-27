import SwiftUI
import AppKit

/// 历史列表视图 - 符合 v0.md 的懒加载设计
struct HistoryListView: View {
    @FocusState.Binding var searchFocused: Bool

    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    // 固定项（置顶）
                    if !appState.pinnedItems.isEmpty && appState.searchQuery.isEmpty {
                        ForEach(appState.pinnedItems) { item in
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
                        }

                        Divider()
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                    }

                    // 普通项
                    ForEach(appState.unpinnedItems) { item in
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
                    }

                    // 加载更多触发器（支持搜索/过滤分页）
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
    @State private var hoverDebounceTimer: Timer?
    @State private var hoverTimer: Timer?
    @State private var showPreview = false
    @State private var previewImageData: Data?

    // 静态图标缓存 - 避免重复调用 NSWorkspace API
    private static var iconCache: [String: NSImage] = [:]

    // 静态 DateFormatter - 避免重复创建
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd"
        return formatter
    }()

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

    /// 视觉高亮：键盘选中 OR 鼠标悬停
    private var shouldHighlight: Bool {
        isKeyboardSelected || isHovering
    }

    private var appIcon: NSImage? {
        guard let bundleID = item.appBundleID else { return nil }

        if let cached = Self.iconCache[bundleID] {
            return cached
        }

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        Self.iconCache[bundleID] = icon
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

    // MARK: - Body

    var body: some View {
        HStack(spacing: 0) {
            // 左侧：app 图标
            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 15, height: 15)
                    .padding(.leading, 4)
                    .padding(.vertical, 5)
            } else {
                Image(systemName: "app")
                    .frame(width: 15, height: 15)
                    .padding(.leading, 4)
                    .padding(.vertical, 5)
                    .foregroundStyle(.secondary)
            }

            Spacer().frame(width: 8)

            // 内容区域
            if item.type == .image && showThumbnails {
                thumbnailView
            } else if item.type == .file {
                Image(systemName: "doc.fill")
                    .frame(width: 12, height: 12)
                    .foregroundStyle(.blue)
                Text(item.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .font(.system(size: 13))
                    .padding(.trailing, 5)
            } else if item.type == .image {
                Image(systemName: "photo")
                    .frame(width: 12, height: 12)
                    .foregroundStyle(.green)
                Text(item.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .font(.system(size: 13))
                    .padding(.trailing, 5)
            } else {
                Text(item.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .font(.system(size: 13))
                    .padding(.trailing, 5)
            }

            Spacer()

            // 右侧：时间 + Pin 标记
            HStack(spacing: 4) {
                Text(relativeTime)
                    .font(.system(size: 10))
                    .foregroundStyle(shouldHighlight ? .white.opacity(0.7) : .secondary)

                if item.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }
            .padding(.trailing, 8)
        }
        .frame(minHeight: item.type == .image && showThumbnails ? thumbnailHeight + 8 : 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(shouldHighlight ? Color.white : .primary)
        .background(shouldHighlight ? Color.accentColor.opacity(0.8) : .white.opacity(0.001))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .id(item.id)
        .onTapGesture {
            onSelect()
        }
        // v0.9.3: 局部悬停状态 + 防抖更新全局选中
        .onHover { hovering in
            isHovering = hovering

            // 取消之前的防抖计时器
            hoverDebounceTimer?.invalidate()

            if hovering {
                // 静止 150ms 后才更新全局选中状态
                hoverDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { _ in
                    DispatchQueue.main.async {
                        onHoverSelect(item.id)
                    }
                }

                // 图片预览计时器
                if item.type == .image && showThumbnails {
                    startPreviewTimer()
                }
            } else {
                cancelPreviewTimer()
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
            hoverDebounceTimer?.invalidate()
            cancelPreviewTimer()
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
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .padding(.leading, 4)
                .padding(.vertical, 4)
        } else {
            Image(systemName: "photo")
                .frame(width: thumbnailHeight, height: thumbnailHeight)
                .padding(.leading, 4)
                .padding(.vertical, 4)
                .foregroundStyle(.green)
        }
    }

    // MARK: - Image Preview View

    @ViewBuilder
    private var imagePreviewView: some View {
        if let imageData = previewImageData,
           let nsImage = NSImage(data: imageData) {
            let maxWidth: CGFloat = 500
            let originalWidth = nsImage.size.width
            let originalHeight = nsImage.size.height

            if originalWidth <= maxWidth {
                Image(nsImage: nsImage)
                    .padding(8)
            } else {
                let aspectRatio = originalWidth / originalHeight
                let displayWidth = maxWidth
                let displayHeight = displayWidth / aspectRatio

                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: displayWidth, height: displayHeight)
                    .padding(8)
            }
        } else {
            ProgressView()
                .padding()
        }
    }

    // MARK: - Preview Timer

    private func startPreviewTimer() {
        cancelPreviewTimer()

        Task {
            if let data = await getImageData() {
                await MainActor.run {
                    previewImageData = data
                }
            } else {
                await MainActor.run {
                    previewImageData = loadOriginalImageData()
                }
            }
        }

        hoverTimer = Timer.scheduledTimer(withTimeInterval: previewDelay, repeats: false) { _ in
            DispatchQueue.main.async {
                if isHovering {
                    showPreview = true
                }
            }
        }
    }

    private func cancelPreviewTimer() {
        hoverTimer?.invalidate()
        hoverTimer = nil
    }

    // MARK: - Load Image Data

    private func loadOriginalImageData() -> Data? {
        if let storageRef = item.storageRef {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: storageRef)) {
                return data
            }
        }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let scopyDir = appSupport.appendingPathComponent("Scopy", isDirectory: true)
        let contentDir = scopyDir.appendingPathComponent("content", isDirectory: true)

        for ext in ["png", "dat"] {
            let idPath = contentDir.appendingPathComponent("\(item.id.uuidString).\(ext)")
            if let data = try? Data(contentsOf: idPath) {
                return data
            }
        }

        return nil
    }

    // MARK: - Relative Time Formatting

    private var relativeTime: String {
        let now = Date()
        let interval = now.timeIntervalSince(item.lastUsedAt)

        if interval < 60 {
            return "刚刚"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)分钟前"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)小时前"
        } else if interval < 604800 {
            let days = Int(interval / 86400)
            return "\(days)天前"
        } else {
            return Self.dateFormatter.string(from: item.lastUsedAt)
        }
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
        .frame(height: 30)
        .padding(.vertical, 5)
    }
}
