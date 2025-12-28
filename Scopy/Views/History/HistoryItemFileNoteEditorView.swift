import SwiftUI
import ScopyUISupport

struct HistoryItemFileNoteEditorView: View {
    @Binding var note: String
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
            HStack(spacing: ScopySpacing.sm) {
                Spacer()
                Button("Cancel") { onCancel() }
                Button("Save") { onSave() }
                    .keyboardShortcut(.defaultAction)
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
        .onAppear { isFocused = true }
    }
}
