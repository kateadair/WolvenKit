import Foundation

struct ArchiveHeader: Hashable, Sendable {
    let version: UInt32
    let indexOffset: UInt64
    let indexSize: UInt32
    let debugOffset: UInt64
    let debugSize: UInt32
    let declaredFileSize: UInt64
    let customDataSize: UInt32
}

struct ArchiveSegment: Hashable, Sendable {
    let offset: UInt64
    let compressedSize: UInt32
    let uncompressedSize: UInt32
}

struct ArchiveEntry: Identifiable, Hashable, Sendable {
    let hash: UInt64
    let timestamp: Date
    let inlineBufferSegmentCount: UInt32
    let dependencyRange: Range<UInt32>
    let segments: [ArchiveSegment]
    let sha1: Data

    var id: UInt64 { hash }

    var displayName: String {
        String(format: "0x%016llX", hash)
    }

    var compressedByteCount: UInt64 {
        segments.reduce(0) { $0 + UInt64($1.compressedSize) }
    }

    var uncompressedByteCount: UInt64 {
        segments.reduce(0) { $0 + UInt64($1.uncompressedSize) }
    }

    var canReadWithoutCodec: Bool {
        segments.allSatisfy { $0.compressedSize == $0.uncompressedSize }
    }
}

struct ArchiveCatalog: Identifiable, Hashable, Sendable {
    let archiveURL: URL
    let header: ArchiveHeader
    let crc: UInt64
    let fileTableOffset: UInt32
    let fileTableSize: UInt32
    let dependencies: [UInt64]
    let entries: [ArchiveEntry]

    var id: URL { archiveURL }
    var fileName: String { archiveURL.lastPathComponent }
}

enum ArchiveReaderError: LocalizedError {
    case notAFile(URL)
    case invalidMagic
    case invalidHeader(String)
    case invalidIndex(String)
    case invalidEntry(String)
    case compressedEntry
    case archiveChanged

    var errorDescription: String? {
        switch self {
        case .notAFile(let url):
            return "The selected archive cannot be read: \(url.lastPathComponent)."
        case .invalidMagic:
            return "The selected file does not have a valid archive signature."
        case .invalidHeader(let detail):
            return "The archive header is invalid: \(detail)"
        case .invalidIndex(let detail):
            return "The archive index is invalid: \(detail)"
        case .invalidEntry(let detail):
            return "The archive contains an invalid entry: \(detail)"
        case .compressedEntry:
            return "This entry contains compressed segments that cannot yet be decoded by this build."
        case .archiveChanged:
            return "The archive changed after it was indexed. Open it again before exporting entries."
        }
    }
}
