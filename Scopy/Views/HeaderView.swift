import AppKit
import SwiftUI

/// 头部视图 - 包含标题、过滤按钮和搜索框
struct HeaderView: View {
    @Binding var searchQuery: String
    @FocusState.Binding var searchFocused: Bool

    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 6) {
            Text("Scopy")
                .foregroundStyle(.secondary)
                .font(.system(size: 12, weight: .medium))

            // App 过滤按钮
            AppFilterButton()

            // Type 过滤按钮
            TypeFilterButton()

            SearchFieldView(
                query: $searchQuery,
                searchFocused: $searchFocused
            )
            .frame(maxWidth: .infinity)
        }
        .frame(height: 28)
        .padding(.horizontal, 10)
        .padding(.bottom, 5)
    }
}

// MARK: - App Filter Button

struct AppFilterButton: View {
    @Environment(AppState.self) private var appState

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
            HStack(spacing: 2) {
                Image(systemName: "app.badge")
                    .font(.system(size: 11))
                if appState.appFilter != nil {
                    Circle()
                        .fill(.blue)
                        .frame(width: 5, height: 5)
                }
            }
            .foregroundStyle(appState.appFilter != nil ? .blue : .secondary)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 24)
        .help("Filter by app")
    }

    private func appIcon(for bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func appName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        return url.deletingPathExtension().lastPathComponent
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
            HStack(spacing: 2) {
                Image(systemName: "doc.text")
                    .font(.system(size: 11))
                if appState.typeFilter != nil {
                    Circle()
                        .fill(.blue)
                        .frame(width: 5, height: 5)
                }
            }
            .foregroundStyle(appState.typeFilter != nil ? .blue : .secondary)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 24)
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
}

/// 搜索框视图
struct SearchFieldView: View {
    @Binding var query: String
    @FocusState.Binding var searchFocused: Bool

    @Environment(AppState.self) private var appState

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.secondary.opacity(0.1))
                .frame(height: 23)

            HStack {
                Image(systemName: "magnifyingglass")
                    .frame(width: 11, height: 11)
                    .padding(.leading, 5)
                    .opacity(0.8)

                TextField("Search...", text: $query)
                    .disableAutocorrection(true)
                    .lineLimit(1)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onChange(of: query) {
                        appState.search()
                    }
                    .onSubmit {
                        Task { await appState.selectCurrent() }
                    }

                if !query.isEmpty {
                    Button {
                        query = ""
                        appState.search()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .frame(width: 11, height: 11)
                            .padding(.trailing, 5)
                    }
                    .buttonStyle(.plain)
                    .opacity(0.9)
                }
            }
        }
    }
}
