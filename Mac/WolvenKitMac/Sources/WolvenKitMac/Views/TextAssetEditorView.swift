import SwiftUI
import AppKit

struct TextAssetEditorView: View {
    let file: ProjectFile
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var originalData: Data?
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(file.relativePath)
                        .font(.headline)
                        .textSelection(.enabled)
                    Text("UTF-8 · changes are written to this project file")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if isLoading {
                ProgressView("Reading file…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .textEditorStyle(.plain)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Close", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(isLoading || isSaving || originalData == nil)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(minWidth: 760, minHeight: 560)
        .task(id: file.url) { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let snapshot = try await TextAssetService().load(file.url)
            text = snapshot.text
            originalData = snapshot.data
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func save() {
        guard let originalData else { return }
        isSaving = true
        errorMessage = nil
        Task {
            defer { isSaving = false }
            do {
                try await TextAssetService().save(text, to: file.url, expectedOriginal: originalData)
                self.originalData = Data(text.utf8)
                onSaved()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
