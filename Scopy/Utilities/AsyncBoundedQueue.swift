import Foundation

/// A small, backpressured async queue for bridging producers to `AsyncStream(unfolding:)`.
///
/// - Guarantees: no dropping; producers suspend when buffer is full.
/// - Intended use: avoid `AsyncStream` `.unbounded` buffering while preserving event ordering.
actor AsyncBoundedQueue<Element: Sendable> {
    private let capacity: Int
    private var buffer: [Element?]
    private var headIndex: Int = 0
    private var tailIndex: Int = 0
    private var bufferedCount: Int = 0
    private var isFinished = false

    private struct ReceiverWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Element?, Never>
    }

    private struct SenderWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    private var waitingReceivers: [ReceiverWaiter] = []
    private var waitingSenders: [SenderWaiter] = []

    init(capacity: Int) {
        let safeCapacity = max(1, capacity)
        self.capacity = safeCapacity
        self.buffer = Array(repeating: nil, count: safeCapacity)
    }

    func enqueue(_ element: Element) async {
        guard !isFinished else { return }
        guard !Task.isCancelled else { return }

        if !waitingReceivers.isEmpty {
            let receiver = waitingReceivers.removeFirst()
            receiver.continuation.resume(returning: element)
            return
        }

        while bufferedCount >= capacity && !isFinished {
            guard !Task.isCancelled else { return }
            let waiterID = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { cont in
                    waitingSenders.append(SenderWaiter(id: waiterID, continuation: cont))
                }
            } onCancel: {
                Task { [weak self] in
                    await self?.cancelSender(id: waiterID)
                }
            }
        }
        guard !isFinished else { return }
        guard !Task.isCancelled else { return }

        if !waitingReceivers.isEmpty {
            let receiver = waitingReceivers.removeFirst()
            receiver.continuation.resume(returning: element)
            return
        }

        buffer[tailIndex] = element
        tailIndex = (tailIndex + 1) % capacity
        bufferedCount += 1
    }

    func dequeue() async -> Element? {
        if bufferedCount > 0 {
            let element = buffer[headIndex]
            buffer[headIndex] = nil
            headIndex = (headIndex + 1) % capacity
            bufferedCount -= 1
            if !waitingSenders.isEmpty {
                let sender = waitingSenders.removeFirst()
                sender.continuation.resume()
            }
            return element
        }

        if isFinished {
            return nil
        }

        if Task.isCancelled {
            return nil
        }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                waitingReceivers.append(ReceiverWaiter(id: waiterID, continuation: cont))
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelReceiver(id: waiterID)
            }
        }
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true

        let receivers = waitingReceivers
        waitingReceivers.removeAll()
        receivers.forEach { $0.continuation.resume(returning: nil) }

        let senders = waitingSenders
        waitingSenders.removeAll()
        senders.forEach { $0.continuation.resume() }
    }

    private func cancelReceiver(id: UUID) {
        guard let index = waitingReceivers.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waitingReceivers.remove(at: index)
        waiter.continuation.resume(returning: nil)
    }

    private func cancelSender(id: UUID) {
        guard let index = waitingSenders.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waitingSenders.remove(at: index)
        waiter.continuation.resume()
    }
}
