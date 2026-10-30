import SwiftUI

struct AssetCatalogView: View {
    @StateObject private var viewModel: AssetCatalogViewModel
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
    }

    @ViewBuilder
    private var inspector: some View {
        if let file = viewModel.selectedFile {
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
                }
                .font(.callout)

                Link(destination: file.url) {
                    Label("Open in Default App", systemImage: "arrow.up.right.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Spacer()
            }
            .padding(18)
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
}
