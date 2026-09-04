import SwiftUI
import AppKit
import ScopyKit
import ScopyUISupport

// MARK: - History Item View (v0.9.3 - 性能优化版)

/// 单个历史项视图 - 实现 Equatable 以优化重绘
/// v0.9.3: 使用局部悬停状态 + 防抖 + Equatable 优化滚动性能
/// Row bookkeeping that never affects what is drawn: liveness, pointer presence and the two
/// ownership tokens. Held by reference so writing it does not invalidate the row's body.
@MainActor
final class HistoryRowControlState {
    var isAppeared = false
    var isPointerInsideRow = false
    var passiveRowToken: HistoryListInteractionCoordinator.PassiveRowToken?
    var sessionAttachmentToken: HistoryItemInteractionSessionStore.AttachmentToken?
}

@MainActor
struct HistoryItemView: View, Equatable {
    @Environment(\.historyRelativeTimeClock) private var relativeTimeClock

    let item: ClipboardItemDTO
    let isKeyboardSelected: Bool
    let settings: SettingsDTO
    let searchMatchContext: SearchMatchContext?

    // 回调闭包 - 不参与 Equatable 比较
    let onSelect: () -> Void
    let onSelectOptimizedForCodex: () -> Void
    let onSendViaAirDrop: () -> Void
    let onOpenContainingFolder: () -> Void
    let onHoverSelect: (UUID) -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void
    let onUpdateNote: (String?) async -> Bool
    let onOptimizeImage: () async -> ImageOptimizationOutcomeDTO
    let getImageData: () async -> Data?
    let markdownWebViewController: MarkdownPreviewWebViewController
    let interactionCoordinator: HistoryListInteractionCoordinator
    let interactionSessionStore: HistoryItemInteractionSessionStore
    let isContentRevisionCurrent: (UUID, ClipboardItemContentRevision) -> Bool
    let isImagePreviewPresented: Bool
    let isTextPreviewPresented: Bool
    let isFilePreviewPresented: Bool
    /// A pinned preview owns the shared Markdown WebView and is the only preview on screen, so
    /// rows stop starting hover previews while one is up.
    let isPreviewPinningActive: Bool
    let requestPopover: (HoverPreviewPopoverKind?) -> Void
    let requestPinPreview: (HoverPreviewPopoverKind, HoverPreviewModel, ClipboardItemContentRevision) -> Void
    let dismissOtherPopovers: () -> Void
    private let contentRevision: ClipboardItemContentRevision

    // Idle rows retain only lightweight SwiftUI value state. The controller/model graph is
    // created as one session after a real interaction and released as a unit when idle.
    @State private var interactionState: HistoryItemInteractionState?
    /// Ownership and liveness bookkeeping, held by reference rather than as `@State`.
    ///
    /// None of it is read while the body is built, but every field is written on paths the scroll
    /// runs constantly: a row appearing, and the pointer crossing a row as the content moves under
    /// it. As `@State` each of those writes invalidated the row and cost another body evaluation,
    /// which measured as roughly an eighth of the busy main thread and most of the worst-case
    /// stall during a 12 s scroll.
    @State private var control = HistoryRowControlState()

    private static let isUITestTapPreviewEnabled: Bool =
        ProcessInfo.processInfo.arguments.contains("--uitesting")
            && ProcessInfo.processInfo.environment["SCOPY_UITEST_OPEN_PREVIEW_ON_TAP"] == "1"

    private static let inactivePopoverToken = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    init(
        item: ClipboardItemDTO,
        isKeyboardSelected: Bool,
        settings: SettingsDTO,
        searchMatchContext: SearchMatchContext?,
        onSelect: @escaping () -> Void,
        onSelectOptimizedForCodex: @escaping () -> Void,
        onSendViaAirDrop: @escaping () -> Void,
        onOpenContainingFolder: @escaping () -> Void,
        onHoverSelect: @escaping (UUID) -> Void,
        onTogglePin: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onUpdateNote: @escaping (String?) async -> Bool,
        onOptimizeImage: @escaping () async -> ImageOptimizationOutcomeDTO,
        getImageData: @escaping () async -> Data?,
        markdownWebViewController: MarkdownPreviewWebViewController,
        interactionCoordinator: HistoryListInteractionCoordinator,
        interactionSessionStore: HistoryItemInteractionSessionStore,
        isContentRevisionCurrent: @escaping (UUID, ClipboardItemContentRevision) -> Bool,
        isImagePreviewPresented: Bool,
        isTextPreviewPresented: Bool,
        isFilePreviewPresented: Bool,
        isPreviewPinningActive: Bool,
        requestPopover: @escaping (HoverPreviewPopoverKind?) -> Void,
        requestPinPreview: @escaping (HoverPreviewPopoverKind, HoverPreviewModel, ClipboardItemContentRevision) -> Void,
        dismissOtherPopovers: @escaping () -> Void
    ) {
        self.item = item
        self.isKeyboardSelected = isKeyboardSelected
        self.settings = settings
        self.searchMatchContext = searchMatchContext
        self.onSelect = onSelect
        self.onSelectOptimizedForCodex = onSelectOptimizedForCodex
        self.onSendViaAirDrop = onSendViaAirDrop
        self.onOpenContainingFolder = onOpenContainingFolder
        self.onHoverSelect = onHoverSelect
        self.onTogglePin = onTogglePin
        self.onDelete = onDelete
        self.onUpdateNote = onUpdateNote
        self.onOptimizeImage = onOptimizeImage
        self.getImageData = getImageData
        self.markdownWebViewController = markdownWebViewController
        self.interactionCoordinator = interactionCoordinator
        self.interactionSessionStore = interactionSessionStore
        self.isContentRevisionCurrent = isContentRevisionCurrent
        self.isImagePreviewPresented = isImagePreviewPresented
        self.isTextPreviewPresented = isTextPreviewPresented
        self.isFilePreviewPresented = isFilePreviewPresented
        self.isPreviewPinningActive = isPreviewPinningActive
        self.requestPopover = requestPopover
        self.requestPinPreview = requestPinPreview
        self.dismissOtherPopovers = dismissOtherPopovers
        self.contentRevision = ClipboardItemContentRevision.resolve(item: item)
        ScrollPerformanceProfile.incrementCounter(name: "row.init")
    }

    // MARK: - Equatable

    nonisolated static func == (lhs: HistoryItemView, rhs: HistoryItemView) -> Bool {
        let profileStart = ScrollPerformanceProfile.isEnabled ? CFAbsoluteTimeGetCurrent() : nil
        defer {
            if let profileStart {
                ScrollPerformanceProfile.recordTiming(
                    name: "swiftui.row_equatable_ms",
                    elapsedMs: (CFAbsoluteTimeGetCurrent() - profileStart) * 1000
                )
            }
        }

        return lhs.contentRevision == rhs.contentRevision &&
            lhs.item.lastUsedAt == rhs.item.lastUsedAt &&
            lhs.item.isPinned == rhs.item.isPinned &&
            lhs.item.note == rhs.item.note &&
            lhs.item.appBundleID == rhs.item.appBundleID &&
            lhs.item.thumbnailPath == rhs.item.thumbnailPath &&
            lhs.searchMatchContext == rhs.searchMatchContext &&
            lhs.isKeyboardSelected == rhs.isKeyboardSelected &&
            lhs.isImagePreviewPresented == rhs.isImagePreviewPresented &&
            lhs.isTextPreviewPresented == rhs.isTextPreviewPresented &&
            lhs.isFilePreviewPresented == rhs.isFilePreviewPresented &&
            lhs.isPreviewPinningActive == rhs.isPreviewPinningActive &&
            lhs.settings.showImageThumbnails == rhs.settings.showImageThumbnails &&
            lhs.settings.thumbnailHeight == rhs.settings.thumbnailHeight &&
            lhs.settings.imagePreviewDelay == rhs.settings.imagePreviewDelay &&
            lhs.settings.markdownChatGPTLayoutScalePercent == rhs.settings.markdownChatGPTLayoutScalePercent &&
            lhs.settings.pngquantBinaryPath == rhs.settings.pngquantBinaryPath &&
            lhs.settings.pngquantMarkdownExportEnabled == rhs.settings.pngquantMarkdownExportEnabled &&
            lhs.settings.pngquantMarkdownExportQualityMin == rhs.settings.pngquantMarkdownExportQualityMin &&
            lhs.settings.pngquantMarkdownExportQualityMax == rhs.settings.pngquantMarkdownExportQualityMax &&
            lhs.settings.pngquantMarkdownExportSpeed == rhs.settings.pngquantMarkdownExportSpeed &&
            lhs.settings.pngquantMarkdownExportColors == rhs.settings.pngquantMarkdownExportColors
    }

    nonisolated static func shouldShowOptimizeButton(
        itemType: ClipboardItemType,
        isHovering: Bool,
        isKeyboardSelected: Bool,
        isInteractionSuppressed: Bool
    ) -> Bool {
        itemType == .image &&
            !isInteractionSuppressed &&
            (isHovering || isKeyboardSelected)
    }

    private var isPreviewInteractionSuppressed: Bool {
        interactionCoordinator.isHoverPreviewSuppressed
    }

    private var isAnyPreviewPresented: Bool {
        isImagePreviewPresented || isTextPreviewPresented || isFilePreviewPresented
    }

    private var isHovering: Bool {
        get { interactionState?.previewCoordinator.isHovering ?? false }
        nonmutating set { interactionState?.previewCoordinator.isHovering = newValue }
    }

    private var hoverDebounceTask: Task<Void, Never>? {
        get { interactionState?.previewCoordinator.hoverDebounceTask }
        nonmutating set { interactionState?.previewCoordinator.hoverDebounceTask = newValue }
    }

    private var hoverPreviewTask: Task<Void, Never>? {
        get { interactionState?.previewCoordinator.hoverPreviewTask }
        nonmutating set { interactionState?.previewCoordinator.hoverPreviewTask = newValue }
    }

    private var hoverMarkdownTask: Task<Void, Never>? {
        get { interactionState?.previewCoordinator.hoverMarkdownTask }
        nonmutating set { interactionState?.previewCoordinator.hoverMarkdownTask = newValue }
    }

    private var hoverExitTask: Task<Void, Never>? {
        get { interactionState?.previewCoordinator.hoverExitTask }
        nonmutating set { interactionState?.previewCoordinator.hoverExitTask = newValue }
    }

    private var isPopoverHovering: Bool {
        get { interactionState?.previewCoordinator.isPopoverHovering ?? false }
        nonmutating set { interactionState?.previewCoordinator.isPopoverHovering = newValue }
    }

    private var imagePopoverToken: UUID {
        interactionState?.previewCoordinator.imagePopoverToken ?? Self.inactivePopoverToken
    }

    private var textPopoverToken: UUID {
        interactionState?.previewCoordinator.textPopoverToken ?? Self.inactivePopoverToken
    }

    private var filePopoverToken: UUID {
        interactionState?.previewCoordinator.filePopoverToken ?? Self.inactivePopoverToken
    }

    private var markdownFilePreviewCacheKey: String? {
        get { interactionState?.previewCoordinator.markdownFilePreviewCacheKey }
        nonmutating set { interactionState?.previewCoordinator.markdownFilePreviewCacheKey = newValue }
    }

    private var relativeTimeText: String {
        get { interactionState?.rowController.relativeTimeText ?? relativeTime }
        nonmutating set { interactionState?.rowController.relativeTimeText = newValue }
    }

    private var isOptimizingImage: Bool {
        get { interactionState?.rowController.isOptimizingImage ?? false }
        nonmutating set { interactionState?.rowController.isOptimizingImage = newValue }
    }

    private var optimizeMessage: String? {
        get { interactionState?.rowController.optimizeMessage }
        nonmutating set { interactionState?.rowController.optimizeMessage = newValue }
    }

    private var isHoveringOptimizeButton: Bool {
        get { interactionState?.rowController.isHoveringOptimizeButton ?? false }
        nonmutating set { interactionState?.rowController.isHoveringOptimizeButton = newValue }
    }

    private var isNoteEditorPresented: Bool {
        get { interactionState?.rowController.isNoteEditorPresented ?? false }
        nonmutating set { interactionState?.rowController.isNoteEditorPresented = newValue }
    }

    private var isSavingNote: Bool {
        interactionState?.rowController.isSavingNote ?? false
    }

    private var isScrollInteractionActive: Bool {
        get { interactionState?.rowController.isScrollInteractionActive ?? false }
        nonmutating set { interactionState?.rowController.isScrollInteractionActive = newValue }
    }

    private var optimizeImageTask: Task<Void, Never>? {
        get { interactionState?.rowController.optimizeImageTask }
        nonmutating set { interactionState?.rowController.optimizeImageTask = newValue }
    }

    private var exportActionTask: Task<Void, Never>? {
        get { interactionState?.rowController.exportActionTask }
        nonmutating set { interactionState?.rowController.exportActionTask = newValue }
    }

    private var exportMessageTask: Task<Void, Never>? {
        get { interactionState?.rowController.exportMessageTask }
        nonmutating set { interactionState?.rowController.exportMessageTask = newValue }
    }

    private var exportMessage: String? {
        get { interactionState?.rowController.exportMessage }
        nonmutating set { interactionState?.rowController.exportMessage = newValue }
    }

    private var isExportingPNG: Bool {
        get { interactionState?.rowController.isExportingPNG ?? false }
        nonmutating set { interactionState?.rowController.isExportingPNG = newValue }
    }

    private var isNoteEditorPresentedBinding: Binding<Bool> {
        Binding(
            get: { isNoteEditorPresented },
            set: { presented in
                if presented {
                    isNoteEditorPresented = true
                } else {
                    // A popover host can write `false` while its List row is being recycled.
                    // Scrolling and an authorized save are session-owned transitions, not Cancel.
                    if interactionCoordinator.isScrolling || isSavingNote {
                        return
                    }
                    scheduleNoteEditorDismissIfStillAttached()
                }
            }
        )
    }

    private var statusMessage: String? {
        if isExportingPNG { return "Exporting…" }
        if let exportMessage, !exportMessage.isEmpty { return exportMessage }
        return optimizeMessage
    }

    private var optimizeMessageTask: Task<Void, Never>? {
        get { interactionState?.rowController.optimizeMessageTask }
        nonmutating set { interactionState?.rowController.optimizeMessageTask = newValue }
    }

    private enum InteractionActivation {
        case hover
        case explicitAction
        case presentedPopover
        case legacyAppearance

        var needsScrollBoundaryOwnership: Bool {
            switch self {
            case .hover, .presentedPopover:
                return true
            case .explicitAction, .legacyAppearance:
                return false
            }
        }
    }

    private var usesPassiveRowArchitecture: Bool {
        PerfFeatureFlags.passiveHistoryRowEnabled
    }

    @discardableResult
    private func ensureInteractionState(
        for activation: InteractionActivation,
        preferredToken: HistoryListInteractionCoordinator.PassiveRowToken? = nil
    ) -> HistoryItemInteractionState? {
        if activation.needsScrollBoundaryOwnership, usesPassiveRowArchitecture {
            let token = preferredToken ?? control.passiveRowToken ?? interactionCoordinator.makePassiveRowToken()
            control.passiveRowToken = token
            guard claimPassiveRow(token: token) else { return nil }
        }

        if let current = interactionState {
            guard current.itemID == item.id, !current.isTornDown else {
                interactionSessionStore.release(current)
                current.tearDown()
                interactionState = nil
                return ensureInteractionState(for: activation, preferredToken: preferredToken)
            }
            if let attachmentToken = control.sessionAttachmentToken {
                guard interactionSessionStore.authorizesViewAttachment(
                    current,
                    attachmentToken: attachmentToken
                ) else { return nil }
                current.activateViewAttachment(attachmentToken)
            }
            current.reconcile(to: contentRevision, relativeTimeText: relativeTime)
            registerLegacyInteractionObserverIfNeeded(on: current)
            return current
        }

        let created = HistoryItemInteractionState(
            revision: contentRevision,
            relativeTimeText: relativeTime
        )
        if let attachmentToken = control.sessionAttachmentToken {
            created.activateViewAttachment(attachmentToken)
        }
        interactionState = created
        ScrollPerformanceProfile.incrementCounter(name: "interaction.session_init")
        registerLegacyInteractionObserverIfNeeded(on: created)
        return created
    }

    private func registerLegacyInteractionObserverIfNeeded(on state: HistoryItemInteractionState) {
        guard !usesPassiveRowArchitecture, state.rowController.interactionObservation == nil else {
            return
        }
        state.rowController.interactionObservation = interactionCoordinator.observe { event in
            guard self.control.isAppeared else { return }
            self.handleInteractionEvent(event)
        }
        ScrollPerformanceProfile.incrementCounter(name: "interaction.observer_install")
    }

    @discardableResult
    private func claimPassiveRow(
        token: HistoryListInteractionCoordinator.PassiveRowToken
    ) -> Bool {
        let expectedItemID = item.id
        let expectedRevision = contentRevision
        return interactionCoordinator.claimActiveRow(
            token: token,
            onEvent: { event in
                guard self.control.isAppeared,
                      self.item.id == expectedItemID,
                      self.control.passiveRowToken == token else { return }
                self.reconcileInteractionStateIfNeeded(restartHover: false)
                self.handleInteractionEvent(event)
            },
            restore: {
                guard self.control.isAppeared,
                      self.item.id == expectedItemID,
                      self.contentRevision == expectedRevision,
                      self.control.passiveRowToken == token,
                      self.control.isPointerInsideRow else {
                    self.interactionCoordinator.releasePassiveRow(token: token)
                    return
                }
                self.restoreSuppressedHover(token: token)
            }
        )
    }

    private func restoreSuppressedHover(
        token: HistoryListInteractionCoordinator.PassiveRowToken
    ) {
        guard control.isAppeared, control.isPointerInsideRow, control.passiveRowToken == token else { return }
        guard let state = ensureInteractionState(for: .hover, preferredToken: token) else { return }
        state.previewCoordinator.isHovering = true
        activateHoverActionsIfAllowed(state: state)
        ScrollPerformanceProfile.incrementCounter(name: "interaction.suppressed_hover_restore")
    }

    private func releasePassiveOwnership() {
        guard let token = control.passiveRowToken else { return }
        interactionCoordinator.releasePassiveRow(token: token)
        control.passiveRowToken = nil
    }

    private func reconcileInteractionStateIfNeeded(restartHover: Bool = true) {
        guard let state = interactionState,
              control.isAppeared,
              interactionSessionStore.authorizesViewAttachment(
                  state,
                  attachmentToken: control.sessionAttachmentToken
              ),
              state.ownsViewAttachment(control.sessionAttachmentToken) else { return }
        let changed = state.reconcile(to: contentRevision, relativeTimeText: relativeTime)
        guard changed else { return }

        requestPopover(nil)
        if usesPassiveRowArchitecture {
            releasePassiveOwnership()
            guard restartHover, control.isAppeared, control.isPointerInsideRow else {
                releaseInteractionStateIfIdle(expected: state)
                return
            }
            handleHover(true)
        } else if restartHover, control.isPointerInsideRow {
            state.previewCoordinator.isHovering = true
            activateHoverActionsIfAllowed(state: state)
        }
    }

    private func releaseInteractionStateIfIdle(
        expected state: HistoryItemInteractionState? = nil
    ) {
        guard usesPassiveRowArchitecture else { return }
        let retainedExpected = state.flatMap {
            interactionSessionStore.contains($0) ? $0 : nil
        }
        guard let current = retainedExpected ?? interactionState else { return }
        if let state, current !== state { return }
        if !current.hasExplicitUserOwnedWork {
            interactionSessionStore.release(current)
        }
        if !control.isAppeared, !current.hasOwnedWork {
            current.tearDown()
            interactionSessionStore.release(current)
            if interactionState === current {
                interactionState = nil
            }
            ScrollPerformanceProfile.incrementCounter(name: "interaction.session_release")
            return
        }
        let ownsRestorationCandidate = control.passiveRowToken.map {
            interactionCoordinator.ownsSuppressedHoverCandidate(token: $0)
        } ?? false
        guard (!control.isPointerInsideRow || ownsRestorationCandidate),
              !isAnyPreviewPresented,
              interactionCoordinator.hoverPreviewTransferOwnerID != item.id,
              !current.hasOwnedWork else { return }

        current.tearDown()
        interactionSessionStore.release(current)
        if interactionState === current {
            interactionState = nil
        }
        if !ownsRestorationCandidate {
            releasePassiveOwnership()
        }
        ScrollPerformanceProfile.incrementCounter(name: "interaction.session_release")
    }

    private func tearDownInteractionStateOnDisappear() {
        releasePassiveOwnership()
        guard let state = interactionState else {
            ScrollPerformanceProfile.incrementCounter(name: "interaction.idle_disappear_fast_path")
            return
        }
        let attachmentToken = control.sessionAttachmentToken
        let detachResult = interactionSessionStore.detach(
            state,
            attachmentToken: attachmentToken
        )
        control.sessionAttachmentToken = nil
        if detachResult == .staleAttachment {
            // A newer virtualized row instance already owns this same explicit session.
            return
        }

        _ = state.deactivateViewAttachment(attachmentToken)
        state.suspendForRowDisappearance()
        if detachResult == .retained, state.hasExplicitUserOwnedWork {
            return
        }

        state.tearDown()
        interactionSessionStore.release(state)
        interactionState = nil
        ScrollPerformanceProfile.incrementCounter(name: "interaction.session_release")
    }

    private func attachRetainedInteractionStateIfNeeded() {
        let token = interactionSessionStore.makeAttachmentToken()
        control.sessionAttachmentToken = token
        guard let retained = interactionSessionStore.attach(
            itemID: item.id,
            attachmentToken: token
        ) else { return }

        if let current = interactionState, current !== retained {
            current.tearDown()
        }
        interactionState = retained
        retained.reconcile(to: contentRevision, relativeTimeText: relativeTime)
    }

    private func handlePopoverDismissRequest(
        _ presented: Bool,
        kind: HoverPreviewPopoverKind,
        token: UUID
    ) {
        if presented {
            guard control.isAppeared,
                  let state = ensureInteractionState(for: .presentedPopover),
                  isViewInteractionCurrent(state, revision: state.revision) else { return }
            requestPopover(kind)
            return
        }
        guard let state = interactionState,
              isViewInteractionCurrent(state, revision: state.revision) else { return }
        let coordinator = state.previewCoordinator
        guard coordinator.isCurrentPopoverToken(token, for: kind) else { return }
        requestPopover(nil)
        releaseInteractionStateIfIdle()
    }

    private func handlePopoverHover(_ hovering: Bool) {
        guard let state = interactionState,
              isViewInteractionCurrent(state, revision: state.revision) else { return }
        state.previewCoordinator.handlePopoverHover(
            hovering,
            isRowHovering: isHovering,
            cancelHoverExit: cancelHoverExitTask,
            scheduleHoverExit: schedulePopoverHoverExitCleanup
        )
        if !hovering {
            releaseInteractionStateIfIdle(expected: state)
        }
    }

    private func handlePopoverFrameChange(
        _ frame: CGRect?,
        kind: HoverPreviewPopoverKind,
        token: UUID
    ) {
        guard let state = interactionState,
              isViewInteractionCurrent(state, revision: state.revision) else { return }
        state.previewCoordinator.updatePopoverScreenFrame(frame, for: kind, token: token)
    }

    private func handlePopoverSystemDismiss(kind: HoverPreviewPopoverKind, token: UUID) {
        guard let state = interactionState,
              isViewInteractionCurrent(state, revision: state.revision) else { return }
        state.previewCoordinator.handleSystemDismiss(
            for: kind,
            token: token,
            isRowHovering: { self.isHovering },
            resetPreviewState: {
                self.resetPreviewState(hidePopovers: true)
                self.releaseInteractionStateIfIdle(expected: state)
            }
        )
    }

    // MARK: - Computed Properties

    private var backgroundColor: Color {
        if isKeyboardSelected {
            return ScopyColors.selection
        } else if isHovering {
            return ScopyColors.hover
        } else {
            return Color.clear
        }
    }

    /// v0.12: 优先使用预加载缓存，避免主线程阻塞
    private var appIcon: NSImage? {
        guard let bundleID = descriptor.appIconBundleID else { return nil }
        return IconService.shared.icon(bundleID: bundleID)
    }

    /// Resolved from the presentation cache on demand rather than in `init`: SwiftUI initializes
    /// every ForEach child whenever the list changes (a page load initializes hundreds of rows),
    /// while only the visible rows ever render.
    private var descriptor: HistoryItemRowDescriptor {
        HistoryItemPresentationCache.shared.rowDescriptor(for: item, settings: settings)
    }

    private var thumbnailHeight: CGFloat {
        descriptor.thumbnailHeight
    }

    private var previewDelay: TimeInterval {
        settings.imagePreviewDelay
    }

    private var showThumbnails: Bool {
        descriptor.showThumbnails
    }

    private func isViewInteractionCurrent(
        _ state: HistoryItemInteractionState,
        revision: ClipboardItemContentRevision,
        attachmentToken: HistoryItemInteractionSessionStore.AttachmentToken? = nil
    ) -> Bool {
        let expectedAttachmentToken = attachmentToken ?? control.sessionAttachmentToken
        return control.isAppeared && interactionState === state &&
            interactionSessionStore.authorizesViewAttachment(
                state,
                attachmentToken: expectedAttachmentToken
            ) &&
            state.ownsViewAttachment(expectedAttachmentToken) &&
            state.revision == revision && contentRevision == revision
    }

    /// Explicit export is retained by the list-owned session store and may finish after its row is
    /// virtualized. It deliberately does not depend on a live row attachment.
    private func isExplicitExportCurrent(
        _ state: HistoryItemInteractionState,
        revision: ClipboardItemContentRevision
    ) -> Bool {
        interactionSessionStore.contains(state) && !state.isTornDown &&
            state.revision == revision &&
            isContentRevisionCurrent(item.id, revision)
    }

    private func isHoverPreviewRequestCurrent(
        state: HistoryItemInteractionState,
        revision: ClipboardItemContentRevision,
        attachmentToken: HistoryItemInteractionSessionStore.AttachmentToken,
        allowPresentedPopover: Bool = false
    ) -> Bool {
        guard isViewInteractionCurrent(
            state,
            revision: revision,
            attachmentToken: attachmentToken
        ) else { return false }
        return HoverPreviewLivenessPolicy.isRequestCurrent(
            isTaskCancelled: Task.isCancelled,
            isPreviewInteractionSuppressed: isPreviewInteractionSuppressed,
            isRowHovering: isHovering,
            isPopoverHovering: isPopoverHovering,
            isTextPreviewPresented: isTextPreviewPresented,
            isFilePreviewPresented: isFilePreviewPresented,
            allowPresentedPopover: allowPresentedPopover
        )
    }

    private func isMarkdownRenderCurrent(
        state: HistoryItemInteractionState,
        revision: ClipboardItemContentRevision,
        attachmentToken: HistoryItemInteractionSessionStore.AttachmentToken,
        source: String
    ) -> Bool {
        guard isViewInteractionCurrent(
            state,
            revision: revision,
            attachmentToken: attachmentToken
        ) else { return false }
        return HoverPreviewLivenessPolicy.isMarkdownRenderCurrent(
            isTaskCancelled: Task.isCancelled,
            isPreviewInteractionSuppressed: isPreviewInteractionSuppressed,
            isRowHovering: isHovering,
            isPopoverHovering: isPopoverHovering,
            isTextPreviewPresented: isTextPreviewPresented,
            isFilePreviewPresented: isFilePreviewPresented,
            sourceMatchesPreviewText: state.previewModel.text == source
        )
    }

    private var filePreviewInfo: FilePreviewInfo? {
        descriptor.filePreviewInfo
    }

    private var filePreviewPath: String? {
        descriptor.filePreviewPath
    }

    private var filePreviewKind: FilePreviewKind? {
        descriptor.filePreviewKind
    }

    private var canSendViaAirDrop: Bool {
        switch item.type {
        case .file:
            return !FilePreviewSupport.fileURLs(from: item.plainText).isEmpty
        case .image:
            return true
        case .text, .rtf, .html, .other:
            return false
        }
    }

    private var canOpenContainingFolder: Bool {
        switch item.type {
        case .file:
            return !FilePreviewSupport.fileURLs(from: item.plainText).isEmpty
        case .image:
            guard realImageFileURL != nil else { return false }
            return true
        case .text, .rtf, .html, .other:
            return false
        }
    }

    private var realImageFileURL: URL? {
        if let storageRef = item.storageRef, !storageRef.isEmpty {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: storageRef, isDirectory: &isDirectory),
               !isDirectory.boolValue {
                return URL(fileURLWithPath: storageRef)
            }
        }

        return FilePreviewSupport.fileURLs(from: item.plainText, policy: .regularFilesOnly).first
    }

    private var filePreviewIsMarkdown: Bool {
        descriptor.filePreviewIsMarkdown
    }

    private var canOfferPNGExport: Bool {
        HistoryItemMarkdownExportController.canOfferPNGMenuItem(
            item: item,
            contentRevision: contentRevision,
            filePreviewInfo: filePreviewInfo
        )
    }

    private var canShowFileThumbnail: Bool {
        descriptor.canShowFileThumbnail
    }

    /// v0.21: 使用预计算的 metadata，避免视图渲染时 O(n) 字符串操作
    private var metadataText: String {
        descriptor.metadataText
    }

    private var titleText: String {
        descriptor.titleText
    }

    /// Derived here rather than in `init`: SwiftUI re-initializes every `ForEach` child on every list
    /// update, but a row's body only runs when the row actually changed. Building the evidence text in
    /// `init` made each search keystroke pay one attributed string, one accessibility string and one
    /// descriptor lookup for every loaded row.
    private var searchEvidence: (text: AttributedString, accessibilityText: String)? {
        guard let searchMatchContext else { return nil }
        return (
            SearchMatchPresentation.attributedText(
                context: searchMatchContext,
                itemType: item.type,
                metadataPrefix: descriptor.searchMetadataPrefix
            ),
            SearchMatchPresentation.accessibilityDescription(
                context: searchMatchContext,
                itemType: item.type
            )
        )
    }

    @ViewBuilder
    private var secondaryLine: some View {
        if let searchEvidence {
            Text(searchEvidence.text)
                .accessibilityLabel(searchEvidence.accessibilityText)
                .accessibilityIdentifier("HistoryItem.MatchEvidence")
        } else {
            Text(metadataText)
        }
    }

    /// v0.15: Simplified content view - removed app icon, using new metadata format
    @ViewBuilder
    private var contentView: some View {
        switch item.type {
        case .image where showThumbnails:
            // v0.15.1: 图片有缩略图时，只显示缩略图和大小，不显示 "Image" 标题
            HStack(spacing: ScopySpacing.md) {
                HistoryItemThumbnailView(
                    thumbnailPath: item.thumbnailPath,
                    height: thumbnailHeight,
                    interactionCoordinator: interactionCoordinator
                )
                secondaryLine
                    .font(ScopyTypography.caption)
                    .foregroundStyle(ScopyColors.mutedText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        case .file:
            HStack(spacing: ScopySpacing.sm) {
                if canShowFileThumbnail {
                    HistoryItemFileThumbnailView(
                        thumbnailPath: item.thumbnailPath,
                        height: thumbnailHeight,
                        kind: filePreviewKind ?? .other,
                        interactionCoordinator: interactionCoordinator
                    )
                } else {
                    Image(systemName: ScopyIcons.file)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: thumbnailHeight, height: thumbnailHeight)
                }
                VStack(alignment: .leading, spacing: ScopySpacing.xxs) {
                    Text(titleText)
                        .font(ScopyTypography.body)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    secondaryLine
                        .font(ScopyTypography.caption)
                        .foregroundStyle(ScopyColors.mutedText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        case .image:
            VStack(alignment: .leading, spacing: ScopySpacing.xxs) {
                HStack(spacing: ScopySpacing.sm) {
                    Image(systemName: ScopyIcons.image)
                        .foregroundStyle(.green)
                    Text(titleText)
                        .font(ScopyTypography.body)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                secondaryLine
                    .font(ScopyTypography.caption)
                    .foregroundStyle(ScopyColors.mutedText)
                    .lineLimit(1)
                    .padding(.leading, ScopySpacing.md)  // v0.15.1: 缩进两格
            }
        default:
            VStack(alignment: .leading, spacing: ScopySpacing.xxs) {
                Text(titleText)
                    .font(ScopyTypography.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                secondaryLine
                    .font(ScopyTypography.caption)
                    .foregroundStyle(ScopyColors.mutedText)
                    .lineLimit(1)
                    .padding(.leading, ScopySpacing.md)  // v0.15: 缩进两格
            }
        }
    }

    // MARK: - Body

    var body: some View {
        let profileStart = ScrollPerformanceProfile.isEnabled ? CFAbsoluteTimeGetCurrent() : nil
        defer {
            if let profileStart {
                ScrollPerformanceProfile.recordTiming(
                    name: "swiftui.row_body_ms",
                    elapsedMs: (CFAbsoluteTimeGetCurrent() - profileStart) * 1000
                )
            }
        }
        return scrollAwareRowContent
    }

    @ViewBuilder
    private var scrollAwareRowContent: some View {
        if usesPassiveRowArchitecture {
            // Keep the lightweight hover detector installed through live scrolling so the final
            // stationary row can become the coordinator's single restoration candidate.
            rowContent.onHover(perform: handleHover)
        } else if isScrollInteractionActive {
            rowContent
        } else {
            rowContent.onHover(perform: handleHover)
        }
    }

    /// The row's activation surface is deliberately not a `Button`.
    ///
    /// A SwiftUI button installs a pointer region, and `NSTableView` makes SwiftUI recompute a
    /// re-inserted cell's pointer region, which re-evaluates the whole row body. Every row coming
    /// into view during a scroll paid it: `NSHostingView.updateRemovedState` ->
    /// `PointerRegionUpdater.updatePointerRegion` was 5.7% of main-thread samples and falls to
    /// zero when the row carries no button. Tap target, identifier and the button role for
    /// assistive technology are unchanged.
    private var mainRowButton: some View {
        rowActivationLabel
            .contentShape(Rectangle())
            .onTapGesture(perform: handlePrimaryAction)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("HistoryItem.MainAction")
            .accessibilityHint("Activate this history item")
            .accessibilityAction(.default, handlePrimaryAction)
    }

    private var rowActivationLabel: some View {
        HStack(alignment: .center, spacing: ScopySpacing.sm) {
            // Pin 标记：左侧颜色条
            if item.isPinned {
                Capsule()
                    .fill(ScopyColors.selectionBorder)
                    .frame(width: ScopySize.Width.pinIndicator, height: ScopySize.Height.pinIndicator)
            }

            // App 图标 (v0.15: 保留图标，只移除元数据中的应用名称)
            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: ScopySize.Icon.listApp, height: ScopySize.Icon.listApp)
                    .cornerRadius(ScopySize.Corner.sm)
            } else {
                Image(systemName: ScopyIcons.app)
                    .font(.system(size: ScopySize.Icon.sm))
                    .foregroundStyle(ScopyColors.mutedText)
                    .frame(width: ScopySize.Icon.listApp, height: ScopySize.Icon.listApp)
            }

            contentView

            Spacer(minLength: ScopySpacing.md)

            if item.isPinned {
                Image(systemName: ScopyIcons.pin)
                    .font(.system(size: ScopySize.Icon.pin))
                    .foregroundStyle(.orange)
            }

            if let statusMessage, !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(ScopyTypography.microMono)
                    .foregroundStyle(ScopyColors.mutedText)
            }

            Text(relativeTime)
                .font(ScopyTypography.microMono)
                .foregroundStyle(ScopyColors.mutedText)
        }
        .contentShape(Rectangle())
    }

    private var rowVisualContent: some View {
        let needsThumbnailHeight = descriptor.needsThumbnailHeight

        return HStack(alignment: .center, spacing: ScopySpacing.sm) {
            mainRowButton

            if Self.shouldShowOptimizeButton(
                itemType: item.type,
                isHovering: isHovering,
                isKeyboardSelected: isKeyboardSelected,
                isInteractionSuppressed: isScrollInteractionActive || isPreviewInteractionSuppressed
            ) {
                Button {
                    startOptimizeImageTask()
                } label: {
                    if isOptimizingImage {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: ScopySize.Icon.pin))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("HistoryItem.OptimizeButton")
                .accessibilityLabel("Optimize image")
                .help("优化图片大小（pngquant）")
                .disabled(isOptimizingImage)
                .onHover { hovering in
                    handleOptimizeButtonHover(hovering)
                }
            }
        }
        .padding(.horizontal, ScopySpacing.md)
        .padding(.vertical, ScopySpacing.sm)
        .frame(minHeight: needsThumbnailHeight ? thumbnailHeight + ScopySpacing.lg : ScopySize.Height.listItem)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isKeyboardSelected || isHovering {
                RoundedRectangle(cornerRadius: ScopySize.Corner.lg, style: .continuous)
                    .fill(backgroundColor)
            }
        }
        // v0.10.3: 键盘选中时添加边框
        .overlay {
            if isKeyboardSelected {
                RoundedRectangle(cornerRadius: ScopySize.Corner.lg, style: .continuous)
                    .stroke(ScopyColors.selectionBorder, lineWidth: ScopySize.Stroke.medium)
            }
        }
        // v0.10.3: 添加选中/悬停态过渡动效
        .animation(isScrollInteractionActive ? nil : .easeInOut(duration: 0.15), value: isHovering)
        .animation(isScrollInteractionActive ? nil : .easeInOut(duration: 0.15), value: isKeyboardSelected)
        .padding(.horizontal, ScopySpacing.md) // Outer padding for floating effect
    }

    private var rowLifecycleContent: some View {
        rowVisualContent
        .onAppear {
            control.isAppeared = true
            if HistoryListUITestRuntime.isEnabled {
                HistoryListUITestProbe.shared.recordRowAppeared(itemID: item.id)
            }
            attachRetainedInteractionStateIfNeeded()
            if !usesPassiveRowArchitecture {
                _ = ensureInteractionState(for: .legacyAppearance)
            }
        }
        .onChange(of: item.lastUsedAt) { _, _ in
            updateRelativeTimeText()
        }
        .onChange(of: contentRevision) { _, _ in
            reconcileInteractionStateIfNeeded()
        }
        .onChange(of: isAnyPreviewPresented) { _, presented in
            if presented {
                _ = ensureInteractionState(for: .presentedPopover)
            } else {
                releaseInteractionStateIfIdle()
            }
        }
    }

    /// Pin control shown on every hover preview.
    ///
    /// Pinning is a mouse action on the preview itself: the search field owns the keyboard while
    /// the panel is open, so a bare Space key would be typed into the query instead.
    @ViewBuilder
    private func pinnablePreview<Content: View>(
        kind: HoverPreviewPopoverKind,
        state: HistoryItemInteractionState,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .overlay(alignment: .topLeading) {
                Button {
                    let model = state.previewModel
                    let revision = state.revision
                    requestPopover(nil)
                    requestPinPreview(kind, model, revision)
                } label: {
                    Image(systemName: "pin")
                        .font(.system(size: ScopySize.Icon.xs))
                        .padding(ScopySpacing.xxs)
                        .background(ScopyColors.cardBackground, in: RoundedRectangle(cornerRadius: ScopySize.Corner.sm))
                }
                .buttonStyle(.plain)
                .foregroundStyle(ScopyColors.mutedText)
                .padding(ScopySpacing.xs)
                .help("Pin this preview in a movable window")
                .accessibilityIdentifier("History.Preview.Pin")
            }
    }

    private var rowPreviewPopoverContent: some View {
        let imageToken = imagePopoverToken
        let textToken = textPopoverToken
        let fileToken = filePopoverToken

        return rowLifecycleContent
        .popover(
            isPresented: Binding(
                get: { isImagePreviewPresented },
                set: { presented in handlePopoverDismissRequest(presented, kind: .image, token: imageToken) }
            ),
            arrowEdge: .trailing
        ) {
            if let state = interactionState {
                pinnablePreview(kind: .image, state: state) {
                    HistoryItemImagePreviewView(model: state.previewModel, thumbnailPath: item.thumbnailPath)
                }
                .background(
                    PopoverWindowObserver(
                        onFrameChange: { frame in
                            handlePopoverFrameChange(frame, kind: .image, token: imageToken)
                        },
                        onClose: {
                            handlePopoverSystemDismiss(kind: .image, token: imageToken)
                        }
                    )
                    .allowsHitTesting(false)
                )
                .onHover(perform: handlePopoverHover)
                .onDisappear {
                    handlePopoverSystemDismiss(kind: .image, token: imageToken)
                }
            }
        }
        .popover(
            isPresented: Binding(
                get: { isTextPreviewPresented },
                set: { presented in handlePopoverDismissRequest(presented, kind: .text, token: textToken) }
            ),
            arrowEdge: .trailing
        ) {
            if let state = interactionState {
                let expectedRevision = state.revision
                let expectedAttachmentToken = control.sessionAttachmentToken
                pinnablePreview(kind: .text, state: state) {
                HistoryItemTextPreviewView(
                    model: state.previewModel,
                    markdownWebViewController: markdownWebViewController,
                    isContentCurrent: {
                        self.isViewInteractionCurrent(
                            state,
                            revision: expectedRevision,
                            attachmentToken: expectedAttachmentToken
                        ) &&
                            self.isContentRevisionCurrent(item.id, expectedRevision)
                    },
                    isExportContentCurrent: {
                        self.isExplicitExportCurrent(state, revision: expectedRevision)
                    },
                    retainExplicitExport: {
                        self.interactionSessionStore.registerExplicitWork(
                            state,
                            attachmentToken: expectedAttachmentToken
                        )
                    },
                    onInteractionLifecycleChange: {
                        self.releaseInteractionStateIfIdle(expected: state)
                    }
                )
                }
                .background(
                    PopoverWindowObserver(
                        onFrameChange: { frame in
                            handlePopoverFrameChange(frame, kind: .text, token: textToken)
                        },
                        onClose: {
                            handlePopoverSystemDismiss(kind: .text, token: textToken)
                        }
                    )
                    .allowsHitTesting(false)
                )
                .onHover(perform: handlePopoverHover)
                .onDisappear {
                    handlePopoverSystemDismiss(kind: .text, token: textToken)
                }
            }
        }
        .popover(
            isPresented: Binding(
                get: { isFilePreviewPresented },
                set: { presented in handlePopoverDismissRequest(presented, kind: .file, token: fileToken) }
            ),
            arrowEdge: .trailing
        ) {
            if let state = interactionState {
                let expectedRevision = state.revision
                let expectedAttachmentToken = control.sessionAttachmentToken
                pinnablePreview(kind: .file, state: state) {
                HistoryItemFilePreviewView(
                    model: state.previewModel,
                    thumbnailPath: item.thumbnailPath,
                    kind: filePreviewKind ?? .other,
                    filePath: filePreviewPath,
                    markdownWebViewController: markdownWebViewController,
                    isContentCurrent: {
                        self.isViewInteractionCurrent(
                            state,
                            revision: expectedRevision,
                            attachmentToken: expectedAttachmentToken
                        ) &&
                            self.isContentRevisionCurrent(item.id, expectedRevision)
                    },
                    isExportContentCurrent: {
                        self.isExplicitExportCurrent(state, revision: expectedRevision)
                    },
                    retainExplicitExport: {
                        self.interactionSessionStore.registerExplicitWork(
                            state,
                            attachmentToken: expectedAttachmentToken
                        )
                    },
                    onInteractionLifecycleChange: {
                        self.releaseInteractionStateIfIdle(expected: state)
                    }
                )
                }
                .background(
                    PopoverWindowObserver(
                        onFrameChange: { frame in
                            handlePopoverFrameChange(frame, kind: .file, token: fileToken)
                        },
                        onClose: {
                            handlePopoverSystemDismiss(kind: .file, token: fileToken)
                        }
                    )
                    .allowsHitTesting(false)
                )
                .onHover(perform: handlePopoverHover)
                .onDisappear {
                    handlePopoverSystemDismiss(kind: .file, token: fileToken)
                }
            }
        }
    }

    private var rowMenuContent: some View {
        rowPreviewPopoverContent
        .contextMenu {
            Button("Copy") {
                onSelect()
            }
            .accessibilityIdentifier("HistoryItem.ContextMenu.Copy")
            if item.type == .image {
                Button("Paste-optimized for Codex") {
                    onSelectOptimizedForCodex()
                }
                .accessibilityIdentifier("HistoryItem.ContextMenu.PasteOptimizedForCodex")
            }
            if canOfferPNGExport {
                Button("Export PNG") {
                    startExportPNGTask()
                }
                .accessibilityIdentifier("HistoryItem.ContextMenu.ExportPNG")
                .disabled(isExportingPNG)
            }
            Button(item.isPinned ? "Unpin" : "Pin") {
                onTogglePin()
            }
            .accessibilityIdentifier(item.isPinned ? "HistoryItem.ContextMenu.Unpin" : "HistoryItem.ContextMenu.Pin")
            if canSendViaAirDrop || canOpenContainingFolder {
                Divider()
                if canSendViaAirDrop {
                    Button("Send via AirDrop") {
                        onSendViaAirDrop()
                    }
                    .accessibilityIdentifier("HistoryItem.ContextMenu.SendViaAirDrop")
                }
                if canOpenContainingFolder {
                    Button("Open Containing Folder") {
                        onOpenContainingFolder()
                    }
                    .accessibilityIdentifier("HistoryItem.ContextMenu.OpenContainingFolder")
                }
                Divider()
            }
            if item.type == .file {
                Button(noteMenuTitle) {
                    presentNoteEditor()
                }
                .accessibilityIdentifier(item.note?.isEmpty == false ? "HistoryItem.ContextMenu.EditNote" : "HistoryItem.ContextMenu.AddNote")
                if item.note?.isEmpty == false {
                    Button("Clear Note") {
                        Task { @MainActor in
                            _ = await onUpdateNote(nil)
                        }
                    }
                    .accessibilityIdentifier("HistoryItem.ContextMenu.ClearNote")
                }
            }
            Divider()
            Button("Delete", role: .destructive) {
                onDelete()
            }
            .accessibilityIdentifier("HistoryItem.ContextMenu.Delete")
        }
        .popover(isPresented: isNoteEditorPresentedBinding, arrowEdge: .leading) {
            if let state = interactionState {
                HistoryItemFileNoteEditorView(
                    controller: state.rowController,
                    onSave: { commitNoteDraft() },
                    onCancel: { dismissNoteEditor() }
                )
            }
        }
    }

    private var rowTeardownContent: some View {
        rowMenuContent
        // v0.17: 增强任务清理 - 确保视图消失时释放所有任务引用
        .onDisappear {
            if let state = interactionState,
               state.ownsViewAttachment(control.sessionAttachmentToken) {
                requestPopover(nil)
            }
            if HistoryListUITestRuntime.isEnabled {
                HistoryListUITestProbe.shared.recordRowDisappeared(itemID: item.id)
            }
            control.isAppeared = false
            control.isPointerInsideRow = false
            tearDownInteractionStateOnDisappear()
        }
        .onChange(of: interactionState?.previewModel.markdownContentSize) { _, _ in
            updateMarkdownPreviewMetricsCacheIfNeeded()
        }
        .onChange(of: interactionState?.previewModel.markdownHasHorizontalOverflow) { _, _ in
            updateMarkdownPreviewMetricsCacheIfNeeded()
        }
    }

    private var rowContent: some View {
        rowTeardownContent
        .background {
            if isImagePreviewPresented || isTextPreviewPresented || isFilePreviewPresented {
                ScrollWheelDismissMonitor(
                    isActive: true,
                    onScrollWheel: dismissPreviewForScrollWheel
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }

    private func handleHover(_ hovering: Bool) {
        control.isPointerInsideRow = hovering

        if !hovering {
            if let token = control.passiveRowToken,
               interactionCoordinator.ownsSuppressedHoverCandidate(token: token) {
                releasePassiveOwnership()
            }
            guard let state = interactionState else { return }
            state.previewCoordinator.isHovering = false
            state.rowController.isHoveringOptimizeButton = false
            state.previewCoordinator.cancelHoverDebounceTask()
            state.previewCoordinator.cancelHoverExitTask()
            scheduleRowHoverExitCleanup(state: state)
            return
        }

        if usesPassiveRowArchitecture, isPreviewInteractionSuppressed {
            if let state = interactionState {
                state.previewCoordinator.isHovering = false
                state.rowController.isHoveringOptimizeButton = false
                state.previewCoordinator.cancelHoverDebounceTask()
                state.previewCoordinator.cancelHoverExitTask()
                resetPreviewState(hidePopovers: true, state: state)
                releaseInteractionStateIfIdle(expected: state)
            }

            let token = control.passiveRowToken ?? interactionCoordinator.makePassiveRowToken()
            control.passiveRowToken = token
            let expectedItemID = item.id
            let expectedRevision = contentRevision
            _ = interactionCoordinator.setSuppressedHoverCandidate(token: token) {
                guard self.control.isAppeared,
                      self.control.isPointerInsideRow,
                      self.item.id == expectedItemID,
                      self.contentRevision == expectedRevision,
                      self.control.passiveRowToken == token else {
                    self.interactionCoordinator.releasePassiveRow(token: token)
                    return
                }
                self.restoreSuppressedHover(token: token)
            }
            if let state = interactionState {
                releaseInteractionStateIfIdle(expected: state)
            }
            return
        }

        guard let state = ensureInteractionState(for: .hover) else { return }
        state.previewCoordinator.isHovering = true
        state.previewCoordinator.cancelHoverDebounceTask()
        state.previewCoordinator.cancelHoverExitTask()
        activateHoverActionsIfAllowed(state: state)
    }

    private func activateHoverActionsIfAllowed(state: HistoryItemInteractionState) {
        guard let attachmentToken = control.sessionAttachmentToken,
              isViewInteractionCurrent(
                  state,
                  revision: contentRevision,
                  attachmentToken: attachmentToken
              ) else { return }
        guard state.previewCoordinator.isHovering else { return }
        guard !isPreviewInteractionSuppressed else { return }
        guard !isPreviewPinningActive else { return }
        guard !interactionCoordinator.isHoverPreviewTransferBlocked(for: item.id) else { return }

        dismissOtherPopovers()

        // 静止 150ms 后才更新全局选中状态
        state.previewCoordinator.cancelHoverDebounceTask()
        let expectedRevision = state.revision
        state.previewCoordinator.hoverDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled,
                  self.isViewInteractionCurrent(
                      state,
                      revision: expectedRevision,
                      attachmentToken: attachmentToken
                  ),
                  state.previewCoordinator.isHovering else { return }
            onHoverSelect(item.id)
        }

        // Returning from the safe corridor must reuse the existing popover. Restarting the
        // pipeline would refresh its token and force SwiftUI to close/reopen the same window.
        guard !isAnyPreviewPresented else { return }
        guard !state.rowController.isHoveringOptimizeButton,
              !state.rowController.isNoteEditorPresented else { return }

        if item.type == .image && showThumbnails {
            startPreviewTask(state: state)
        } else if item.type == .file {
            startFilePreviewTask(state: state)
        } else if item.type == .text || item.type == .rtf || item.type == .html {
            startTextPreviewTask(state: state)
        }
    }

    // MARK: - Preview Task
    // v0.10.3: 使用 Task 替代 Timer，自动取消防止泄漏

    /// v0.12: 完善取消检查，获取数据后也检查取消状态
    /// v0.22: 确保在创建新任务前取消旧任务，防止快速悬停时任务累积导致内存泄漏
    private func startPreviewTask(state: HistoryItemInteractionState) {
        guard let attachmentToken = control.sessionAttachmentToken,
              isViewInteractionCurrent(
                  state,
                  revision: contentRevision,
                  attachmentToken: attachmentToken
              ) else { return }
        let expectedRevision = state.revision
        state.previewCoordinator.presentPreview(.image)
        let request = HistoryHoverPreviewPipeline.imageRequest(item: item, delay: previewDelay)
        state.previewCoordinator.hoverPreviewTask = Task(priority: .userInitiated) { @MainActor in
            await HistoryHoverPreviewPipeline.run(
                request: .image(request),
                getImageData: getImageData,
                isCurrent: {
                    isHoverPreviewRequestCurrent(
                        state: state,
                        revision: expectedRevision,
                        attachmentToken: attachmentToken
                    )
                },
                emit: { event in
                    applyHoverPreviewEvent(
                        event,
                        state: state,
                        revision: expectedRevision,
                        attachmentToken: attachmentToken
                    )
                }
            )
        }
    }

    private func startFilePreviewTask(state: HistoryItemInteractionState) {
        guard let attachmentToken = control.sessionAttachmentToken,
              isViewInteractionCurrent(
                  state,
                  revision: contentRevision,
                  attachmentToken: attachmentToken
              ) else { return }
        let expectedRevision = state.revision
        guard let previewInfo = filePreviewInfo else { return }
        let isMarkdownFile = filePreviewIsMarkdown
        let request = HistoryHoverPreviewPipeline.fileRequest(
            item: item,
            previewInfo: previewInfo,
            isMarkdown: isMarkdownFile,
            delay: previewDelay,
            settings: settings
        )
        let markdownCacheKey = isMarkdownFile
            ? HistoryHoverPreviewPipeline.markdownFileCacheKey(revision: request.revision)
            : nil
        state.previewCoordinator.presentPreview(.file, markdownCacheKey: markdownCacheKey)
        state.previewCoordinator.hoverPreviewTask = Task(priority: .userInitiated) { @MainActor in
            await HistoryHoverPreviewPipeline.run(
                request: .file(request),
                isCurrent: {
                    isHoverPreviewRequestCurrent(
                        state: state,
                        revision: expectedRevision,
                        attachmentToken: attachmentToken,
                        allowPresentedPopover: isMarkdownFile
                    )
                },
                emit: { event in
                    applyHoverPreviewEvent(
                        event,
                        state: state,
                        revision: expectedRevision,
                        attachmentToken: attachmentToken
                    )
                }
            )
        }
    }

    private func cancelPreviewTask() {
        interactionState?.previewCoordinator.cancelPreviewTasks()
    }

    private func cancelHoverDebounceTask() {
        interactionState?.previewCoordinator.cancelHoverDebounceTask()
    }

    private func cancelHoverExitTask() {
        interactionState?.previewCoordinator.cancelHoverExitTask()
    }

    private func cancelOptimizeMessageTask() {
        interactionState?.rowController.cancelOptimizeMessageTask()
    }

    private func cancelExportMessageTask() {
        interactionState?.rowController.cancelExportMessageTask()
    }

    private func cancelOptimizeImageTask() {
        interactionState?.rowController.cancelOptimizeImageTask()
    }

    private func cancelExportActionTask() {
        interactionState?.rowController.cancelExportActionTask()
    }

    private func cancelExportTasks() {
        cancelExportActionTask()
        cancelExportMessageTask()
    }

    private var noteMenuTitle: String {
        item.note?.isEmpty == false ? "Edit Note..." : "Add Note..."
    }

    private func startExportPNGTask() {
        guard let state = ensureInteractionState(for: .explicitAction) else { return }
        cancelExportTasks()
        guard state.rowController.beginExportingPNG(),
              let exportToken = state.rowController.exportAuthorizationToken else { return }
        guard interactionSessionStore.registerExplicitWork(
            state,
            attachmentToken: control.sessionAttachmentToken
        ) else {
            state.rowController.cancelExportActionTask()
            releaseInteractionStateIfIdle(expected: state)
            return
        }

        let expectedRevision = state.revision
        let currentItem = item
        let currentSettings = settings
        let currentFilePreviewInfo = filePreviewInfo
        let pasteboardWriteLease = MarkdownExportService.capturePasteboardWriteLease()

        guard HistoryItemMarkdownExportController.canExportPNG(
            item: currentItem,
            filePreviewInfo: currentFilePreviewInfo
        ) else {
            state.rowController.finishExportingPNG(message: "Export failed", token: exportToken)
            scheduleExportMessageReset(state: state, revision: expectedRevision)
            return
        }

        state.rowController.exportActionTask = Task { @MainActor in
            guard let markdownSource = await HistoryItemMarkdownExportController.loadMarkdownSource(
                item: currentItem,
                filePreviewInfo: currentFilePreviewInfo
            ) else {
                guard self.interactionSessionStore.contains(state),
                      state.revision == expectedRevision,
                      state.rowController.authorizesExport(token: exportToken) else { return }
                state.rowController.finishExportingPNG(
                    message: "Export failed",
                    token: exportToken
                )
                scheduleExportMessageReset(state: state, revision: expectedRevision)
                return
            }

            let result = await HistoryItemMarkdownExportController.exportMarkdownToClipboard(
                markdownSource: markdownSource,
                settings: currentSettings,
                pasteboardWriteLease: pasteboardWriteLease,
                authorizePasteboardWrite: {
                    self.interactionSessionStore.contains(state) &&
                        !state.isTornDown &&
                        state.revision == expectedRevision &&
                        state.rowController.authorizesExport(token: exportToken) &&
                        self.isContentRevisionCurrent(currentItem.id, expectedRevision)
                }
            )
            guard !Task.isCancelled,
                  self.interactionSessionStore.contains(state),
                  state.revision == expectedRevision,
                  state.rowController.authorizesExport(token: exportToken),
                  self.isContentRevisionCurrent(currentItem.id, expectedRevision) else { return }

            switch result {
            case .success:
                state.rowController.finishExportingPNG(message: "PNG copied", token: exportToken)
            case .failure:
                state.rowController.finishExportingPNG(message: "Export failed", token: exportToken)
            }
            scheduleExportMessageReset(state: state, revision: expectedRevision)
        }
    }

    private func scheduleExportMessageReset(
        state: HistoryItemInteractionState,
        revision: ClipboardItemContentRevision
    ) {
        state.rowController.cancelExportMessageTask()
        state.rowController.exportMessageTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled,
                  self.interactionSessionStore.contains(state),
                  !state.isTornDown,
                  state.revision == revision else { return }
            state.rowController.clearExportFeedback()
            self.releaseInteractionStateIfIdle(expected: state)
        }
    }

    private func presentNoteEditor() {
        guard let state = ensureInteractionState(for: .explicitAction) else { return }
        state.rowController.presentNoteEditor(note: item.note)
        guard interactionSessionStore.registerExplicitWork(
            state,
            attachmentToken: control.sessionAttachmentToken
        ) else {
            state.rowController.dismissNoteEditor(discardDraft: true)
            releaseInteractionStateIfIdle(expected: state)
            return
        }
        dismissOtherPopovers()
        resetPreviewState(hidePopovers: true, state: state)
    }

    private func commitNoteDraft() {
        guard let state = interactionState,
              isViewInteractionCurrent(state, revision: state.revision),
              isContentRevisionCurrent(item.id, state.revision) else { return }
        guard let request = state.rowController.beginNoteSave() else { return }
        guard interactionSessionStore.registerExplicitWork(
            state,
            attachmentToken: control.sessionAttachmentToken
        ) else {
            state.rowController.cancelNoteSave()
            return
        }

        let task = Task { @MainActor in
            let succeeded = await onUpdateNote(request.normalizedNote)
            guard !Task.isCancelled,
                  interactionSessionStore.contains(state),
                  !state.isTornDown else { return }

            let completion = state.rowController.finishNoteSave(
                succeeded: succeeded,
                request: request
            )
            if completion == .savedAndDismissed {
                releaseInteractionStateIfIdle(expected: state)
            }
        }
        _ = state.rowController.installNoteSaveTask(task, token: request.token)
    }

    private func dismissNoteEditor() {
        guard let state = interactionState else { return }
        state.rowController.dismissNoteEditor(discardDraft: true)
        releaseInteractionStateIfIdle(expected: state)
    }

    private func scheduleNoteEditorDismissIfStillAttached() {
        guard let state = interactionState,
              let attachmentToken = control.sessionAttachmentToken else { return }
        DispatchQueue.main.async {
            guard self.control.isAppeared,
                  self.interactionState === state,
                  self.interactionSessionStore.authorizesViewAttachment(
                      state,
                      attachmentToken: attachmentToken
                  ),
                  state.ownsViewAttachment(attachmentToken) else { return }
            self.dismissNoteEditor()
        }
    }

    private func handlePrimaryAction() {
        if Self.isUITestTapPreviewEnabled {
            dismissOtherPopovers()
            control.isPointerInsideRow = true
            guard let state = ensureInteractionState(for: .presentedPopover) else { return }
            state.previewCoordinator.isHovering = true
            // UITest 点按打开 preview 只需要维持 row hover，不应伪造 popover hover，
            // 否则滚动关闭路径会被 `isPopoverHovering` 误拦截。
            state.previewCoordinator.isPopoverHovering = false
            if item.type == .image && showThumbnails {
                startPreviewTask(state: state)
            } else if item.type == .file {
                startFilePreviewTask(state: state)
            } else if item.type == .text || item.type == .rtf || item.type == .html {
                startTextPreviewTask(state: state)
            }
        } else {
            onSelect()
        }
    }

    private func handleInteractionEvent(_ event: HistoryListInteractionCoordinator.Event) {
        guard let state = interactionState else { return }
        switch event {
        case .scrollStarted, .pointerInteractionStarted:
            state.rowController.isScrollInteractionActive = true
            handleScrollDidStart(state: state)
        case .scrollEnded:
            state.rowController.isScrollInteractionActive = false
            handleScrollDidEnd(state: state)
        case .pointerInteractionEnded:
            if !interactionCoordinator.isScrolling {
                state.rowController.isScrollInteractionActive = false
            }
        case .hoverPreviewTransferEnded(let sourceItemID):
            guard sourceItemID != item.id, state.previewCoordinator.isHovering else { return }
            activateHoverActionsIfAllowed(state: state)
        }
    }

    private func handleOptimizeButtonHover(_ hovering: Bool) {
        guard let state = ensureInteractionState(for: .explicitAction) else { return }
        if hovering {
            state.rowController.isHoveringOptimizeButton = true
            resetPreviewState(hidePopovers: true, state: state)
            return
        }

        state.rowController.isHoveringOptimizeButton = false
        guard state.previewCoordinator.isHovering else {
            releaseInteractionStateIfIdle(expected: state)
            return
        }
        guard !isPreviewInteractionSuppressed else { return }

        if item.type == .image && showThumbnails {
            startPreviewTask(state: state)
        } else if item.type == .file {
            startFilePreviewTask(state: state)
        } else if item.type == .text || item.type == .rtf || item.type == .html {
            startTextPreviewTask(state: state)
        }
    }

    private func cancelHoverTasks() {
        interactionState?.previewCoordinator.cancelHoverTasks()
    }

    private func resetPreviewModel(state: HistoryItemInteractionState) {
        state.previewModel.resetPreviewContent()
    }

    private func resetPreviewState(
        hidePopovers: Bool,
        state: HistoryItemInteractionState? = nil
    ) {
        guard let state = state ?? interactionState else { return }
        state.previewCoordinator.dismissPreview(
            hidePopovers: hidePopovers,
            requestPopover: requestPopover,
            resetPreviewModel: { resetPreviewModel(state: state) }
        )
    }

    private func updateMarkdownPreviewMetricsCacheIfNeeded() {
        guard let state = interactionState,
              isViewInteractionCurrent(state, revision: state.revision),
              state.previewModel.isMarkdown,
              let text = state.previewModel.text,
              let size = state.previewModel.markdownContentSize,
              let layoutScalePercent = state.previewModel.markdownMetricsLayoutScalePercent else { return }

        let layoutScale = MarkdownChatGPTLayoutScalePercent(settingsValue: layoutScalePercent)
        let renderKey = HoverPreviewModel.markdownRenderKey(source: text, layoutScale: layoutScale)
        guard state.previewModel.isMarkdownRenderLive(for: renderKey) else { return }

        let contentHash: String
        if item.type == .file {
            guard isFilePreviewPresented else { return }
            guard let cacheKey = markdownFilePreviewCacheKey else { return }
            guard let current = MarkdownPreviewCache.shared.filePreview(forKey: cacheKey),
                  current.text == text else { return }
            contentHash = cacheKey
        } else if item.type == .text || item.type == .rtf || item.type == .html {
            guard isTextPreviewPresented else { return }
            contentHash = contentRevision.cacheKey
        } else {
            return
        }

        let context = MarkdownRenderContextResolver.defaultContext(
            for: text,
            layoutScale: layoutScale
        )
        let renderCacheKey = MarkdownRenderCacheKey.make(contentHash: contentHash, context: context)
        guard !renderCacheKey.isEmpty else { return }
        let metrics = MarkdownContentMetrics(
            size: size,
            hasHorizontalOverflow: state.previewModel.markdownHasHorizontalOverflow,
            renderSucceeded: true
        )
        MarkdownPreviewCache.shared.setMetrics(metrics, forKey: renderCacheKey)
    }

    private func applyHoverPreviewEvent(
        _ event: HistoryHoverPreviewPipeline.Event,
        state: HistoryItemInteractionState,
        revision: ClipboardItemContentRevision,
        attachmentToken: HistoryItemInteractionSessionStore.AttachmentToken
    ) {
        guard isViewInteractionCurrent(
            state,
            revision: revision,
            attachmentToken: attachmentToken
        ) else { return }
        switch event {
        case .present(let kind):
            requestPopover(kind)
        case .image(let cgImage):
            state.previewModel.previewCGImage = cgImage
        case .text(let previewState):
            state.previewModel.primeTextPreview(
                text: previewState.text,
                isMarkdown: previewState.isMarkdown,
                markdownHTML: previewState.markdownHTML,
                markdownContentSize: previewState.markdownContentSize,
                markdownHasHorizontalOverflow: previewState.markdownHasHorizontalOverflow,
                layoutScale: previewState.layoutScale
            )
        case .markdownHTML(let html, let layoutScale):
            state.previewModel.setMarkdownHTMLAwaitingLiveRender(html, layoutScale: layoutScale)
        case .prewarmMarkdownHTML(let html, let renderCacheKey):
            guard !isAnyPreviewPresented else { return }
            markdownWebViewController.prewarm(
                html: html,
                renderCacheKey: renderCacheKey,
                width: HoverPreviewScreenMetrics.maxMarkdownPopoverWidthPoints()
            )
        case .renderMarkdown(let request):
            state.previewCoordinator.hoverMarkdownTask = HistoryHoverPreviewPipeline.makeMarkdownRenderTask(
                request: request,
                isCurrent: {
                    isMarkdownRenderCurrent(
                        state: state,
                        revision: revision,
                        attachmentToken: attachmentToken,
                        source: request.source
                    )
                },
                emit: { nextEvent in
                    applyHoverPreviewEvent(
                        nextEvent,
                        state: state,
                        revision: revision,
                        attachmentToken: attachmentToken
                    )
                }
            )
        }
    }

    private func startOptimizeImageTask() {
        guard item.type == .image else { return }
        guard let state = ensureInteractionState(for: .explicitAction) else { return }
        guard !state.rowController.isOptimizingImage else { return }

        state.rowController.cancelOptimizeImageTask()
        state.rowController.cancelOptimizeMessageTask()
        guard let startRevision = state.beginOptimization() else { return }

        state.rowController.isOptimizingImage = true
        guard interactionSessionStore.registerExplicitWork(
            state,
            attachmentToken: control.sessionAttachmentToken
        ) else {
            state.rowController.isOptimizingImage = false
            state.finishOptimizationWithoutFeedback(startedAt: startRevision)
            releaseInteractionStateIfIdle(expected: state)
            return
        }
        state.rowController.optimizeImageTask = Task { @MainActor in
            defer {
                state.rowController.isOptimizingImage = false
                state.rowController.optimizeImageTask = nil
                state.finishOptimizationWithoutFeedback(startedAt: startRevision)
                self.releaseInteractionStateIfIdle(expected: state)
            }

            let outcome = await onOptimizeImage()
            guard self.interactionSessionStore.contains(state), !state.isTornDown else { return }
            guard state.acceptsOptimizationOutcome(outcome, startedAt: startRevision) else { return }
            state.rowController.optimizeMessage = Self.makeOptimizeMessage(outcome)
            guard state.rowController.optimizeMessage != nil else { return }

            state.rowController.optimizeMessageTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled,
                      self.interactionSessionStore.contains(state),
                      !state.isTornDown else { return }
                state.rowController.optimizeMessage = nil
                state.rowController.optimizeMessageTask = nil
                self.releaseInteractionStateIfIdle(expected: state)
            }
        }
    }

    private static func makeOptimizeMessage(_ outcome: ImageOptimizationOutcomeDTO) -> String? {
        switch outcome.result {
        case .optimized:
            let original = max(0, outcome.originalBytes)
            let optimized = max(0, outcome.optimizedBytes)
            guard original > 0, optimized >= 0 else { return "已优化" }
            guard optimized < original else { return "无变化" }
            let percent = Int((Double(original - optimized) / Double(original) * 100.0).rounded())
            guard percent > 0 else { return "已压缩" }
            return "压缩 -\(percent)%"
        case .noChange:
            return "无变化"
        case .failed(let message):
            let lower = message.lowercased()
            if lower.contains("pngquant") && (lower.contains("not found") || lower.contains("not executable")) {
                return "pngquant 不可用"
            }
            return "压缩失败"
        }
    }

    private var shouldResetPreviewOnScroll: Bool {
        guard let state = interactionState else { return false }
        if state.previewCoordinator.isHovering || state.previewCoordinator.isPopoverHovering ||
            isImagePreviewPresented || isTextPreviewPresented || isFilePreviewPresented {
            return true
        }
        if state.previewCoordinator.hasActiveHoverWork {
            return true
        }
        if state.previewModel.previewCGImage != nil || state.previewModel.text != nil ||
            state.previewModel.markdownHTML != nil {
            return true
        }
        if state.previewModel.isExporting || state.previewModel.exportSuccess ||
            state.previewModel.exportFailed || state.previewModel.exportErrorMessage != nil {
            return true
        }
        return false
    }

    private func scheduleRowHoverExitCleanup(state: HistoryItemInteractionState) {
        guard interactionState === state,
              let attachmentToken = control.sessionAttachmentToken else { return }
        state.previewCoordinator.cancelHoverExitTask()
        guard isAnyPreviewPresented else {
            resetPreviewState(hidePopovers: true, state: state)
            releaseInteractionStateIfIdle(expected: state)
            return
        }
        guard let transferToken = interactionCoordinator.beginHoverPreviewTransferToken(for: item.id) else {
            resetPreviewState(hidePopovers: true, state: state)
            releaseInteractionStateIfIdle(expected: state)
            return
        }

        let expectedRevision = state.revision
        let exitPoint = NSEvent.mouseLocation
        state.previewCoordinator.startRowExitIntent(
            from: exitPoint,
            onDismiss: {
                guard self.isViewInteractionCurrent(
                    state,
                    revision: expectedRevision,
                    attachmentToken: attachmentToken
                ),
                      !state.previewCoordinator.isHovering,
                      !state.previewCoordinator.isPopoverHovering else { return }
                self.resetPreviewState(hidePopovers: true, state: state)
            },
            onFinish: { [weak interactionCoordinator] in
                interactionCoordinator?.endHoverPreviewTransfer(token: transferToken)
                self.releaseInteractionStateIfIdle(expected: state)
            }
        )
    }

    /// Popover-to-row transfer does not need direction inference. Keep the small symmetric grace
    /// for AppKit's transient hover changes while the popover opens, closes, or hands focus back.
    private func schedulePopoverHoverExitCleanup() {
        guard let state = interactionState,
              let attachmentToken = control.sessionAttachmentToken else { return }
        let expectedRevision = state.revision
        state.previewCoordinator.cancelHoverExitTask()
        state.previewCoordinator.hoverExitTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled,
                  self.isViewInteractionCurrent(
                      state,
                      revision: expectedRevision,
                      attachmentToken: attachmentToken
                  ),
                  !state.previewCoordinator.isHovering,
                  !state.previewCoordinator.isPopoverHovering else { return }
            self.resetPreviewState(hidePopovers: true, state: state)
            self.releaseInteractionStateIfIdle(expected: state)
        }
    }

    private func dismissPreviewForScrollWheel() {
        guard let state = interactionState, shouldResetPreviewOnScroll else { return }
        guard !state.previewCoordinator.isPopoverHovering else { return }
        state.previewCoordinator.isHovering = false
        state.previewCoordinator.cancelHoverTasks()
        resetPreviewState(hidePopovers: true, state: state)
        releaseInteractionStateIfIdle(expected: state)
    }

    // MARK: - Text Preview (v0.15)

    /// v0.15.1: Start text preview task - uses `plainText` (full content) and lazily upgrades to Markdown preview when detected.
    /// v0.22: 确保在创建新任务前取消旧任务，防止快速悬停时任务累积导致内存泄漏
    private func startTextPreviewTask(state: HistoryItemInteractionState) {
        guard let attachmentToken = control.sessionAttachmentToken,
              isViewInteractionCurrent(
                  state,
                  revision: contentRevision,
                  attachmentToken: attachmentToken
              ) else { return }
        let expectedRevision = state.revision
        state.previewCoordinator.presentPreview(.text)
        let request = HistoryHoverPreviewPipeline.textRequest(
            item: item,
            delay: previewDelay,
            settings: settings
        )
        state.previewCoordinator.hoverPreviewTask = Task(priority: .userInitiated) { @MainActor in
            await HistoryHoverPreviewPipeline.run(
                request: .text(request),
                isCurrent: {
                    isHoverPreviewRequestCurrent(
                        state: state,
                        revision: expectedRevision,
                        attachmentToken: attachmentToken,
                        allowPresentedPopover: true
                    )
                },
                emit: { event in
                    applyHoverPreviewEvent(
                        event,
                        state: state,
                        revision: expectedRevision,
                        attachmentToken: attachmentToken
                    )
                }
            )
        }
    }

    // MARK: - Relative Time Formatting

    private var relativeTime: String {
        let bucket = relativeTimeClock?.bucket ?? HistoryRelativeTimeClock.bucket(for: Date())
        return HistoryItemPresentationCache.shared.relativeTimeText(for: item, bucket: bucket)
    }

    private func updateRelativeTimeText() {
        let next = relativeTime
        guard next != relativeTimeText else { return }
        relativeTimeText = next
    }

    private func handleScrollDidStart(state: HistoryItemInteractionState) {
        guard shouldResetPreviewOnScroll else { return }
        state.previewCoordinator.isHovering = false
        state.previewCoordinator.cancelHoverTasks()
        resetPreviewState(hidePopovers: true, state: state)
        releaseInteractionStateIfIdle(expected: state)
    }

    private func handleScrollDidEnd(state: HistoryItemInteractionState) {
        updateRelativeTimeText()
        releaseInteractionStateIfIdle(expected: state)
    }

    /// v0.12: 使用全局缓存获取应用名称，避免重复调用 NSWorkspace
    private func appName(for bundleID: String) -> String {
        return IconService.shared.appName(bundleID: bundleID)
    }

    private func formatBytes(_ bytes: Int) -> String {
        Localization.formatBytes(bytes)
    }
}

private struct ScrollWheelDismissMonitor: NSViewRepresentable {
    let isActive: Bool
    let onScrollWheel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScrollWheel: onScrollWheel)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.update(isActive: isActive)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onScrollWheel = onScrollWheel
        context.coordinator.update(isActive: isActive)
    }

    final class Coordinator {
        var onScrollWheel: () -> Void
        private var monitor: Any?

        init(onScrollWheel: @escaping () -> Void) {
            self.onScrollWheel = onScrollWheel
        }

        func update(isActive: Bool) {
            if isActive {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    self?.onScrollWheel()
                    return event
                }
            } else if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}
