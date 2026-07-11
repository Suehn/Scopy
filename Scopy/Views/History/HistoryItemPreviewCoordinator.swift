import Foundation
import Observation

@Observable
@MainActor
final class HistoryItemPreviewCoordinator {
    var isHovering = false
    var isPopoverHovering = false
    private(set) var imagePopoverToken = UUID()
    private(set) var textPopoverToken = UUID()
    private(set) var filePopoverToken = UUID()
    var markdownFilePreviewCacheKey: String?

    @ObservationIgnored var hoverDebounceTask: Task<Void, Never>?
    @ObservationIgnored var hoverPreviewTask: Task<Void, Never>?
    @ObservationIgnored var hoverMarkdownTask: Task<Void, Never>?
    @ObservationIgnored var hoverExitTask: Task<Void, Never>?
    @ObservationIgnored private let hoverIntentController: HoverPreviewIntentController
    @ObservationIgnored private var popoverScreenFrame: CGRect?

    init(hoverIntentController: HoverPreviewIntentController? = nil) {
        self.hoverIntentController = hoverIntentController ?? HoverPreviewIntentController()
    }

    var hasActiveHoverWork: Bool {
        hoverPreviewTask != nil || hoverMarkdownTask != nil || hoverDebounceTask != nil ||
            hoverExitTask != nil || hoverIntentController.isActive
    }

    func presentPreview(_ kind: HoverPreviewPopoverKind, markdownCacheKey: String? = nil) {
        cancelHoverExitTask()
        popoverScreenFrame = nil
        refreshPopoverToken(for: kind)
        if kind == .file {
            markdownFilePreviewCacheKey = markdownCacheKey
        } else {
            markdownFilePreviewCacheKey = nil
        }
        cancelPreviewTasks()
    }

    func dismissPreview(
        hidePopovers: Bool,
        requestPopover: (HoverPreviewPopoverKind?) -> Void,
        resetPreviewModel: () -> Void
    ) {
        cancelHoverExitTask()
        cancelPreviewTasks()
        if hidePopovers {
            requestPopover(nil)
        }
        invalidatePreviewTokens()
        resetPreviewModel()
    }

    func handlePopoverHover(
        _ hovering: Bool,
        isRowHovering: Bool,
        cancelHoverExit: () -> Void,
        scheduleHoverExit: () -> Void
    ) {
        isPopoverHovering = hovering
        if hovering {
            cancelHoverExit()
        } else if !isRowHovering {
            scheduleHoverExit()
        }
    }

    func handleSystemDismiss(
        for kind: HoverPreviewPopoverKind,
        token: UUID,
        isRowHovering: @escaping @MainActor () -> Bool,
        resetPreviewState: @escaping @MainActor () -> Void
    ) {
        guard popoverToken(for: kind) == token else { return }
        cancelHoverExitTask()
        popoverScreenFrame = nil
        isPopoverHovering = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.popoverToken(for: kind) == token else { return }
            if !isRowHovering() {
                resetPreviewState()
            }
        }
    }

    func isCurrentPopoverToken(_ token: UUID, for kind: HoverPreviewPopoverKind) -> Bool {
        popoverToken(for: kind) == token
    }

    func refreshPopoverToken(for kind: HoverPreviewPopoverKind) {
        switch kind {
        case .image:
            imagePopoverToken = UUID()
        case .text:
            textPopoverToken = UUID()
        case .file:
            filePopoverToken = UUID()
        }
    }

    func updatePopoverScreenFrame(
        _ frame: CGRect?,
        for kind: HoverPreviewPopoverKind,
        token: UUID
    ) {
        guard popoverToken(for: kind) == token else { return }
        popoverScreenFrame = frame
    }

    func startRowExitIntent(
        from exitPoint: CGPoint,
        onDismiss: @escaping @MainActor () -> Void,
        onFinish: @escaping @MainActor () -> Void
    ) {
        hoverIntentController.start(
            exitPoint: exitPoint,
            targetFrame: { [weak self] in self?.popoverScreenFrame },
            shouldKeepAlive: { [weak self] in
                guard let self else { return false }
                return self.isHovering || self.isPopoverHovering
            },
            onDismiss: onDismiss,
            onFinish: onFinish
        )
    }

    var isHoverIntentActive: Bool {
        hoverIntentController.isActive
    }

    var currentPopoverScreenFrame: CGRect? {
        popoverScreenFrame
    }

    func cancelPreviewTasks() {
        hoverPreviewTask?.cancel()
        hoverPreviewTask = nil
        hoverMarkdownTask?.cancel()
        hoverMarkdownTask = nil
    }

    func cancelHoverDebounceTask() {
        hoverDebounceTask?.cancel()
        hoverDebounceTask = nil
    }

    func cancelHoverExitTask() {
        hoverExitTask?.cancel()
        hoverExitTask = nil
        hoverIntentController.cancel()
    }

    func cancelHoverTasks() {
        cancelHoverDebounceTask()
        cancelHoverExitTask()
    }

    func invalidatePreviewTokens() {
        cancelHoverExitTask()
        imagePopoverToken = UUID()
        textPopoverToken = UUID()
        filePopoverToken = UUID()
        markdownFilePreviewCacheKey = nil
        popoverScreenFrame = nil
        isPopoverHovering = false
    }

    private func popoverToken(for kind: HoverPreviewPopoverKind) -> UUID {
        switch kind {
        case .image:
            imagePopoverToken
        case .text:
            textPopoverToken
        case .file:
            filePopoverToken
        }
    }
}
