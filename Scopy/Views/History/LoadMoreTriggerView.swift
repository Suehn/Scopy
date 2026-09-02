import SwiftUI
import ScopyKit

/// Reads `isLoading` itself so the List body does not observe it: the flag toggles around every
/// search and page load.
struct LoadMoreTriggerView: View {
    @Environment(HistoryViewModel.self) private var historyViewModel

    var body: some View {
        let isLoading = historyViewModel.isLoading
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
