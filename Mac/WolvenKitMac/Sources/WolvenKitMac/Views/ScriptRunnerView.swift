import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ScriptRunnerView: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var source = "const largeFiles = projectFiles.filter(file => file.size > 10_000_000);\nconsole.log(`Large project files: ${largeFiles.length}`);\nfor (const file of largeFiles) console.log(file.path);"
    @State private var isConfirmingApply = false
    @State private var scriptName = "Untitled Script"
    @State private var scriptURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Project Scripts")
                        .font(.title2.weight(.semibold))
                    Text(viewModel.activeProject?.name ?? "No project open")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open Script…", action: openScript)
                Button("Save Script…", action: saveScript)
            }

            HStack {
                TextField("Script name", text: $scriptName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Text("JavaScript · projectFiles, readText(path), writeText(path, text), print(...)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            TextEditor(text: $source)
                .font(.system(.body, design: .monospaced))
                .textEditorStyle(.plain)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            if let result = viewModel.scriptRunResult {
                resultPanel(result)
            }

            HStack {
                Text("Scripts can read project files and stage text edits for review before they are applied.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Run Script", action: run)
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.activeProject == nil || viewModel.isRunningScript || source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
            }
        }
        .padding(20)
        .frame(minWidth: 900, minHeight: 680)
        .confirmationDialog(
            "Apply Script Edits?",
            isPresented: $isConfirmingApply,
            titleVisibility: .visible
        ) {
            Button("Apply \(viewModel.scriptRunResult?.edits.count ?? 0) File Edits", role: .destructive) {
                Task { await viewModel.applyScriptEdits() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The script changes will be written to the listed project files. Each file is checked for changes made since the script ran.")
        }
    }

    @ViewBuilder
    private func resultPanel(_ result: ScriptRunResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Output")
                    .font(.headline)
                Spacer()
                if !result.edits.isEmpty {
                    Button("Apply \(result.edits.count) Edits…") { isConfirmingApply = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.isRunningScript)
                }
            }
            if result.logs.isEmpty {
                Text("Script completed without output.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(result.logs.enumerated()), id: \.offset) { item in
                            Text(item.element)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 100)
            }
            if !result.edits.isEmpty {
                Divider()
                ForEach(result.edits) { edit in
                    Label(edit.relativePath, systemImage: "pencil.line")
                        .font(.caption)
                        .lineLimit(1)
                }
            }
        }
        .padding(12)
        .background(Color.gray.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func openScript() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "js") ?? .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let hasAccess = url.startAccessingSecurityScopedResource()
        Task {
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                guard data.count <= 16 * 1024 * 1024 else { throw ScriptFileError.fileTooLarge }
                guard let value = String(data: data, encoding: .utf8) else { throw ScriptFileError.invalidEncoding }
                source = value
                scriptName = url.deletingPathExtension().lastPathComponent
                scriptURL = url
                viewModel.clearScriptResult()
            } catch {
                viewModel.errorMessage = error.localizedDescription
            }
        }
    }

    private func run() {
        Task { await viewModel.runScript(source) }
    }

    private func saveScript() {
        let destination: URL
        if let scriptURL {
            destination = scriptURL
        } else {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "js") ?? .plainText]
            panel.nameFieldStringValue = scriptName.isEmpty ? "Untitled Script.js" : "\(scriptName).js"
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        }

        do {
            try Data(source.utf8).write(to: destination, options: .atomic)
            scriptURL = destination
            scriptName = destination.deletingPathExtension().lastPathComponent
            viewModel.clearScriptResult()
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }
}

private enum ScriptFileError: LocalizedError {
    case invalidEncoding
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidEncoding: return "The selected script is not valid UTF-8 text."
        case .fileTooLarge: return "Scripts are limited to 16 MB."
        }
    }
}
