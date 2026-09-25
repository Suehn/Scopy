import Foundation

actor ClipboardEventQueue {
    struct PublicationToken: Sendable, Equatable {
        let itemID: UUID
        let sequence: UInt64
        let clearGeneration: UInt64
    }

    private struct PublicationState {
        var highestSequence: UInt64
        var outstanding: Set<UInt64>
    }

    private struct ReceiverWaiter {
        let id: UUID
        let continuation: CheckedContinuation<ClipboardEvent?, Never>
    }

    private struct SenderWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    private let capacity: Int
    private var buffer: [ClipboardEvent?]
    private var headIndex = 0
    private var tailIndex = 0
    private var bufferedCount = 0
    private var isFinished = false
    private var nextSequence: UInt64 = 0
    private var clearGeneration: UInt64 = 0
    private var publications: [UUID: PublicationState] = [:]
    private var waitingReceivers: [ReceiverWaiter] = []
    private var waitingSenders: [SenderWaiter] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        self.buffer = Array(repeating: nil, count: max(1, capacity))
    }

    func reservePublication(itemID: UUID) -> PublicationToken {
        nextSequence &+= 1
        let token = PublicationToken(
            itemID: itemID,
            sequence: nextSequence,
            clearGeneration: clearGeneration
        )
        var state = publications[itemID] ?? PublicationState(
            highestSequence: token.sequence,
            outstanding: []
        )
        state.highestSequence = max(state.highestSequence, token.sequence)
        state.outstanding.insert(token.sequence)
        publications[itemID] = state
        return token
    }

    func advanceClearGeneration() {
        clearGeneration &+= 1
        publications.removeAll(keepingCapacity: true)
    }

    /// Invalidates only publications for rows a bulk cleanup actually deleted. Older suspended
    /// per-item senders then fail `isLatest`, while unrelated item publications remain intact.
    func invalidatePublications(itemIDs: [UUID]) {
        guard !itemIDs.isEmpty else { return }
        for itemID in Set(itemIDs) {
            publications.removeValue(forKey: itemID)
        }
    }

    func discardPublication(_ token: PublicationToken) {
        abandonPublication(token)
    }

    @discardableResult
    func enqueue(_ event: ClipboardEvent, publication token: PublicationToken? = nil) async -> Bool {
        guard !isFinished, !Task.isCancelled else {
            if let token { abandonPublication(token) }
            return false
        }

        while bufferedCount >= capacity, !isFinished {
            guard !Task.isCancelled else {
                if let token { abandonPublication(token) }
                return false
            }
            let waiterID = UUID()
            await withTaskCancellationHandler(operation: {
                await withCheckedContinuation { continuation in
                    waitingSenders.append(SenderWaiter(id: waiterID, continuation: continuation))
                }
            }, onCancel: {
                Task { await self.cancelSender(id: waiterID) }
            })
        }

        guard !isFinished, !Task.isCancelled else {
            if let token { abandonPublication(token) }
            return false
        }
        if let token, !isLatest(token) {
            completePublication(token)
            wakeOneSenderIfCapacityAvailable()
            return false
        }

        if !waitingReceivers.isEmpty {
            let receiver = waitingReceivers.removeFirst()
            receiver.continuation.resume(returning: event)
        } else {
            buffer[tailIndex] = event
            tailIndex = (tailIndex + 1) % capacity
            bufferedCount += 1
        }
        if let token { completePublication(token) }
        return true
    }

    func dequeue() async -> ClipboardEvent? {
        if bufferedCount > 0 {
            let event = buffer[headIndex]
            buffer[headIndex] = nil
            headIndex = (headIndex + 1) % capacity
            bufferedCount -= 1
            wakeOneSenderIfCapacityAvailable()
            return event
        }
        guard !isFinished, !Task.isCancelled else { return nil }

        let waiterID = UUID()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                waitingReceivers.append(ReceiverWaiter(id: waiterID, continuation: continuation))
            }
        }, onCancel: {
            Task { await self.cancelReceiver(id: waiterID) }
        })
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        publications.removeAll(keepingCapacity: false)
        let receivers = waitingReceivers
        waitingReceivers.removeAll()
        receivers.forEach { $0.continuation.resume(returning: nil) }
        let senders = waitingSenders
        waitingSenders.removeAll()
        senders.forEach { $0.continuation.resume() }
    }

    private func isLatest(_ token: PublicationToken) -> Bool {
        guard token.clearGeneration == clearGeneration,
              let state = publications[token.itemID] else { return false }
        return token.sequence == state.highestSequence && state.outstanding.contains(token.sequence)
    }

    /// Retires a publication that did deliver an event. The watermark stays where it is so the
    /// publications this one superseded remain stale.
    private func completePublication(_ token: PublicationToken) {
        guard var state = publications[token.itemID] else { return }
        state.outstanding.remove(token.sequence)
        if state.outstanding.isEmpty {
            publications.removeValue(forKey: token.itemID)
        } else {
            publications[token.itemID] = state
        }
    }

    /// Retires a publication that delivered nothing (authoritative state could not be built, or
    /// the queue was cancelled). Unlike a completed publication it must give the watermark back:
    /// otherwise the publications it superseded also fail `isLatest`, and an item whose row did
    /// change reaches the UI through no event at all until the next full reload.
    private func abandonPublication(_ token: PublicationToken) {
        guard var state = publications[token.itemID] else { return }
        state.outstanding.remove(token.sequence)
        guard !state.outstanding.isEmpty else {
            publications.removeValue(forKey: token.itemID)
            return
        }
        if state.highestSequence == token.sequence,
           let highestRemaining = state.outstanding.max() {
            state.highestSequence = highestRemaining
        }
        publications[token.itemID] = state
    }

    private func wakeOneSenderIfCapacityAvailable() {
        guard bufferedCount < capacity, !waitingSenders.isEmpty else { return }
        let sender = waitingSenders.removeFirst()
        sender.continuation.resume()
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
