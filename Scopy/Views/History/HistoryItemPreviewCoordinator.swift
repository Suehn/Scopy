import Foundation
import SwiftUI

@MainActor
final class HistoryItemPreviewCoordinator: ObservableObject {
    @Published var isHovering = false
    @Published var isPopoverHovering = false
    @Published private(set) var imagePopoverToken = UUID()
    @Published private(set) var textPopoverToken = UUID()
    @Published private(set) var filePopoverToken = UUID()
    @Published var markdownFilePreviewCacheKey: String?

    var hoverDebounceTask: Task<Void, Never>?
    var hoverPreviewTask: Task<Void, Never>?
    var hoverMarkdownTask: Task<Void, Never>?
    var hoverExitTask: Task<Void, Never>?

    var hasActiveHoverWork: Bool {
        hoverPreviewTask != nil || hoverMarkdownTask != nil || hoverDebounceTask != nil || hoverExitTask != nil
    }

    func presentPreview(_ kind: HoverPreviewPopoverKind, markdownCacheKey: String? = nil) {
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
    }

    func cancelHoverTasks() {
        cancelHoverDebounceTask()
        cancelHoverExitTask()
    }

    func invalidatePreviewTokens() {
        imagePopoverToken = UUID()
        textPopoverToken = UUID()
        filePopoverToken = UUID()
        markdownFilePreviewCacheKey = nil
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
