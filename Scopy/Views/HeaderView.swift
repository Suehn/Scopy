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

    var body: some View {
        Menu {
            ForEach(SearchMode.allCases, id: \.self) { mode in
                Button {
                    appState.searchMode = mode
                    appState.search()
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

        // LRU 清理：名称缓存也需要限制大小
        if Self.nameCache.count >= Self.maxCacheSize {
            Self.nameCache.removeAll()  // 简单策略：满了就清空
        }

        Self.nameCache[bundleID] = name
        Self.cacheLock.unlock()

        return name
    }
}

// MARK: - Type Filter Button

struct TypeFilterButton: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Menu {
            Button(action: {
                appState.typeFilter = nil
                appState.search()
            }) {
                HStack {
                    if appState.typeFilter == nil {
                        Image(systemName: "checkmark")
                    }
                    Text("All Types")
                }
            }

            Divider()

            typeMenuItem(.text, label: "Text", icon: "doc.text")
            typeMenuItem(.image, label: "Image", icon: "photo")
            typeMenuItem(.file, label: "File", icon: "doc.fill")
        } label: {
            Image(systemName: typeIcon(appState.typeFilter))
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
            appState.search()
        }) {
            HStack {
                if appState.typeFilter == type {
                    Image(systemName: "checkmark")
                }
                Label(label, systemImage: icon)
            }
        }
    }

    private func typeIcon(_ type: ClipboardItemType?) -> String {
        guard let type else { return ScopyIcons.filterType }
        switch type {
        case .text: return "doc.text"
        case .image: return "photo"
        case .file: return "doc.fill"
        default: return ScopyIcons.filterType
        }
    }
}
