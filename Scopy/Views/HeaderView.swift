import SwiftUI

/// 头部视图 - 包含标题和搜索框
struct HeaderView: View {
    @Binding var searchQuery: String
    @FocusState.Binding var searchFocused: Bool

    @Environment(AppState.self) private var appState

    var body: some View {
        HStack {
            Text("Scopy")
                .foregroundStyle(.secondary)
                .font(.system(size: 12, weight: .medium))

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
