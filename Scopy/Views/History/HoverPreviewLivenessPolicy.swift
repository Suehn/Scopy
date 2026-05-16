import Foundation

enum HoverPreviewLivenessPolicy {
    static func isRequestCurrent(
        isTaskCancelled: Bool,
        isPreviewInteractionSuppressed: Bool,
        isRowHovering: Bool,
        isPopoverHovering: Bool,
        isTextPreviewPresented: Bool,
        isFilePreviewPresented: Bool,
        allowPresentedPopover: Bool
    ) -> Bool {
        guard !isTaskCancelled, !isPreviewInteractionSuppressed else { return false }
        if isRowHovering { return true }
        guard allowPresentedPopover else { return false }
        return isPopoverHovering || isTextPreviewPresented || isFilePreviewPresented
    }

    static func isMarkdownRenderCurrent(
        isTaskCancelled: Bool,
        isPreviewInteractionSuppressed: Bool,
        isRowHovering: Bool,
        isPopoverHovering: Bool,
        isTextPreviewPresented: Bool,
        isFilePreviewPresented: Bool,
        sourceMatchesPreviewText: Bool
    ) -> Bool {
        guard sourceMatchesPreviewText else { return false }
        return isRequestCurrent(
            isTaskCancelled: isTaskCancelled,
            isPreviewInteractionSuppressed: isPreviewInteractionSuppressed,
            isRowHovering: isRowHovering,
            isPopoverHovering: isPopoverHovering,
            isTextPreviewPresented: isTextPreviewPresented,
            isFilePreviewPresented: isFilePreviewPresented,
            allowPresentedPopover: true
        )
    }
}
