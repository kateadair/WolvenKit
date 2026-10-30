import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ArchiveBuilderView: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var sourceURLs: [URL] = []
    @State private var outputName = "mod.archive"
    @State private var resultMessage: String?
    @State private var resultIsError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Build Archive")
                    .font(.title2.weight(.semibold))
                Text("Create an archive from exported, hash-named files.")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Input")
                    .font(.headline)
                Spacer()
                Button("Choose Files or Folders…", action: chooseInputs)
            }

            if sourceURLs.isEmpty {
                ContentUnavailableView("No Inputs Selected", systemImage: "doc.badge.plus", description: Text("Choose one or more files or folders. Files must be named with their numeric resource hash, such as 123456789.bin."))
                    .frame(maxHeight: 190)
            } else {
                List(sourceURLs, id: \.standardizedFileURL) { url in
                    Label(url.lastPathComponent, systemImage: "doc")
                        .lineLimit(1)
                }
                .frame(minHeight: 130, maxHeight: 230)
            }

            TextField("Archive file name", text: $outputName)
                .textFieldStyle(.roundedBorder)

            if let resultMessage {
                Label(resultMessage, systemImage: resultIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(resultIsError ? .red : .green)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("Close", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Build Archive", action: build)
                    .buttonStyle(.borderedProminent)
                    .disabled(sourceURLs.isEmpty || viewModel.isBusy || outputName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func chooseInputs() {
        let panel = NSOpenPanel()
        panel.title = "Choose Archive Inputs"
        panel.message = "Select one or more hash-named files or folders containing hash-named files."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        if panel.runModal() == .OK {
            sourceURLs = panel.urls
            resultMessage = nil
        }
    }

    private func build() {
        let panel = NSSavePanel()
        panel.title = "Save Archive"
        panel.nameFieldStringValue = outputName.hasSuffix(".archive") ? outputName : outputName + ".archive"
        panel.allowedContentTypes = [.data]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let accessedURLs = sourceURLs.filter { $0.startAccessingSecurityScopedResource() }
        Task {
            defer { accessedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
            guard let count = await viewModel.buildArchive(from: sourceURLs, to: destination) else {
                resultIsError = true
                resultMessage = viewModel.errorMessage ?? "The archive could not be created."
                return
            }
            resultIsError = false
            resultMessage = "Created archive with \(count.formatted()) files at \(destination.lastPathComponent)."
        }
    }
}
