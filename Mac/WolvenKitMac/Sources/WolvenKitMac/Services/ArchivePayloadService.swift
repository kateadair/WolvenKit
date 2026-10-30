import Foundation

struct ArchivePayloadService: Sendable {
    func export(_ entry: ArchiveEntry, from catalog: ArchiveCatalog, to destination: URL) async throws {
        guard entry.canReadWithoutCodec else { throw ArchiveReaderError.compressedEntry }
        guard destination.standardizedFileURL != catalog.archiveURL.standardizedFileURL else {
            throw ArchiveReaderError.invalidEntry("The output path cannot replace the source archive.")
        }

        try await Task.detached(priority: .userInitiated) {
            try Self.exportSynchronously(entry, from: catalog, to: destination)
        }.value
    }

    private static func exportSynchronously(_ entry: ArchiveEntry, from catalog: ArchiveCatalog, to destination: URL) throws {
        let fileManager = FileManager.default
        let archiveURL = catalog.archiveURL
        let attributes = try fileManager.attributesOfItem(atPath: archiveURL.path)
        guard let currentSize = (attributes[.size] as? NSNumber)?.uint64Value else {
            throw ArchiveReaderError.notAFile(archiveURL)
        }

        let temporaryURL = destination.deletingLastPathComponent()
            .appendingPathComponent(".export-\(UUID().uuidString).tmp")
        guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let input = try FileHandle(forReadingFrom: archiveURL)
        let output = try FileHandle(forWritingTo: temporaryURL)
        var keepTemporary = false
        defer {
            try? input.close()
            try? output.close()
            if !keepTemporary { try? fileManager.removeItem(at: temporaryURL) }
        }

        var written: UInt64 = 0
        for segment in entry.segments {
            guard segment.compressedSize == segment.uncompressedSize,
                  segment.offset <= currentSize,
                  UInt64(segment.compressedSize) <= currentSize - segment.offset else {
                throw ArchiveReaderError.archiveChanged
            }

            try input.seek(toOffset: segment.offset)
            var remaining = Int(segment.compressedSize)
            while remaining > 0 {
                let chunkSize = min(remaining, 1_048_576)
                let chunk = try readExactly(chunkSize, from: input)
                try output.write(contentsOf: chunk)
                remaining -= chunk.count
                written += UInt64(chunk.count)
            }
        }

        guard written == entry.uncompressedByteCount else {
            throw ArchiveReaderError.invalidEntry("The extracted byte count does not match the indexed entry size.")
        }

        try output.synchronize()
        try output.close()
        try input.close()

        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destination)
        }
        keepTemporary = true
    }

    private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        var data = Data(capacity: count)
        while data.count < count {
            let chunk = try handle.read(upToCount: count - data.count) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count == count else { throw ArchiveReaderError.archiveChanged }
        return data
    }
}
