import Combine
import Foundation

enum ArchiveEntryFilter: String, CaseIterable, Identifiable {
    case all = "All Entries"
    case multipleSegments = "Multiple Segments"
    case uncompressed = "Uncompressed"

    var id: String { rawValue }

    func contains(_ entry: ArchiveEntry) -> Bool {
        switch self {
        case .all:
            return true
        case .multipleSegments:
            return entry.segments.count > 1
        case .uncompressed:
            return entry.canReadWithoutCodec
        }
    }
}

@MainActor
final class ArchiveCatalogViewModel: ObservableObject {
    let catalog: ArchiveCatalog

    @Published var searchText = ""
    @Published var filter: ArchiveEntryFilter = .all
    @Published var largestFirst = false
    @Published var selectedEntryID: UInt64?

    init(catalog: ArchiveCatalog) {
        self.catalog = catalog
    }

    var visibleEntries: [ArchiveEntry] {
        let matching = catalog.entries.filter { entry in
            filter.contains(entry)
                && (searchText.isEmpty
                    || entry.displayName.localizedCaseInsensitiveContains(searchText)
                    || String(entry.hash).localizedCaseInsensitiveContains(searchText))
        }

        if largestFirst {
            return matching.sorted {
                if $0.uncompressedByteCount == $1.uncompressedByteCount {
                    return $0.hash < $1.hash
                }
                return $0.uncompressedByteCount > $1.uncompressedByteCount
            }
        }
        return matching.sorted { $0.hash < $1.hash }
    }

    var selectedEntry: ArchiveEntry? {
        guard let selectedEntryID else { return nil }
        return catalog.entries.first { $0.id == selectedEntryID }
    }
}
