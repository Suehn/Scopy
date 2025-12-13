import AppKit
import ScopyKit
import SwiftUI

/// 头部视图 - 包含标题、过滤按钮和搜索框
struct HeaderView: View {
    @Binding var searchQuery: String
    @FocusState.Binding var searchFocused: Bool

    @Environment(HistoryViewModel.self) private var historyViewModel

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
                    historyViewModel.search()
                }
                .onSubmit {
                    Task { await historyViewModel.selectCurrent() }
                }

            Spacer()

            // Filters & Actions
            HStack(spacing: ScopySpacing.sm) {
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                        historyViewModel.search()
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
    @Environment(HistoryViewModel.self) private var historyViewModel
    @Environment(SettingsViewModel.self) private var settingsViewModel
    /// v0.22: 保存设置任务引用，支持取消，防止内存泄漏
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        Menu {
            ForEach(SearchMode.allCases, id: \.self) { mode in
                Button {
                    historyViewModel.searchMode = mode
                    historyViewModel.search()
                    // v0.22: 取消之前的保存任务，防止快速切换时任务累积
                    saveTask?.cancel()
                    // 持久化到设置
                    saveTask = Task {
                        guard !Task.isCancelled else { return }
                        var newSettings = settingsViewModel.settings
                        newSettings.defaultSearchMode = mode
                        await settingsViewModel.updateSettings(newSettings)
                    }
                } label: {
                    HStack {
                        if mode == historyViewModel.searchMode {
                            Image(systemName: "checkmark")
                        }
                        Text(modeLabel(mode))
                    }
                }
            }
        } label: {
            Image(systemName: modeIcon(historyViewModel.searchMode))
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
    @Environment(HistoryViewModel.self) private var historyViewModel

    var body: some View {
        Menu {
            Button(action: {
                historyViewModel.appFilter = nil
                historyViewModel.search()
            }) {
                HStack {
                    if historyViewModel.appFilter == nil {
                        Image(systemName: "checkmark")
                    }
                    Text("All Apps")
                }
            }

            if !historyViewModel.recentApps.isEmpty {
                Divider()

                ForEach(historyViewModel.recentApps, id: \.self) { bundleID in
                    Button(action: {
                        historyViewModel.appFilter = bundleID
                        historyViewModel.search()
                    }) {
                        HStack {
                            if historyViewModel.appFilter == bundleID {
                                Image(systemName: "checkmark")
                            }
                            if let icon = appIcon(for: bundleID) {
                                Image(nsImage: icon)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: ScopySize.Icon.menuApp, height: ScopySize.Icon.menuApp)
                            }
                            Text(appName(for: bundleID))
                        }
                    }
                }
            }
        } label: {
            if let bundleID = historyViewModel.appFilter, let icon = appIcon(for: bundleID) {
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

    private func appIcon(for bundleID: String) -> NSImage? {
        IconService.shared.icon(bundleID: bundleID)
    }

    private func appName(for bundleID: String) -> String {
        IconService.shared.appName(bundleID: bundleID)
    }
}

// MARK: - Type Filter Button

/// v0.22: 添加 Rich Text 选项，支持 rtf + html 类型过滤
struct TypeFilterButton: View {
    @Environment(HistoryViewModel.self) private var historyViewModel

    /// Rich Text 类型集合 (rtf + html)
    private static let richTextTypes: Set<ClipboardItemType> = [.rtf, .html]

    /// 当前是否选中 Rich Text 过滤
    private var isRichTextSelected: Bool {
        historyViewModel.typeFilters == Self.richTextTypes
    }

    var body: some View {
        Menu {
            Button(action: {
                historyViewModel.typeFilter = nil
                historyViewModel.typeFilters = nil
                historyViewModel.search()
            }) {
                HStack {
                    if historyViewModel.typeFilter == nil && historyViewModel.typeFilters == nil {
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
            historyViewModel.typeFilter = type
            historyViewModel.typeFilters = nil
            historyViewModel.search()
        }) {
            HStack {
                if historyViewModel.typeFilter == type && historyViewModel.typeFilters == nil {
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
            historyViewModel.typeFilter = nil
            historyViewModel.typeFilters = Self.richTextTypes
            historyViewModel.search()
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
        guard let type = historyViewModel.typeFilter else { return ScopyIcons.filterType }
        switch type {
        case .text: return "doc.text"
        case .image: return "photo"
        case .file: return "doc.fill"
        default: return ScopyIcons.filterType
        }
    }
}
