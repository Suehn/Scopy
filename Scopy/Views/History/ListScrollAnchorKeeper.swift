import AppKit

/// Keeps the row under the top edge of the history list where it is while the list's rows
/// change.
///
/// When the projection changes (a page lands, a row is inserted or removed), the List's
/// NSTableView asks for every row's height again and answers with its estimate for rows that
/// are not on screen. The document then shrinks or grows by the difference between measured and
/// estimated heights above the viewport, and the content under the viewport moves with it: the
/// jump seen after a fast scroll, which reaches the prefetch point while the momentum is still
/// running. The keeper records the row under the top edge and its offset before the change and
/// scrolls back to that row as soon as the table has re-tiled, so the same row stays in place.
@MainActor
final class ListScrollAnchorKeeper {
    private struct Anchor {
        /// The item under the top edge, or nil for a header or load-more row.
        let itemID: UUID?
        let row: Int
        let offset: CGFloat
    }

    /// Set by the scroll observer when it attaches to the List's scroll view.
    weak var scrollView: NSScrollView? {
        didSet {
            guard scrollView !== oldValue else { return }
            observeDocumentFrame()
        }
    }
    /// The history list's row order, supplied by the view that owns the List.
    var itemID: (Int) -> UUID? = { _ in nil }
    var row: (UUID) -> Int? = { _ in nil }
    var programmaticScrollGate: ListProgrammaticScrollGate?

    private var anchor: Anchor?
    private var documentFrameObserver: NSObjectProtocol?

    deinit {
        if let documentFrameObserver {
            NotificationCenter.default.removeObserver(documentFrameObserver)
        }
    }

    /// Records the row under the top edge; the first capture of a change wins until it is restored.
    func projectionWillChange() {
        guard anchor == nil, let scrollView, let tableView = scrollView.documentView as? NSTableView else { return }
        let visible = scrollView.contentView.documentVisibleRect
        let rows = tableView.rows(in: visible)
        guard rows.length > 0 else { return }
        let rowIndex = rows.location
        let rect = tableView.rect(ofRow: rowIndex)
        anchor = Anchor(itemID: itemID(rowIndex), row: rowIndex, offset: visible.origin.y - rect.origin.y)
    }

    /// The table re-tiles inside the SwiftUI update; its document frame change restores the row
    /// in the same frame. This clears the anchor once that update is over.
    func projectionDidChange() {
        guard anchor != nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.restore()
            self?.anchor = nil
        }
    }

    private func observeDocumentFrame() {
        if let documentFrameObserver {
            NotificationCenter.default.removeObserver(documentFrameObserver)
            self.documentFrameObserver = nil
        }
        guard let documentView = scrollView?.documentView else { return }
        documentView.postsFrameChangedNotifications = true
        documentFrameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: documentView,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.restore()
            }
        }
    }

    /// Scrolls so the anchored row sits where it was. A row whose item left the projection is
    /// not restored: the rows were replaced, not shifted.
    private func restore() {
        guard let anchor, let scrollView, let tableView = scrollView.documentView as? NSTableView else { return }
        let rowIndex: Int
        if let itemID = anchor.itemID {
            guard let current = row(itemID) else { return }
            rowIndex = current
        } else {
            rowIndex = anchor.row
        }
        guard rowIndex >= 0, rowIndex < tableView.numberOfRows else { return }
        let clipView = scrollView.contentView
        let target = tableView.rect(ofRow: rowIndex).origin.y + anchor.offset
        let maxY = max(0, tableView.frame.height - clipView.bounds.height)
        let y = min(max(0, target), maxY)
        guard abs(y - clipView.bounds.origin.y) >= 0.5 else { return }
        programmaticScrollGate?.beginProgrammaticScroll(duration: 0.05)
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clipView)
    }
}
