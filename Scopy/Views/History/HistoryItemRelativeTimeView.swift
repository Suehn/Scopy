import SwiftUI

/// Only this leaf observes the clock. A time tick must not rebuild the row's interaction host.
@MainActor
struct HistoryItemRelativeTimeView: View {
    @Environment(\.historyRelativeTimeClock) private var clock

    let itemID: UUID
    let lastUsedAt: Date

    var body: some View {
        let bucket = clock?.bucket ?? HistoryRelativeTimeClock.bucket(for: Date())
        Text(HistoryItemPresentationCache.shared.relativeTimeText(
            itemID: itemID,
            lastUsedAt: lastUsedAt,
            bucket: bucket
        ))
    }
}
