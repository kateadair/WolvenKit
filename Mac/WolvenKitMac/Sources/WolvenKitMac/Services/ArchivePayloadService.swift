import Foundation

struct ArchivePayloadService: Sendable {
    func export(_ entry: ArchiveEntry, from catalog: ArchiveCatalog, to destination: URL) async throws {
        guard entry.canAttemptExport else {
            throw ArchiveReaderError.invalidEntry("The selected entry does not contain any data segments.")
        }
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
        for (index, segment) in entry.segments.enumerated() {
            guard segment.offset <= currentSize,
                  UInt64(segment.compressedSize) <= currentSize - segment.offset else {
                throw ArchiveReaderError.archiveChanged
            }

            try input.seek(toOffset: segment.offset)
            if index == 0, segment.compressedSize != segment.uncompressedSize {
                guard segment.compressedSize <= UInt32(KrakenDecoder.Limits.default.maximumInputSize) else {
                    throw KrakenDecodingError.inputLimitExceeded
                }
                let packed = try readExactly(Int(segment.compressedSize), from: input)
                let decoded = try KrakenDecoder().decode(packed)
                guard decoded.count == Int(segment.uncompressedSize) else {
                    throw ArchiveReaderError.invalidEntry("The decoded main segment size does not match its index record.")
                }
                try output.write(contentsOf: decoded)
                written += UInt64(decoded.count)
            } else {
                let remainingSize = Int(index == 0 ? segment.uncompressedSize : segment.compressedSize)
                var remaining = remainingSize
                while remaining > 0 {
                    let chunkSize = min(remaining, 1_048_576)
                    let chunk = try readExactly(chunkSize, from: input)
                    try output.write(contentsOf: chunk)
                    remaining -= chunk.count
                    written += UInt64(chunk.count)
                }
            }
        }

        guard written == entry.fileByteCount else {
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
