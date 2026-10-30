import CryptoKit
import Foundation

struct ArchiveBuilderService: Sendable {
    func buildArchive(from sources: [URL], to destination: URL) async throws -> Int {
        try await Task.detached(priority: .userInitiated) {
            try Self.buildSynchronously(from: sources, to: destination)
        }.value
    }

    private static func buildSynchronously(from sources: [URL], to destination: URL) throws -> Int {
        guard !sources.isEmpty else { throw ArchiveBuilderError.noInputFiles }
        let files = try collectInputFiles(from: sources)
        guard !files.isEmpty else { throw ArchiveBuilderError.noInputFiles }
        guard files.count <= Int(UInt32.max) else { throw ArchiveBuilderError.tooManyFiles }

        let temporaryURL = destination.deletingLastPathComponent()
            .appendingPathComponent(".archive-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        var keepTemporary = false
        defer {
            if !keepTemporary { try? FileManager.default.removeItem(at: temporaryURL) }
        }

        let output = try FileHandle(forWritingTo: temporaryURL)
        defer { try? output.close() }

        try output.write(contentsOf: Data(repeating: 0, count: 176))
        var records: [ArchiveFileRecord] = []
        var segments: [ArchiveSegmentRecord] = []
        records.reserveCapacity(files.count)
        segments.reserveCapacity(files.count)

        for input in files {
            guard segments.count < Int(UInt32.max) else { throw ArchiveBuilderError.tooManySegments }
            let start = UInt32(segments.count)
            let inputHandle = try FileHandle(forReadingFrom: input.url)
            defer { try? inputHandle.close() }
            var hasher = Insecure.SHA1()
            var hashRemaining = input.byteCount
            while hashRemaining > 0 {
                let amount = Int(min(hashRemaining, 1_048_576))
                let chunk = try inputHandle.read(upToCount: amount) ?? Data()
                guard chunk.count == amount else { throw ArchiveBuilderError.sourceChanged(input.url.lastPathComponent) }
                hasher.update(data: chunk)
                hashRemaining -= UInt64(chunk.count)
            }

            let digest = Data(hasher.finalize())
            for (segmentIndex, inputSegment) in input.segments.enumerated() {
                guard segments.count < Int(UInt32.max) else { throw ArchiveBuilderError.tooManySegments }
                guard inputSegment.storedSize <= UInt64(UInt32.max),
                      inputSegment.expandedSize <= UInt64(UInt32.max) else {
                    throw ArchiveBuilderError.fileTooLarge(input.url.lastPathComponent)
                }
                if segmentIndex == 0, requiresPageAlignment(input.url), output.offsetInFile % 4096 != 0 {
                    let paddingCount = Int(4096 - output.offsetInFile % 4096)
                    try output.write(contentsOf: Data(repeating: 0, count: paddingCount))
                }
                try inputHandle.seek(toOffset: inputSegment.sourceOffset)
                let offset = output.offsetInFile
                var remaining = inputSegment.storedSize
                while remaining > 0 {
                    let amount = Int(min(remaining, 1_048_576))
                    let chunk = try inputHandle.read(upToCount: amount) ?? Data()
                    guard chunk.count == amount else { throw ArchiveBuilderError.sourceChanged(input.url.lastPathComponent) }
                    try output.write(contentsOf: chunk)
                    remaining -= UInt64(chunk.count)
                }
                segments.append(ArchiveSegmentRecord(
                    offset: offset,
                    compressedSize: UInt32(inputSegment.storedSize),
                    uncompressedSize: UInt32(inputSegment.expandedSize)
                ))
            }
            let end = UInt32(segments.count)
            let timestamp = fileTime(for: input.modificationDate)
            records.append(ArchiveFileRecord(
                hash: input.hash,
                fileTime: timestamp,
                inlineBufferSegmentCount: input.inlineBufferSegmentCount,
                segmentStart: start,
                segmentEnd: end,
                sha1: digest
            ))
        }

        guard records.count <= Int(UInt32.max),
              segments.count <= Int(UInt32.max),
              UInt64(records.count) * 56 + UInt64(segments.count) * 16 + 28 <= UInt64(UInt32.max) else {
            throw ArchiveBuilderError.indexTooLarge
        }

        if output.offsetInFile % 4096 != 0 {
            let paddingCount = Int(4096 - output.offsetInFile % 4096)
            try output.write(contentsOf: Data(repeating: 0, count: paddingCount))
        }

        let indexOffset = output.offsetInFile
        let index = makeIndex(records: records.sorted { $0.hash < $1.hash }, segments: segments)
        guard index.count <= Int(UInt32.max) else { throw ArchiveBuilderError.indexTooLarge }
        try output.write(contentsOf: index)
        let indexSize = UInt32(index.count)

        if output.offsetInFile % 4096 != 0 {
            let paddingCount = Int(4096 - output.offsetInFile % 4096)
            try output.write(contentsOf: Data(repeating: 0, count: paddingCount))
        }

        let fileSize = output.offsetInFile
        try output.synchronize()
        try output.seek(toOffset: 0)
        var header = Data()
        header.appendLE(UInt32(1_380_009_042))
        header.appendLE(UInt32(12))
        header.appendLE(indexOffset)
        header.appendLE(indexSize)
        header.appendLE(UInt64(0))
        header.appendLE(UInt32(0))
        header.appendLE(fileSize)
        header.append(Data(repeating: 0, count: 132))
        header.appendLE(UInt32(0))
        try output.write(contentsOf: header)
        try output.synchronize()
        try output.close()

        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporaryURL)
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
        }
        keepTemporary = true
        return files.count
    }

    private static func collectInputFiles(from sources: [URL]) throws -> [ArchiveBuildInput] {
        let fileManager = FileManager.default
        var urls: [URL] = []

        for source in sources {
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { continue }
            if values.isRegularFile == true {
                urls.append(source)
            } else if values.isDirectory == true,
                      let enumerator = fileManager.enumerator(
                        at: source,
                        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                        options: [.skipsHiddenFiles, .skipsPackageDescendants]
                      ) {
                for case let url as URL in enumerator {
                    let item = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    if item.isSymbolicLink != true, item.isRegularFile == true { urls.append(url) }
                }
            }
        }

        var inputs: [ArchiveBuildInput] = []
        var seenHashes = Set<UInt64>()
        for url in urls.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) {
            let basename = url.deletingPathExtension().lastPathComponent
            guard let hash = UInt64(basename) else {
                throw ArchiveBuilderError.hashNamedFilesRequired(url.lastPathComponent)
            }
            guard seenHashes.insert(hash).inserted else { throw ArchiveBuilderError.duplicateHash(hash) }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard let fileSize = values.fileSize, fileSize >= 0 else {
                throw ArchiveBuilderError.cannotReadFile(url.lastPathComponent)
            }
            let layout = try readArchiveSegments(for: url, fileSize: UInt64(fileSize))
            inputs.append(ArchiveBuildInput(
                url: url,
                hash: hash,
                byteCount: UInt64(fileSize),
                segments: layout.segments,
                inlineBufferSegmentCount: layout.inlineBufferSegmentCount,
                modificationDate: values.contentModificationDate ?? Date(timeIntervalSince1970: 0)
            ))
        }
        return inputs
    }

    private static func makeIndex(records: [ArchiveFileRecord], segments: [ArchiveSegmentRecord]) -> Data {
        var tables = Data()
        tables.appendLE(UInt32(records.count))
        tables.appendLE(UInt32(segments.count))
        tables.appendLE(UInt32(0))

        for record in records {
            tables.appendLE(record.hash)
            tables.appendLE(record.fileTime)
            tables.appendLE(record.inlineBufferSegmentCount)
            tables.appendLE(record.segmentStart)
            tables.appendLE(record.segmentEnd)
            tables.appendLE(UInt32(0))
            tables.appendLE(UInt32(0))
            tables.append(record.sha1)
        }

        for segment in segments {
            tables.appendLE(segment.offset)
            tables.appendLE(segment.compressedSize)
            tables.appendLE(segment.uncompressedSize)
        }

        var index = Data()
        index.appendLE(UInt32(8))
        index.appendLE(UInt32(tables.count + 8))
        index.appendLE(crc64(tables))
        index.append(tables)
        return index
    }

    private static func crc64(_ data: Data) -> UInt64 {
        let polynomial: UInt64 = 0xC96C5795D7870F42
        var crc = UInt64.max
        for byte in data {
            crc = (crc >> 8) ^ ((crc ^ UInt64(byte)) & 0xFF).crc64TableValue(using: polynomial)
        }
        return ~crc
    }

    private static func requiresPageAlignment(_ url: URL) -> Bool {
        ["bk2", "bnk", "opusinfo", "wem", "bin"].contains(url.pathExtension.lowercased())
    }

    private static func fileTime(for date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 + 11_644_473_600) * 10_000_000)
    }

    private static func readArchiveSegments(for url: URL, fileSize: UInt64) throws -> ArchiveFileLayout {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard fileSize >= 4 else {
            return ArchiveFileLayout(segments: [ArchiveBuildSegment(sourceOffset: 0, storedSize: fileSize, expandedSize: fileSize)], inlineBufferSegmentCount: 0)
        }
        let prefix = try readExactly(4, from: handle)
        guard readUInt32(prefix, at: 0) == 0x57325243 else {
            return ArchiveFileLayout(segments: [ArchiveBuildSegment(sourceOffset: 0, storedSize: fileSize, expandedSize: fileSize)], inlineBufferSegmentCount: 0)
        }
        guard fileSize >= 160 else { throw ArchiveBuilderError.malformedResource(url.lastPathComponent) }

        try handle.seek(toOffset: 0)
        let header = try readExactly(160, from: handle)
        let objectsEnd = UInt64(readUInt32(header, at: 24))
        let bufferTableOffset = UInt64(readUInt32(header, at: 100))
        let bufferCount = readUInt32(header, at: 104)
        guard objectsEnd >= 160, objectsEnd <= fileSize, bufferCount <= 1_000_000 else {
            throw ArchiveBuilderError.malformedResource(url.lastPathComponent)
        }
        let bufferTableLength = UInt64(bufferCount) * 24
        guard bufferTableOffset <= fileSize, bufferTableLength <= fileSize - bufferTableOffset else {
            throw ArchiveBuilderError.malformedResource(url.lastPathComponent)
        }

        var segments = [ArchiveBuildSegment(sourceOffset: 0, storedSize: objectsEnd, expandedSize: objectsEnd)]
        var expectedNextBufferOffset = objectsEnd
        if bufferCount > 0 {
            try handle.seek(toOffset: bufferTableOffset)
            let table = try readExactly(Int(bufferTableLength), from: handle)
            var cursor = ResourceTableCursor(data: table)
            for _ in 0..<bufferCount {
                _ = try cursor.readUInt32()
                _ = try cursor.readUInt32()
                let offset = UInt64(try cursor.readUInt32())
                let diskSize = UInt64(try cursor.readUInt32())
                let memorySize = UInt64(try cursor.readUInt32())
                _ = try cursor.readUInt32()
                guard offset == expectedNextBufferOffset,
                      offset <= fileSize,
                      diskSize <= fileSize - offset,
                      diskSize <= UInt64(UInt32.max),
                      memorySize <= UInt64(UInt32.max) else {
                    throw ArchiveBuilderError.malformedResource(url.lastPathComponent)
                }
                segments.append(ArchiveBuildSegment(sourceOffset: offset, storedSize: diskSize, expandedSize: memorySize))
                expectedNextBufferOffset = offset + diskSize
            }
        }

        if expectedNextBufferOffset < fileSize {
            let trailingSize = fileSize - expectedNextBufferOffset
            guard trailingSize <= UInt64(UInt32.max) else { throw ArchiveBuilderError.fileTooLarge(url.lastPathComponent) }
            segments.append(ArchiveBuildSegment(sourceOffset: expectedNextBufferOffset, storedSize: trailingSize, expandedSize: trailingSize))
        }
        let inlineBufferCount = bufferCount > 0 ? bufferCount - 1 : 0
        if segments.isEmpty {
            segments.append(ArchiveBuildSegment(sourceOffset: 0, storedSize: 0, expandedSize: 0))
        }
        return ArchiveFileLayout(segments: segments, inlineBufferSegmentCount: inlineBufferCount)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes { bytes in
            UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }

    private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        var data = Data(capacity: count)
        while data.count < count {
            let chunk = try handle.read(upToCount: count - data.count) ?? Data()
            guard !chunk.isEmpty else { throw ArchiveBuilderError.sourceChanged("input resource") }
            data.append(chunk)
        }
        return data
    }
}

private struct ArchiveBuildInput {
    let url: URL
    let hash: UInt64
    let byteCount: UInt64
    let segments: [ArchiveBuildSegment]
    let inlineBufferSegmentCount: UInt32
    let modificationDate: Date
}

private struct ArchiveBuildSegment {
    let sourceOffset: UInt64
    let storedSize: UInt64
    let expandedSize: UInt64
}

private struct ArchiveFileLayout {
    let segments: [ArchiveBuildSegment]
    let inlineBufferSegmentCount: UInt32
}

private struct ArchiveFileRecord {
    let hash: UInt64
    let fileTime: Int64
    let inlineBufferSegmentCount: UInt32
    let segmentStart: UInt32
    let segmentEnd: UInt32
    let sha1: Data
}

private struct ArchiveSegmentRecord {
    let offset: UInt64
    let compressedSize: UInt32
    let uncompressedSize: UInt32
}

private struct ResourceTableCursor {
    let data: Data
    var offset = 0

    mutating func readUInt32() throws -> UInt32 {
        guard offset <= data.count, 4 <= data.count - offset else {
            throw ArchiveBuilderError.malformedResource("buffer table")
        }
        defer { offset += 4 }
        return data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }
}

private enum ArchiveBuilderError: LocalizedError {
    case noInputFiles
    case hashNamedFilesRequired(String)
    case duplicateHash(UInt64)
    case fileTooLarge(String)
    case sourceChanged(String)
    case cannotReadFile(String)
    case malformedResource(String)
    case tooManyFiles
    case tooManySegments
    case indexTooLarge

    var errorDescription: String? {
        switch self {
        case .noInputFiles:
            return "Select at least one supported file or folder to build an archive."
        case .hashNamedFilesRequired(let name):
            return "Archive creation currently requires files named with their numeric resource hash, such as 123456789.bin. Rename \(name) before building."
        case .duplicateHash(let hash):
            return "More than one selected file uses resource hash \(hash). Remove the duplicate before building."
        case .fileTooLarge(let name):
            return "\(name) exceeds the archive format's 32-bit segment size limit."
        case .sourceChanged(let name):
            return "\(name) changed while the archive was being written. Try again."
        case .cannotReadFile(let name):
            return "The size of \(name) could not be read."
        case .malformedResource(let name):
            return "The resource buffer table in \(name) is malformed or its buffer ranges are not contiguous."
        case .tooManyFiles:
            return "The selected input contains more files than the archive format can index."
        case .tooManySegments:
            return "The selected input contains more segments than the archive format can index."
        case .indexTooLarge:
            return "The generated archive index exceeds the format's 32-bit size limit."
        }
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}

private extension UInt64 {
    func crc64TableValue(using polynomial: UInt64) -> UInt64 {
        var value = self
        for _ in 0..<8 { value = (value & 1) != 0 ? (value >> 1) ^ polynomial : value >> 1 }
        return value
    }
}
