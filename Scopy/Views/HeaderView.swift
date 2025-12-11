import AppKit
import SwiftUI

/// 头部视图 - 包含标题、过滤按钮和搜索框
struct HeaderView: View {
    @Binding var searchQuery: String
    @FocusState.Binding var searchFocused: Bool

    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: ScopySpacing.md) {
            // Search Icon
            Image(systemName: ScopyIcons.search)
                .font(.system(size: ScopySize.Icon.header, weight: .medium))
                .foregroundStyle(ScopyColors.mutedText)

            // Search Field
            TextField("Search...", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(ScopyTypography.searchField)
                .focused($searchFocused)
                .onChange(of: searchQuery) {
                    appState.search()
                }
                .onSubmit {
                    Task { await appState.selectCurrent() }
                }

            Spacer()

            // Filters & Actions
            HStack(spacing: ScopySpacing.sm) {
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                        appState.search()
                    } label: {
                        Image(systemName: ScopyIcons.clear)
                            .foregroundStyle(ScopyColors.mutedText)
                    }
                    .buttonStyle(.plain)
                }
                
                Divider()
                    .frame(height: ScopySize.Height.divider)
                
                AppFilterButton()
                TypeFilterButton()
                SearchModeMenu()
            }
        }
        .padding(ScopySpacing.md)
        .background(ScopyColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: ScopySize.Corner.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ScopySize.Corner.xl, style: .continuous)
                .stroke(ScopyColors.border.opacity(ScopySize.Opacity.medium), lineWidth: ScopySize.Stroke.thin)
        )
    }
}

// MARK: - Search Mode Menu

private struct SearchModeMenu: View {
    @Environment(AppState.self) private var appState
    /// v0.22: 保存设置任务引用，支持取消，防止内存泄漏
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        Menu {
            ForEach(SearchMode.allCases, id: \.self) { mode in
                Button {
                    appState.searchMode = mode
                    appState.search()
                    // v0.22: 取消之前的保存任务，防止快速切换时任务累积
                    saveTask?.cancel()
                    // 持久化到设置
                    saveTask = Task {
                        guard !Task.isCancelled else { return }
                        var newSettings = appState.settings
                        newSettings.defaultSearchMode = mode
                        await appState.updateSettings(newSettings)
                    }
                } label: {
                    HStack {
                        if mode == appState.searchMode {
                            Image(systemName: "checkmark")
                        }
                        Text(modeLabel(mode))
                    }
                }
            }
        } label: {
            Image(systemName: modeIcon(appState.searchMode))
                .font(.system(size: ScopySize.Icon.filter))
                .foregroundStyle(ScopyColors.mutedText)
        }
        .menuStyle(.borderlessButton)
        .help("Search mode")
        .onDisappear {
            // v0.22: 视图消失时取消未完成的任务
            saveTask?.cancel()
            saveTask = nil
        }
    }

    private func modeLabel(_ mode: SearchMode) -> String {
        switch mode {
        case .exact: return "Exact"
        case .fuzzy: return "Fuzzy"
        case .fuzzyPlus: return "Fuzzy+"
        case .regex: return "Regex"
        }
    }

    private func modeIcon(_ mode: SearchMode) -> String {
        switch mode {
        case .exact: return "text.quote"
        case .fuzzy: return "text.magnifyingglass"
        case .fuzzyPlus: return "plus.magnifyingglass"
        case .regex: return "asterisk.circle"
        }
    }
}

// MARK: - App Filter Button

struct AppFilterButton: View {
    @Environment(AppState.self) private var appState

    // LRU 缓存：限制最大 50 个条目，防止内存泄漏
    // v0.10.8: 添加 NSLock 保护，确保线程安全
    private static var nameCache: [String: String] = [:]
    private static var iconCache: [String: NSImage] = [:]
    private static var iconAccessOrder: [String] = []  // LRU 访问顺序
    private static let maxCacheSize = 50
    private static let cacheLock = NSLock()

    var body: some View {
        Menu {
            Button(action: {
                appState.appFilter = nil
                appState.search()
            }) {
                HStack {
                    if appState.appFilter == nil {
                        Image(systemName: "checkmark")
                    }
                    Text("All Apps")
                }
            }

            if !appState.recentApps.isEmpty {
                Divider()

                ForEach(appState.recentApps, id: \.self) { bundleID in
                    Button(action: {
                        appState.appFilter = bundleID
                        appState.search()
                    }) {
                        HStack {
                            if appState.appFilter == bundleID {
                                Image(systemName: "checkmark")
                            }
                            if let icon = appIcon(for: bundleID) {
                                Image(nsImage: icon)
                            }
                            Text(appName(for: bundleID))
                        }
                    }
                }
            }
        } label: {
            if let bundleID = appState.appFilter, let icon = appIcon(for: bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: ScopySize.Icon.menuApp, height: ScopySize.Icon.menuApp)
            } else {
                Image(systemName: ScopyIcons.filterApp)
                    .font(.system(size: ScopySize.Icon.filter))
                    .foregroundStyle(ScopyColors.mutedText)
            }
        }
        .menuStyle(.borderlessButton)
        .help("Filter by app")
    }

    /// v0.10.8: 使用锁保护缓存访问，确保线程安全
    private func appIcon(for bundleID: String) -> NSImage? {
        Self.cacheLock.lock()

        // 检查缓存命中
        if let cached = Self.iconCache[bundleID] {
            // 更新 LRU 访问顺序
            if let index = Self.iconAccessOrder.firstIndex(of: bundleID) {
                Self.iconAccessOrder.remove(at: index)
            }
            Self.iconAccessOrder.append(bundleID)
            Self.cacheLock.unlock()
            return cached
        }

        // 缓存未命中，释放锁后获取图标（避免阻塞）
        Self.cacheLock.unlock()

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let sourceIcon = NSWorkspace.shared.icon(forFile: url.path)

        // Create properly sized icon - match menu app icon size
        let iconSize = ScopySize.Icon.menuApp
        let targetSize = NSSize(width: iconSize, height: iconSize)
        let croppedIcon = NSImage(size: targetSize)

        croppedIcon.lockFocus()

        // Find the best representation and draw centered
        if let bestRep = sourceIcon.bestRepresentation(
            for: NSRect(origin: .zero, size: targetSize),
            context: nil,
            hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)]
        ) {
            bestRep.draw(in: NSRect(origin: .zero, size: targetSize))
        }

        croppedIcon.unlockFocus()
        croppedIcon.isTemplate = false

        // 重新获取锁来更新缓存
        Self.cacheLock.lock()

        // LRU 清理：超出限制时移除最早访问的条目
        if Self.iconCache.count >= Self.maxCacheSize, let oldest = Self.iconAccessOrder.first {
            Self.iconCache.removeValue(forKey: oldest)
            Self.iconAccessOrder.removeFirst()
        }

        Self.iconCache[bundleID] = croppedIcon
        Self.iconAccessOrder.append(bundleID)
        Self.cacheLock.unlock()

        return croppedIcon
    }

    /// v0.10.8: 使用锁保护缓存访问，确保线程安全
    /// v0.22: 修复 LRU 清理策略，使用 FIFO 而非全部清空
    private static var nameAccessOrder: [String] = []  // 名称缓存的访问顺序

    private func appName(for bundleID: String) -> String {
        Self.cacheLock.lock()

        if let cached = Self.nameCache[bundleID] {
            Self.cacheLock.unlock()
            return cached
        }

        // 缓存未命中，需要获取名称（在锁外执行）
        Self.cacheLock.unlock()

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        let name = url.deletingPathExtension().lastPathComponent

        // 重新获取锁来更新缓存
        Self.cacheLock.lock()

        // v0.22: LRU 清理：移除最旧的条目而非全部清空
        if Self.nameCache.count >= Self.maxCacheSize, let oldest = Self.nameAccessOrder.first {
            Self.nameCache.removeValue(forKey: oldest)
            Self.nameAccessOrder.removeFirst()
        }

        Self.nameCache[bundleID] = name
        Self.nameAccessOrder.append(bundleID)
        Self.cacheLock.unlock()

        return name
    }
}

// MARK: - Type Filter Button

/// v0.22: 添加 Rich Text 选项，支持 rtf + html 类型过滤
struct TypeFilterButton: View {
    @Environment(AppState.self) private var appState

    /// Rich Text 类型集合 (rtf + html)
    private static let richTextTypes: Set<ClipboardItemType> = [.rtf, .html]

    /// 当前是否选中 Rich Text 过滤
    private var isRichTextSelected: Bool {
        appState.typeFilters == Self.richTextTypes
    }

    var body: some View {
        Menu {
            Button(action: {
                appState.typeFilter = nil
                appState.typeFilters = nil
                appState.search()
            }) {
                HStack {
                    if appState.typeFilter == nil && appState.typeFilters == nil {
                        Image(systemName: "checkmark")
                    }
                    Text("All Types")
                }
            }

            Divider()

            typeMenuItem(.text, label: "Text", icon: "doc.text")
            richTextMenuItem()
            typeMenuItem(.image, label: "Image", icon: "photo")
            typeMenuItem(.file, label: "File", icon: "doc.fill")
        } label: {
            Image(systemName: currentTypeIcon)
                .font(.system(size: ScopySize.Icon.filter))
                .foregroundStyle(ScopyColors.mutedText)
        }
        .menuStyle(.borderlessButton)
        .help("Filter by type")
    }

    @ViewBuilder
    private func typeMenuItem(_ type: ClipboardItemType, label: String, icon: String) -> some View {
        Button(action: {
            appState.typeFilter = type
            appState.typeFilters = nil
            appState.search()
        }) {
            HStack {
                if appState.typeFilter == type && appState.typeFilters == nil {
                    Image(systemName: "checkmark")
                }
                Label(label, systemImage: icon)
            }
        }
    }

    /// Rich Text 菜单项 (rtf + html)
    @ViewBuilder
    private func richTextMenuItem() -> some View {
        Button(action: {
            appState.typeFilter = nil
            appState.typeFilters = Self.richTextTypes
            appState.search()
        }) {
            HStack {
                if isRichTextSelected {
                    Image(systemName: "checkmark")
                }
                Label("Rich Text", systemImage: "doc.richtext")
            }
        }
    }

    /// 当前过滤类型的图标
    private var currentTypeIcon: String {
        if isRichTextSelected {
            return "doc.richtext"
        }
        guard let type = appState.typeFilter else { return ScopyIcons.filterType }
        switch type {
        case .text: return "doc.text"
        case .image: return "photo"
        case .file: return "doc.fill"
        default: return ScopyIcons.filterType
        }
    }
}
