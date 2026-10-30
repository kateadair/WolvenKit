import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AssetCatalogView: View {
    @StateObject private var viewModel: AssetCatalogViewModel
    @State private var resourceMetadata: CR2WMetadata?
    @State private var resourceDocument: CR2WDocument?
    @State private var resourceError: String?
    @State private var selectedResourceEdit: CR2WEditSelection?
    @State private var selectedTextFile: ProjectFile?
    @State private var imageConversionMessage: String?
    let files: [ProjectFile]

    init(files: [ProjectFile]) {
        self.files = files
        _viewModel = StateObject(wrappedValue: AssetCatalogViewModel(files: files))
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    TextField("Search project files", text: $viewModel.searchText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Search project files")

                    Picker("Category", selection: $viewModel.category) {
                        ForEach(AssetCategory.allCases) { category in
                            Text(category.rawValue).tag(category)
                        }
                    }
                    .frame(width: 145)

                    Picker("Sort", selection: $viewModel.sortOrder) {
                        ForEach(AssetSortOrder.allCases) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                    .frame(width: 145)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)

                if viewModel.visibleFiles.isEmpty {
                    ContentUnavailableView {
                        Label(viewModel.searchText.isEmpty ? "No Matching Files" : "No Search Results", systemImage: "doc.text.magnifyingglass")
                    } description: {
                        Text(viewModel.searchText.isEmpty ? "Choose another category to see project files." : "Try a different search term or category.")
                    }
                } else {
                    List(viewModel.visibleFiles, selection: $viewModel.selectedFileID) { file in
                        HStack(spacing: 10) {
                            Image(systemName: icon(for: file.url))
                                .frame(width: 20)
                                .foregroundStyle(.secondary)
                            Text(file.relativePath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 10)
                            Text(file.byteCount, format: .byteCount(style: .file))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .tag(file.id as String?)
                        .contentShape(Rectangle())
                    }
                    .listStyle(.inset)
                }
            }
            .frame(minWidth: 360)

            Divider()

            inspector
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 340)
        }
        .onChange(of: files) { _, newFiles in
            viewModel.replaceFiles(newFiles)
        }
        .task(id: viewModel.selectedFile?.url) {
            resourceDocument = nil
            resourceMetadata = nil
            resourceError = nil
            guard let selectedFile = viewModel.selectedFile else {
                return
            }
            resourceMetadata = await CR2WMetadataReader().readMetadata(at: selectedFile.url)
            if resourceMetadata != nil {
                do {
                    resourceDocument = try await CR2WDocumentReader().readDocument(at: selectedFile.url)
                } catch {
                    resourceError = error.localizedDescription
                }
            }
        }
        .sheet(item: $selectedResourceEdit) { selection in
            if let resourceDocument {
                HexPayloadEditorView(document: resourceDocument, export: selection.export, variable: selection.variable) {
                    Task { await reloadResourceDocument() }
                }
            }
        }
        .sheet(item: $selectedTextFile) { file in
            TextAssetEditorView(file: file, onSaved: {})
        }
    }

    @ViewBuilder
    private var inspector: some View {
        if let file = viewModel.selectedFile {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                Label(file.url.lastPathComponent, systemImage: icon(for: file.url))
                    .font(.headline)
                    .lineLimit(2)
                    .textSelection(.enabled)

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Type").foregroundStyle(.secondary)
                        Text(file.url.pathExtension.isEmpty ? "File" : file.url.pathExtension.uppercased())
                    }
                    GridRow {
                        Text("Size").foregroundStyle(.secondary)
                        Text(file.byteCount, format: .byteCount(style: .file))
                    }
                    GridRow {
                        Text("Location").foregroundStyle(.secondary)
                        Text(file.relativePath).textSelection(.enabled)
                    }
                    if let resourceMetadata {
                        GridRow {
                            Text("Resource Class").foregroundStyle(.secondary)
                            Text(resourceMetadata.rootClassName ?? "Unknown")
                                .textSelection(.enabled)
                        }
                        GridRow {
                            Text("Format Version").foregroundStyle(.secondary)
                            Text("\(resourceMetadata.version) · build \(resourceMetadata.buildVersion)")
                        }
                        GridRow {
                            Text("Chunks").foregroundStyle(.secondary)
                            Text("\(resourceDocument?.exports.count ?? Int(resourceMetadata.chunkCount))")
                        }
                    }
                }
                .font(.callout)

                if let resourceDocument {
                    resourceStructure(resourceDocument)
                } else if let resourceError {
                    Label(resourceError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                        .textSelection(.enabled)
                }

                Link(destination: file.url) {
                    Label("Open in Default App", systemImage: "arrow.up.right.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                if isEditableText(file.url) {
                    Button {
                        selectedTextFile = file
                    } label: {
                        Label("Edit Text…", systemImage: "pencil")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }

                if isConvertibleImage(file.url) {
                    Button {
                        convertImage(file.url)
                    } label: {
                        Label("Convert Image…", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                if isPlayableAudio(file.url) {
                    AudioPreviewControl(url: file.url)
                }

                if let imageConversionMessage {
                    Text(imageConversionMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Spacer()
                }
                .padding(18)
            }
        } else {
            ContentUnavailableView("Select a File", systemImage: "doc.text.magnifyingglass")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func icon(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "tif", "tiff", "webp", "bmp", "dds", "ktx": "photo"
        case "wem", "ogg", "wav", "mp3", "flac", "opus": "waveform"
        case "json", "yaml", "yml", "xml": "curlybraces"
        default: "doc"
        }
    }

    @ViewBuilder
    private func resourceStructure(_ document: CR2WDocument) -> some View {
        Divider()
        Text("Resource Structure")
            .font(.headline)

        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow { Text("Format tables").foregroundStyle(.secondary); Text("\(document.tables.count)") }
            GridRow { Text("Names").foregroundStyle(.secondary); Text("\(document.names.count)") }
            GridRow { Text("Imports").foregroundStyle(.secondary); Text("\(document.imports.count)") }
            GridRow { Text("Properties").foregroundStyle(.secondary); Text("\(document.properties.count)") }
            GridRow { Text("Buffers").foregroundStyle(.secondary); Text("\(document.buffers.count)") }
            GridRow { Text("Embedded files").foregroundStyle(.secondary); Text("\(document.embedded.count)") }
        }
        .font(.caption)

        DisclosureGroup("Format Tables (\(document.tables.count))") {
            ForEach(document.tables, id: \.index) { table in
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    GridRow {
                        Text("Table \(table.index)").font(.caption.weight(.medium))
                        Text("\(table.itemCount) entries · offset 0x\(String(table.offset, radix: 16).uppercased())")
                    }
                    GridRow {
                        Text("CRC32").foregroundStyle(.secondary)
                        Text(String(format: "%08X", table.crc32)).font(.system(.caption2, design: .monospaced))
                    }
                }
                .padding(.vertical, 3)
            }
        }

        DisclosureGroup("Names (\(document.names.count))") {
            ForEach(document.names) { name in
                HStack(alignment: .firstTextBaseline) {
                    Text("\(name.index)").foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
                    Text(name.value).textSelection(.enabled)
                    Spacer(minLength: 8)
                    Text(String(format: "%08X", name.hash))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding(.vertical, 2)
            }
        }

        DisclosureGroup("Imports (\(document.imports.count))") {
            ForEach(document.imports) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(item.className) · flags 0x\(String(item.flags, radix: 16).uppercased())")
                        .font(.caption.weight(.medium))
                    Text(item.depotPath)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 3)
            }
        }

        DisclosureGroup("Properties (\(document.properties.count))") {
            ForEach(document.properties) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(item.className) · \(item.propertyName)")
                        .font(.caption.weight(.medium))
                    Text("class flags 0x\(String(item.classFlags, radix: 16).uppercased()) · property flags 0x\(String(item.propertyFlags, radix: 16).uppercased()) · hash 0x\(String(item.hash, radix: 16).uppercased())")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 3)
            }
        }

        DisclosureGroup("Buffers (\(document.buffers.count))") {
            ForEach(document.buffers) { buffer in
                VStack(alignment: .leading, spacing: 2) {
                    Text("Buffer \(buffer.index) · index \(buffer.bufferIndex) · flags 0x\(String(buffer.flags, radix: 16).uppercased())")
                        .font(.caption.weight(.medium))
                    Text("offset 0x\(String(buffer.offset, radix: 16).uppercased()) · stored \(buffer.compressedSize) B · expanded \(buffer.uncompressedSize) B · CRC32 \(String(format: "%08X", buffer.crc32))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 3)
            }
        }

        DisclosureGroup("Embedded Files (\(document.embedded.count))") {
            ForEach(document.embedded) { item in
                Text("\(item.index) · import \(item.importIndex) · chunk \(item.chunkIndex) · path hash 0x\(String(item.pathHash, radix: 16).uppercased())")
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .padding(.vertical, 2)
            }
        }

        DisclosureGroup("Chunks (\(document.exports.count))") {
            ForEach(document.exports) { export in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(export.index + 1). \(export.className)")
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(export.dataSize) B")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Button("Inspect or edit chunk bytes…") {
                        selectedResourceEdit = CR2WEditSelection(export: export, variable: nil)
                    }
                        .controlSize(.small)
                    DisclosureGroup("Properties (\(export.variables.count))") {
                        ForEach(export.variables) { variable in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(variable.propertyName) · \(variable.typeName)")
                                    .font(.caption.weight(.medium))
                                Text("Offset 0x\(String(variable.dataOffset, radix: 16).uppercased()) · \(variable.data.count) bytes · \(variable.preview)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                Button("Edit property bytes…") {
                                    selectedResourceEdit = CR2WEditSelection(export: export, variable: variable)
                                }
                                .controlSize(.small)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                    .font(.caption)
                }
                .padding(.vertical, 5)
            }
        }
        .font(.callout)
    }

    private func reloadResourceDocument() async {
        guard let file = viewModel.selectedFile else { return }
        do {
            resourceDocument = try await CR2WDocumentReader().readDocument(at: file.url)
            resourceError = nil
        } catch {
            resourceDocument = nil
            resourceError = error.localizedDescription
        }
    }

    private func isEditableText(_ url: URL) -> Bool {
        ["json", "xml", "yaml", "yml", "txt", "csv", "md", "ini", "toml"].contains(url.pathExtension.lowercased())
    }

    private func isConvertibleImage(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "tif", "tiff", "heic", "bmp", "gif"].contains(url.pathExtension.lowercased())
    }

    private func isPlayableAudio(_ url: URL) -> Bool {
        ["wav", "mp3", "m4a", "aif", "aiff", "caf", "aac", "flac"].contains(url.pathExtension.lowercased())
    }

    private func convertImage(_ source: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + ".png"
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        imageConversionMessage = nil
        let hasAccess = source.startAccessingSecurityScopedResource()
        Task {
            defer { if hasAccess { source.stopAccessingSecurityScopedResource() } }
            do {
                try await ImageConversionService().convert(source, to: destination)
                imageConversionMessage = "Saved \(destination.lastPathComponent)."
            } catch {
                imageConversionMessage = error.localizedDescription
            }
        }
    }
}
