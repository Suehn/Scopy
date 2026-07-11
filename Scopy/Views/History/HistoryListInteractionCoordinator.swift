import Foundation
import ScopyUISupport

@MainActor
final class HistoryListInteractionCoordinator {
    enum Event: Equatable {
        case scrollStarted
        case scrollEnded
        case pointerInteractionStarted
        case pointerInteractionEnded
        case hoverPreviewTransferEnded(itemID: UUID)
    }

    /// A fresh ownership token for one passive-row activation attempt.
    ///
    /// Callers must not reuse a token after releasing it. A fresh token on every claim is what
    /// makes delayed A -> B -> A cancellation unable to clear the newest A ownership.
    struct PassiveRowToken: Hashable, Sendable {
        fileprivate let rawValue: UUID

        fileprivate init(rawValue: UUID = UUID()) {
            self.rawValue = rawValue
        }
    }

    struct PointerInteractionToken: Hashable, Sendable {
        fileprivate let rawValue: UUID

        fileprivate init(rawValue: UUID = UUID()) {
            self.rawValue = rawValue
        }
    }

    struct HoverPreviewTransferToken: Hashable, Sendable {
        fileprivate let rawValue: UUID
        fileprivate let itemID: UUID

        fileprivate init(itemID: UUID, rawValue: UUID = UUID()) {
            self.itemID = itemID
            self.rawValue = rawValue
        }
    }

    struct PassivePathSnapshot: Equatable {
        let activeRowCount: Int
        let suppressedHoverCandidateCount: Int
        let cooldownTaskCount: Int
        let pointerInteractionCount: Int
        let cooldownGeneration: UInt64
    }

    final class CooldownCancellation {
        private var cancelClosure: (() -> Void)?

        init(cancel: @escaping () -> Void) {
            cancelClosure = cancel
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

    typealias CooldownAction = @MainActor @Sendable () -> Void
    typealias CooldownScheduler = (
        _ delay: CFTimeInterval,
        _ action: @escaping CooldownAction
    ) -> CooldownCancellation
    typealias PassivePathSnapshotSink = @MainActor (PassivePathSnapshot) -> Void

    private struct ActiveRowSlot {
        let token: PassiveRowToken
        let eventSink: (Event) -> Void
        let restore: () -> Void
    }

    private struct SuppressedHoverCandidate {
        let token: PassiveRowToken
        let restore: () -> Void
    }

    nonisolated private static let defaultHoverPreviewCooldownAfterScrollSeconds: CFTimeInterval = 0.25

    private let hoverPreviewCooldownAfterScrollSeconds: CFTimeInterval
    private let monotonicNow: () -> CFTimeInterval
    private let scheduleCooldown: CooldownScheduler
    private let passivePathSnapshotSink: PassivePathSnapshotSink

    private(set) var isScrolling = false
    var hoverPreviewTransferOwnerID: UUID? {
        hoverPreviewTransferToken?.itemID
    }

    private var pointerInteractionToken: PointerInteractionToken?
    private var hoverPreviewTransferToken: HoverPreviewTransferToken?
    private var lastScrollEndDeadline: CFTimeInterval?
    private var activeRowSlot: ActiveRowSlot?
    private var suppressedHoverCandidate: SuppressedHoverCandidate?
    private var cooldownCancellation: CooldownCancellation?
    private var cooldownGeneration: UInt64 = 0

    // Transitional compatibility path. Passive rows use the O(1) slot API below; the legacy
    // observer broadcast remains available for same-binary profiling and incremental migration.
    private var observers: [UUID: (Event) -> Void] = [:]

    init(
        hoverPreviewCooldownAfterScrollSeconds: CFTimeInterval =
            HistoryListInteractionCoordinator.defaultHoverPreviewCooldownAfterScrollSeconds,
        monotonicNow: @escaping () -> CFTimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        scheduleCooldown: @escaping CooldownScheduler =
            HistoryListInteractionCoordinator.productionCooldownScheduler,
        passivePathSnapshotSink: @escaping PassivePathSnapshotSink = { snapshot in
            guard ScrollPerformanceProfile.isEnabled else { return }
            ScrollPerformanceProfile.shared.recordPassivePathSnapshot(
                activeSlotCount: snapshot.activeRowCount,
                suppressedCandidateCount: snapshot.suppressedHoverCandidateCount
            )
        }
    ) {
        self.hoverPreviewCooldownAfterScrollSeconds = hoverPreviewCooldownAfterScrollSeconds
        self.monotonicNow = monotonicNow
        self.scheduleCooldown = scheduleCooldown
        self.passivePathSnapshotSink = passivePathSnapshotSink
        publishPassivePathSnapshot()
    }

    var isPointerInteractionActive: Bool {
        pointerInteractionToken != nil
    }

    var isHoverPreviewSuppressed: Bool {
        if isScrolling || isPointerInteractionActive {
            return true
        }

        guard let lastScrollEndDeadline else { return false }
        return monotonicNow() < lastScrollEndDeadline
    }

    var passivePathSnapshot: PassivePathSnapshot {
        PassivePathSnapshot(
            activeRowCount: activeRowSlot == nil ? 0 : 1,
            suppressedHoverCandidateCount: suppressedHoverCandidate == nil ? 0 : 1,
            cooldownTaskCount: cooldownCancellation == nil ? 0 : 1,
            pointerInteractionCount: pointerInteractionToken == nil ? 0 : 1,
            cooldownGeneration: cooldownGeneration
        )
    }

    func makePassiveRowToken() -> PassiveRowToken {
        PassiveRowToken()
    }

    /// Claims the sole passive-path active-row slot when interaction is allowed.
    ///
    /// During suppression the row remains passive and becomes the sole lightweight restoration
    /// candidate instead. The return value tells the caller whether it may create or retain its
    /// heavyweight interaction session now.
    @discardableResult
    func claimActiveRow(
        token: PassiveRowToken,
        onEvent: @escaping (Event) -> Void,
        restore: @escaping () -> Void
    ) -> Bool {
        guard !isHoverPreviewSuppressed else {
            setSuppressedHoverCandidate(token: token, restore: restore)
            return false
        }

        invalidateCooldown(keepDeadline: false)
        suppressedHoverCandidate = nil
        activeRowSlot = ActiveRowSlot(
            token: token,
            eventSink: onEvent,
            restore: restore
        )
        publishPassivePathSnapshot()
        return true
    }

    /// Replaces the sole restoration candidate while suppression is active.
    ///
    /// The token belongs to this candidate claim, not just to an item ID. A delayed clear for an
    /// older candidate is therefore harmless even when the row identity cycles A -> B -> A.
    @discardableResult
    func setSuppressedHoverCandidate(
        token: PassiveRowToken,
        restore: @escaping () -> Void
    ) -> Bool {
        guard isHoverPreviewSuppressed else { return false }

        suppressedHoverCandidate = SuppressedHoverCandidate(token: token, restore: restore)
        rescheduleCandidateRestoreIfNeeded()
        publishPassivePathSnapshot()
        return true
    }

    func releaseActiveRow(token: PassiveRowToken) {
        guard activeRowSlot?.token == token else { return }
        activeRowSlot = nil
        publishPassivePathSnapshot()
    }

    func clearSuppressedHoverCandidate(token: PassiveRowToken) {
        guard suppressedHoverCandidate?.token == token else { return }
        suppressedHoverCandidate = nil
        invalidateCooldown(keepDeadline: true)
        publishPassivePathSnapshot()
    }

    func releasePassiveRow(token: PassiveRowToken) {
        releaseActiveRow(token: token)
        clearSuppressedHoverCandidate(token: token)
    }

    func ownsActiveRow(token: PassiveRowToken) -> Bool {
        activeRowSlot?.token == token
    }

    func ownsSuppressedHoverCandidate(token: PassiveRowToken) -> Bool {
        suppressedHoverCandidate?.token == token
    }

    func observe(_ observer: @escaping (Event) -> Void) -> HistoryListInteractionObservation {
        let id = UUID()
        observers[id] = observer
        return HistoryListInteractionObservation { [weak self] in
            self?.observers.removeValue(forKey: id)
        }
    }

    func beginScrolling() {
        guard !isScrolling else { return }

        invalidateCooldown(keepDeadline: false)
        preserveActiveRowAsCandidateIfNeeded()
        isScrolling = true
        publishPassivePathSnapshot()
        notifyAndRetireActiveRow(.scrollStarted)
        notifyLegacyObservers(.scrollStarted)
        publishPassivePathSnapshot()
    }

    func endScrolling() {
        guard isScrolling else { return }

        isScrolling = false
        lastScrollEndDeadline = monotonicNow() + hoverPreviewCooldownAfterScrollSeconds
        publishPassivePathSnapshot()
        notifyLegacyObservers(.scrollEnded)
        scheduleOrRestoreCandidate()
        publishPassivePathSnapshot()
    }

    @discardableResult
    func beginPointerInteraction() -> PointerInteractionToken {
        if pointerInteractionToken != nil {
            // Replace ownership without allowing the old session's teardown to restore between
            // the paired end/start transitions.
            pointerInteractionToken = nil
            publishPassivePathSnapshot()
            notifyLegacyObservers(.pointerInteractionEnded)
        }

        invalidateCooldown(keepDeadline: true)
        preserveActiveRowAsCandidateIfNeeded()

        let token = PointerInteractionToken()
        pointerInteractionToken = token
        publishPassivePathSnapshot()
        notifyAndRetireActiveRow(.pointerInteractionStarted)
        notifyLegacyObservers(.pointerInteractionStarted)
        publishPassivePathSnapshot()
        return token
    }

    func endPointerInteraction(token: PointerInteractionToken) {
        guard pointerInteractionToken == token else { return }
        pointerInteractionToken = nil
        publishPassivePathSnapshot()
        notifyLegacyObservers(.pointerInteractionEnded)
        scheduleOrRestoreCandidate()
        publishPassivePathSnapshot()
    }

    /// Compatibility cleanup for legacy callers. New production adapters must retain the token
    /// returned by `beginPointerInteraction()` and use the token-matched overload above.
    func endPointerInteraction() {
        guard let pointerInteractionToken else { return }
        endPointerInteraction(token: pointerInteractionToken)
    }

    /// Cancels every passive-path ownership and scheduled restoration. The legacy observer table
    /// intentionally remains intact because its observations own their own cancellation lifetime.
    func tearDownPassivePath() {
        invalidateCooldown(keepDeadline: false)
        activeRowSlot = nil
        suppressedHoverCandidate = nil
        pointerInteractionToken = nil
        hoverPreviewTransferToken = nil
        publishPassivePathSnapshot()
    }

    /// Claims the short row-to-popover handoff for one source row. Other rows stay visually
    /// hoverable, but defer selection and preview work until this ownership ends.
    @discardableResult
    func beginHoverPreviewTransfer(for itemID: UUID) -> Bool {
        if hoverPreviewTransferOwnerID == itemID {
            return true
        }
        guard hoverPreviewTransferToken == nil else {
            return false
        }
        hoverPreviewTransferToken = HoverPreviewTransferToken(itemID: itemID)
        publishPassivePathSnapshot()
        return true
    }

    /// Tokenized production ownership. A delayed completion from an old safe-corridor intent
    /// cannot end a newer transfer for the same row ID.
    func beginHoverPreviewTransferToken(
        for itemID: UUID
    ) -> HoverPreviewTransferToken? {
        guard hoverPreviewTransferToken == nil else { return nil }
        let token = HoverPreviewTransferToken(itemID: itemID)
        hoverPreviewTransferToken = token
        publishPassivePathSnapshot()
        return token
    }

    func endHoverPreviewTransfer(token: HoverPreviewTransferToken) {
        guard hoverPreviewTransferToken == token else { return }
        finishHoverPreviewTransfer(itemID: token.itemID)
    }

    func endHoverPreviewTransfer(for itemID: UUID) {
        guard hoverPreviewTransferOwnerID == itemID else { return }
        finishHoverPreviewTransfer(itemID: itemID)
    }

    private func finishHoverPreviewTransfer(itemID: UUID) {
        hoverPreviewTransferToken = nil
        publishPassivePathSnapshot()
        let event = Event.hoverPreviewTransferEnded(itemID: itemID)
        // Passive rows do not install legacy broadcast observers. Route the unblock event to the
        // sole active row so a row that entered while the safe corridor was owned can resume its
        // normal hover path without reintroducing O(visible rows) fan-out.
        activeRowSlot?.eventSink(event)
        notifyLegacyObservers(event)
    }

    func isHoverPreviewTransferBlocked(for itemID: UUID) -> Bool {
        guard let ownerID = hoverPreviewTransferOwnerID else { return false }
        return ownerID != itemID
    }

    private func preserveActiveRowAsCandidateIfNeeded() {
        guard suppressedHoverCandidate == nil, let activeRowSlot else { return }
        suppressedHoverCandidate = SuppressedHoverCandidate(
            token: activeRowSlot.token,
            restore: activeRowSlot.restore
        )
        publishPassivePathSnapshot()
    }

    private func notifyAndRetireActiveRow(_ event: Event) {
        guard let slot = activeRowSlot else { return }
        // Retire before invoking user code so reentrant claims cannot be cleared after the sink
        // returns, and repeated suppression starts cannot notify an already-suspended row again.
        activeRowSlot = nil
        publishPassivePathSnapshot()
        slot.eventSink(event)
    }

    private func rescheduleCandidateRestoreIfNeeded() {
        guard !isScrolling, !isPointerInteractionActive, lastScrollEndDeadline != nil else {
            return
        }
        invalidateCooldown(keepDeadline: true)
        scheduleOrRestoreCandidate()
    }

    private func scheduleOrRestoreCandidate() {
        guard let candidate = suppressedHoverCandidate else {
            invalidateCooldown(keepDeadline: true)
            return
        }
        guard !isScrolling, !isPointerInteractionActive else { return }

        guard let lastScrollEndDeadline else {
            consumeAndRestore(candidate)
            return
        }

        let remainingDelay = lastScrollEndDeadline - monotonicNow()
        guard remainingDelay > 0 else {
            consumeAndRestore(candidate)
            return
        }

        invalidateCooldown(keepDeadline: true)
        let generation = cooldownGeneration
        cooldownCancellation = scheduleCooldown(remainingDelay) { [weak self] in
            self?.cooldownDidElapse(generation: generation)
        }
        publishPassivePathSnapshot()
    }

    private func cooldownDidElapse(generation: UInt64) {
        guard generation == cooldownGeneration else { return }
        cooldownCancellation = nil
        publishPassivePathSnapshot()
        guard !isScrolling, !isPointerInteractionActive,
              let candidate = suppressedHoverCandidate
        else { return }
        consumeAndRestore(candidate)
    }

    private func consumeAndRestore(_ candidate: SuppressedHoverCandidate) {
        guard suppressedHoverCandidate?.token == candidate.token else { return }
        suppressedHoverCandidate = nil
        activeRowSlot = nil
        lastScrollEndDeadline = nil
        invalidateCooldown(keepDeadline: false)
        candidate.restore()
    }

    private func invalidateCooldown(keepDeadline: Bool) {
        cooldownGeneration &+= 1
        cooldownCancellation?.cancel()
        cooldownCancellation = nil
        if !keepDeadline {
            lastScrollEndDeadline = nil
        }
        publishPassivePathSnapshot()
    }

    private func publishPassivePathSnapshot() {
        passivePathSnapshotSink(passivePathSnapshot)
    }

    private func notifyLegacyObservers(_ event: Event) {
        // A callback may cancel itself or another legacy observation. Iterate a stable snapshot so
        // that mutation is safe and affects only subsequent events.
        for observer in Array(observers.values) {
            observer(event)
        }
    }

    nonisolated private static func productionCooldownScheduler(
        delay: CFTimeInterval,
        action: @escaping CooldownAction
    ) -> CooldownCancellation {
        let task = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            action()
        }
        return CooldownCancellation {
            task.cancel()
        }
    }
}
