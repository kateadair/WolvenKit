import Combine
import Foundation

enum AssetCategory: String, CaseIterable, Identifiable {
    case all = "All Files"
    case images = "Images"
    case audio = "Audio"
    case documents = "Documents"
    case other = "Other"

    var id: String { rawValue }

    func contains(_ file: ProjectFile) -> Bool {
        let ext = file.url.pathExtension.lowercased()
        switch self {
        case .all:
            return true
        case .images:
            return ["png", "jpg", "jpeg", "tif", "tiff", "webp", "bmp", "dds", "ktx"].contains(ext)
        case .audio:
            return ["wav", "ogg", "mp3", "flac", "wem", "opus"].contains(ext)
        case .documents:
            return ["json", "yaml", "yml", "xml", "txt", "csv", "md"].contains(ext)
        case .other:
            return !AssetCategory.images.contains(file)
                && !AssetCategory.audio.contains(file)
                && !AssetCategory.documents.contains(file)
        }
    }
}

enum AssetSortOrder: String, CaseIterable, Identifiable {
    case name = "Name"
    case largestFirst = "Largest First"

    var id: String { rawValue }
}

@MainActor
final class AssetCatalogViewModel: ObservableObject {
    @Published private(set) var files: [ProjectFile]
    @Published var searchText = ""
    @Published var category: AssetCategory = .all
    @Published var sortOrder: AssetSortOrder = .name
    @Published var selectedFileID: String?

    init(files: [ProjectFile]) {
        self.files = files
    }

    var visibleFiles: [ProjectFile] {
        let matching = files.filter { file in
            category.contains(file)
                && (searchText.isEmpty || file.relativePath.localizedStandardContains(searchText))
        }

        switch sortOrder {
        case .name:
            return matching.sorted {
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }
        case .largestFirst:
            return matching.sorted {
                if $0.byteCount == $1.byteCount {
                    return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
                }
                return $0.byteCount > $1.byteCount
            }
        }
    }

    var selectedFile: ProjectFile? {
        guard let selectedFileID else { return nil }
        return files.first { $0.id == selectedFileID }
    }

    func replaceFiles(_ files: [ProjectFile]) {
        self.files = files
        if let selectedFileID, !files.contains(where: { $0.id == selectedFileID }) {
            self.selectedFileID = nil
        }
    }
}
