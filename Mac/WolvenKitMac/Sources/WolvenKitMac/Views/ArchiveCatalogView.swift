import SwiftUI
import AppKit

struct ArchiveCatalogView: View {
    @StateObject private var viewModel: ArchiveCatalogViewModel
    let onClose: () -> Void
    let exportEntry: (ArchiveEntry, URL) async -> Void

    init(catalog: ArchiveCatalog, onClose: @escaping () -> Void, exportEntry: @escaping (ArchiveEntry, URL) async -> Void) {
        _viewModel = StateObject(wrappedValue: ArchiveCatalogViewModel(catalog: catalog))
        self.onClose = onClose
        self.exportEntry = exportEntry
    }

    var body: some View {
        VStack(spacing: 0) {
            archiveHeader
            Divider()
            HStack(spacing: 0) {
                entryList
                Divider()
                entryInspector
                    .frame(minWidth: 260, idealWidth: 310, maxWidth: 380)
            }
        }
        .navigationTitle(viewModel.catalog.fileName)
    }

    private var archiveHeader: some View {
        HStack(spacing: 14) {
            Image(systemName: "archivebox")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(viewModel.catalog.fileName)
                    .font(.headline)
                Text("Version \(viewModel.catalog.header.version) · \(viewModel.catalog.entries.count.formatted()) entries · \(viewModel.catalog.dependencies.count.formatted()) dependencies")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close Archive", action: onClose)
                .buttonStyle(.bordered)
        }
        .padding(18)
    }

    private var entryList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("Search by hash", text: $viewModel.searchText)
                    .textFieldStyle(.roundedBorder)
                Picker("Filter", selection: $viewModel.filter) {
                    ForEach(ArchiveEntryFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .frame(width: 180)
                Picker("Sort", selection: $viewModel.largestFirst) {
                    Text("Hash").tag(false)
                    Text("Largest First").tag(true)
                }
                .frame(width: 145)
            }
            .padding(12)

            if viewModel.visibleEntries.isEmpty {
                ContentUnavailableView {
                    Label("No Matching Entries", systemImage: "archivebox")
                } description: {
                    Text("Change the search text or entry filter.")
                }
            } else {
                List(viewModel.visibleEntries, selection: $viewModel.selectedEntryID) { entry in
                    HStack(spacing: 10) {
                        Image(systemName: entry.canReadWithoutCodec ? "doc" : "doc.zipper")
                            .foregroundStyle(.secondary)
                        Text(entry.displayName)
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                        Text(entry.fileByteCount.formatted(.byteCount(style: .file)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .tag(Optional(entry.id))
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 400)
    }

    @ViewBuilder
    private var entryInspector: some View {
        if let entry = viewModel.selectedEntry {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(entry.displayName)
                        .font(.title3.monospaced().weight(.semibold))
                        .textSelection(.enabled)

                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 9) {
                        valueRow("Segments", "\(entry.segments.count)")
                        valueRow("Inline buffers", "\(entry.inlineBufferSegmentCount)")
                        valueRow("Stored size", entry.compressedByteCount.formatted(.byteCount(style: .file)))
                        valueRow("Reconstructed file", entry.fileByteCount.formatted(.byteCount(style: .file)))
                        valueRow("Expanded segments", entry.uncompressedByteCount.formatted(.byteCount(style: .file)))
                        valueRow("Timestamp", entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                        valueRow("SHA-1", entry.sha1.map { String(format: "%02x", $0) }.joined())
                    }
                    .font(.callout)

                    if entry.canReadWithoutCodec {
                        Label("The main segment is stored without archive compression; embedded buffers remain in their resource encoding.", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Label("This entry contains a compressed main segment.", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Export supports KARK stored and repeated-byte Kraken blocks. Unsupported entropy-coded blocks produce a precise decoding error.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        export(entry)
                    } label: {
                        Label("Export Entry…", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Divider()
                    Text("Segment ranges")
                        .font(.headline)
                    ForEach(entry.segments.indices, id: \.self) { index in
                        let segment = entry.segments[index]
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Segment \(index + 1)")
                                .font(.subheadline.weight(.medium))
                            Text("Offset 0x\(String(segment.offset, radix: 16).uppercased()) · stored \(segment.compressedSize) bytes · expanded \(segment.uncompressedSize) bytes")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("Select an Entry", systemImage: "doc.text.magnifyingglass")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func valueRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func export(_ entry: ArchiveEntry) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.displayName + ".bin"
        panel.allowedContentTypes = [.data]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task {
            await exportEntry(entry, destination)
        }
    }
}
