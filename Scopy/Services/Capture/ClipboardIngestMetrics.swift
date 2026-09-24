import Foundation

public actor ClipboardIngestMetrics {
    public static let shared = ClipboardIngestMetrics()

    private var pendingCount = 0
    private var activeCount = 0
    private var persistedCount = 0
    private var softLimitHitCount = 0
    private var replayCount = 0
    private var changeJumpCount = 0
    private var maxObservedChangeDelta = 1
    private var lastPersistedAt: Date?
    private var lastAcknowledgedAt: Date?
    private var lastReplayAt: Date?

    public func recordChangeDelta(_ delta: Int) {
        guard delta > 1 else { return }
        changeJumpCount += 1
        maxObservedChangeDelta = max(maxObservedChangeDelta, delta)
    }

    public func recordSoftLimitHit() {
        softLimitHitCount += 1
    }

    public func recordReplay(count: Int) {
        guard count > 0 else { return }
        replayCount += count
        lastReplayAt = Date()
    }

    public func recordPersistedEnvelope() {
        lastPersistedAt = Date()
    }

    public func recordAcknowledgedEnvelope() {
        lastAcknowledgedAt = Date()
    }

    public func updateQueueSnapshot(pendingCount: Int, activeCount: Int, persistedCount: Int) {
        self.pendingCount = pendingCount
        self.activeCount = activeCount
        self.persistedCount = persistedCount
    }

    public func reset() {
        pendingCount = 0
        activeCount = 0
        persistedCount = 0
        softLimitHitCount = 0
        replayCount = 0
        changeJumpCount = 0
        maxObservedChangeDelta = 1
        lastPersistedAt = nil
        lastAcknowledgedAt = nil
        lastReplayAt = nil
    }

    public func getSummary() async -> ClipboardIngestSummary {
        ClipboardIngestSummary(
            pendingCount: pendingCount,
            activeCount: activeCount,
            persistedCount: persistedCount,
            softLimitHitCount: softLimitHitCount,
            replayCount: replayCount,
            changeJumpCount: changeJumpCount,
            maxObservedChangeDelta: maxObservedChangeDelta,
            lastPersistedAt: lastPersistedAt,
            lastAcknowledgedAt: lastAcknowledgedAt,
            lastReplayAt: lastReplayAt
        )
    }
}

public struct ClipboardIngestSummary: Sendable {
    public let pendingCount: Int
    public let activeCount: Int
    public let persistedCount: Int
    public let softLimitHitCount: Int
    public let replayCount: Int
    public let changeJumpCount: Int
    public let maxObservedChangeDelta: Int
    public let lastPersistedAt: Date?
    public let lastAcknowledgedAt: Date?
    public let lastReplayAt: Date?
}
