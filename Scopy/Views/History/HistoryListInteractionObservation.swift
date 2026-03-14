import Foundation

final class HistoryListInteractionObservation {
    private var cancelClosure: (() -> Void)?

    init(cancel: @escaping () -> Void) {
        self.cancelClosure = cancel
    }

    func cancel() {
        guard let cancelClosure else { return }
        self.cancelClosure = nil
        cancelClosure()
    }

    deinit {
        cancel()
    }
}
