import Foundation
import SwiftUI

@MainActor
final class HistoryItemRowController: ObservableObject {
    @Published var isHovering = false
    @Published var isPopoverHovering = false
    @Published var imagePopoverToken = UUID()
    @Published var textPopoverToken = UUID()
    @Published var filePopoverToken = UUID()
    @Published var markdownFilePreviewCacheKey: String?
    @Published var relativeTimeText: String
    @Published var isOptimizingImage = false
    @Published var optimizeMessage: String?
    @Published var exportMessage: String?
    @Published var isHoveringOptimizeButton = false
    @Published var isNoteEditorPresented = false
    @Published var noteDraft = ""
    @Published var isExportingPNG = false

    var hoverDebounceTask: Task<Void, Never>?
    var hoverPreviewTask: Task<Void, Never>?
    var hoverMarkdownTask: Task<Void, Never>?
    var hoverExitTask: Task<Void, Never>?
    var optimizeImageTask: Task<Void, Never>?
    var optimizeMessageTask: Task<Void, Never>?
    var exportActionTask: Task<Void, Never>?
    var exportMessageTask: Task<Void, Never>?

    init(relativeTimeText: String) {
        self.relativeTimeText = relativeTimeText
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

    func cancelOptimizeMessageTask() {
        optimizeMessageTask?.cancel()
        optimizeMessageTask = nil
    }

    func cancelExportMessageTask() {
        exportMessageTask?.cancel()
        exportMessageTask = nil
    }

    func cancelOptimizeImageTask() {
        optimizeImageTask?.cancel()
        optimizeImageTask = nil
        isOptimizingImage = false
    }

    func cancelExportActionTask() {
        exportActionTask?.cancel()
        exportActionTask = nil
        isExportingPNG = false
    }
}
