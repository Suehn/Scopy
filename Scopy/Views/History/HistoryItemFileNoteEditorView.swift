import SwiftUI
import ScopyUISupport

struct HistoryItemFileNoteEditorView: View {
    @Binding var note: String
    let isSaving: Bool
    let errorMessage: String?
    let onSave: () -> Void
    let onCancel: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: ScopySpacing.sm) {
            Text("Note")
                .font(.system(size: 12, weight: .semibold))
            TextEditor(text: $note)
                .font(.system(size: 12))
                .frame(width: 260, height: 90)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(ScopyColors.secondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: ScopySize.Corner.sm))
                .overlay(
                    RoundedRectangle(cornerRadius: ScopySize.Corner.sm)
                        .stroke(ScopyColors.separator.opacity(0.6), lineWidth: ScopySize.Stroke.thin)
                )
                .focused($isFocused)
                .disabled(isSaving)
                .accessibilityIdentifier("HistoryItem.NoteEditor.Text")
            if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("HistoryItem.NoteEditor.Error")
            }
            HStack(spacing: ScopySpacing.sm) {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityIdentifier("HistoryItem.NoteEditor.Progress")
                }
                Spacer()
                Button("Cancel") { onCancel() }
                    .disabled(isSaving)
                    .accessibilityIdentifier("HistoryItem.NoteEditor.Cancel")
                Button("Save") { onSave() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
                    .accessibilityIdentifier("HistoryItem.NoteEditor.Save")
            }
        }
        .padding(ScopySpacing.md)
        .background(
            RoundedRectangle(cornerRadius: ScopySize.Corner.md)
                .fill(ScopyColors.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ScopySize.Corner.md)
                .stroke(ScopyColors.separator.opacity(0.5), lineWidth: ScopySize.Stroke.thin)
        )
        .accessibilityIdentifier("HistoryItem.NoteEditor")
        .onAppear { isFocused = true }
    }
}
