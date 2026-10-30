import Foundation

struct TextAssetSnapshot: Sendable {
    let text: String
    let data: Data
}

struct TextAssetService: Sendable {
    func load(_ url: URL) async throws -> TextAssetSnapshot {
        try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count <= 32 * 1024 * 1024 else { throw TextAssetError.fileTooLarge }
            guard let text = String(data: data, encoding: .utf8) else { throw TextAssetError.invalidEncoding }
            return TextAssetSnapshot(text: text, data: data)
        }.value
    }

    func save(_ text: String, to url: URL, expectedOriginal: Data) async throws {
        try await Task.detached(priority: .userInitiated) {
            try Self.saveSynchronously(text, to: url, expectedOriginal: expectedOriginal)
        }.value
    }

    private static func saveSynchronously(_ text: String, to url: URL, expectedOriginal: Data) throws {
        guard text.utf8.count <= 32 * 1024 * 1024 else { throw TextAssetError.fileTooLarge }
        guard let current = try? Data(contentsOf: url, options: [.mappedIfSafe]), current == expectedOriginal else {
            throw TextAssetError.changedOnDisk
        }

        let ext = url.pathExtension.lowercased()
        let data = Data(text.utf8)
        switch ext {
        case "json":
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        case "xml":
            _ = try XMLDocument(data: data, options: [.nodePreserveAll])
        default:
            break
        }

        let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(".text-edit-\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporaryURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }
}

private enum TextAssetError: LocalizedError {
    case fileTooLarge
    case invalidEncoding
    case changedOnDisk

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            return "Text editing is limited to files no larger than 32 MB."
        case .invalidEncoding:
            return "The file is not valid UTF-8 text."
        case .changedOnDisk:
            return "This file changed on disk after it was opened. Reopen it before saving edits."
        }
    }
}
