import Foundation

struct ArchiveIndexReader: Sendable {
    private static let archiveMagic: UInt32 = 1_380_009_042
    private static let extendedHeaderSize = 0xAC
    private static let headerSize = 40
    private static let indexHeaderSize = 28
    private static let entrySize = 56
    private static let segmentSize = 16
    private static let dependencySize = 8
    private static let maximumIndexSize = 512 * 1024 * 1024

    func readArchive(at url: URL) async throws -> ArchiveCatalog {
        try await Task.detached(priority: .userInitiated) {
            try Self.readArchiveSynchronously(at: url)
        }.value
    }

    private static func readArchiveSynchronously(at url: URL) throws -> ArchiveCatalog {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSizeNumber = attributes[.size] as? NSNumber else {
            throw ArchiveReaderError.notAFile(url)
        }

        let fileSize = fileSizeNumber.uint64Value
        let fixedHeaderLength = extendedHeaderSize + MemoryLayout<UInt32>.size
        guard fileSize >= UInt64(fixedHeaderLength) else {
            throw ArchiveReaderError.invalidHeader("The file is shorter than the fixed header.")
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let headerBytes = try readExactly(fixedHeaderLength, from: handle)
        var cursor = BinaryCursor(data: headerBytes)
        let magic = try cursor.readUInt32()
        guard magic == archiveMagic else { throw ArchiveReaderError.invalidMagic }

        let version = try cursor.readUInt32()
        let indexOffset = try cursor.readUInt64()
        let indexSize = try cursor.readUInt32()
        let debugOffset = try cursor.readUInt64()
        let debugSize = try cursor.readUInt32()
        let declaredFileSize = try cursor.readUInt64()
        guard cursor.offset == headerSize else {
            throw ArchiveReaderError.invalidHeader("The fixed header layout is inconsistent.")
        }

        try cursor.seek(to: extendedHeaderSize)
        let customDataSize = try cursor.readUInt32()
        let header = ArchiveHeader(
            version: version,
            indexOffset: indexOffset,
            indexSize: indexSize,
            debugOffset: debugOffset,
            debugSize: debugSize,
            declaredFileSize: declaredFileSize,
            customDataSize: customDataSize
        )

        guard declaredFileSize == 0 || declaredFileSize <= fileSize else {
            throw ArchiveReaderError.invalidHeader("The declared file size exceeds the actual file size.")
        }
        guard UInt64(customDataSize) <= fileSize - UInt64(fixedHeaderLength) else {
            throw ArchiveReaderError.invalidHeader("The custom data range is outside the archive file.")
        }
        guard debugOffset <= fileSize, UInt64(debugSize) <= fileSize - debugOffset else {
            throw ArchiveReaderError.invalidHeader("The debug data range is outside the archive file.")
        }
        guard indexOffset <= fileSize,
              UInt64(indexSize) <= fileSize - indexOffset,
              indexOffset >= UInt64(fixedHeaderLength),
              indexSize >= UInt32(indexHeaderSize),
              indexSize <= UInt32(maximumIndexSize) else {
            throw ArchiveReaderError.invalidHeader("The index range is outside the archive file.")
        }
        guard indexOffset <= UInt64(Int64.max) else {
            throw ArchiveReaderError.invalidHeader("The index offset is too large to address.")
        }

        try handle.seek(toOffset: indexOffset)
        let indexData = try readExactly(Int(indexSize), from: handle)
        return try parseIndex(indexData, archiveURL: url.standardizedFileURL, header: header, archiveSize: fileSize)
    }

    private static func parseIndex(_ data: Data, archiveURL: URL, header: ArchiveHeader, archiveSize: UInt64) throws -> ArchiveCatalog {
        var cursor = BinaryCursor(data: data)
        let fileTableOffset = try cursor.readUInt32()
        let fileTableSize = try cursor.readUInt32()
        let crc = try cursor.readUInt64()
        let fileEntryCount = try cursor.readUInt32()
        let fileSegmentCount = try cursor.readUInt32()
        let dependencyCount = try cursor.readUInt32()

        let expectedSize = UInt64(indexHeaderSize)
            + UInt64(fileEntryCount) * UInt64(entrySize)
            + UInt64(fileSegmentCount) * UInt64(segmentSize)
            + UInt64(dependencyCount) * UInt64(dependencySize)
        guard expectedSize <= UInt64(data.count) else {
            throw ArchiveReaderError.invalidIndex("The table counts exceed the available index bytes.")
        }

        struct EntryRecord {
            let hash: UInt64
            let timestamp: Date
            let inlineBufferSegmentCount: UInt32
            let segmentRange: Range<UInt32>
            let dependencyRange: Range<UInt32>
            let sha1: Data
        }

        var records: [EntryRecord] = []
        records.reserveCapacity(Int(fileEntryCount))
        for _ in 0..<fileEntryCount {
            let hash = try cursor.readUInt64()
            let fileTime = try cursor.readInt64()
            let inlineBufferSegmentCount = try cursor.readUInt32()
            let segmentStart = try cursor.readUInt32()
            let segmentEnd = try cursor.readUInt32()
            let dependencyStart = try cursor.readUInt32()
            let dependencyEnd = try cursor.readUInt32()
            let sha1 = try cursor.readData(count: 20)

            guard segmentStart < segmentEnd, segmentEnd <= fileSegmentCount else {
                throw ArchiveReaderError.invalidEntry("A file references an invalid segment range.")
            }
            guard dependencyStart <= dependencyEnd, dependencyEnd <= dependencyCount else {
                throw ArchiveReaderError.invalidEntry("A file references an invalid dependency range.")
            }

            let unixSeconds = Double(fileTime) / 10_000_000.0 - 11_644_473_600.0
            let timestamp = Date(timeIntervalSince1970: unixSeconds)
            records.append(EntryRecord(
                hash: hash,
                timestamp: timestamp,
                inlineBufferSegmentCount: inlineBufferSegmentCount,
                segmentRange: segmentStart..<segmentEnd,
                dependencyRange: dependencyStart..<dependencyEnd,
                sha1: sha1
            ))
        }

        var segments: [ArchiveSegment] = []
        segments.reserveCapacity(Int(fileSegmentCount))
        for _ in 0..<fileSegmentCount {
            let offset = try cursor.readUInt64()
            let compressedSize = try cursor.readUInt32()
            let uncompressedSize = try cursor.readUInt32()
            guard offset <= archiveSize, UInt64(compressedSize) <= archiveSize - offset else {
                throw ArchiveReaderError.invalidEntry("A file segment points outside the archive data.")
            }
            segments.append(ArchiveSegment(offset: offset, compressedSize: compressedSize, uncompressedSize: uncompressedSize))
        }

        var dependencies: [UInt64] = []
        dependencies.reserveCapacity(Int(dependencyCount))
        for _ in 0..<dependencyCount {
            dependencies.append(try cursor.readUInt64())
        }

        var entriesByHash: [UInt64: ArchiveEntry] = [:]
        entriesByHash.reserveCapacity(records.count)
        for record in records where entriesByHash[record.hash] == nil {
            let entrySegments = Array(segments[Int(record.segmentRange.lowerBound)..<Int(record.segmentRange.upperBound)])
            entriesByHash[record.hash] = ArchiveEntry(
                hash: record.hash,
                timestamp: record.timestamp,
                inlineBufferSegmentCount: record.inlineBufferSegmentCount,
                dependencyRange: record.dependencyRange,
                segments: entrySegments,
                sha1: record.sha1
            )
        }

        let entries = entriesByHash.values.sorted { $0.hash < $1.hash }
        return ArchiveCatalog(
            archiveURL: archiveURL,
            header: header,
            crc: crc,
            fileTableOffset: fileTableOffset,
            fileTableSize: fileTableSize,
            dependencies: dependencies,
            entries: entries
        )
    }

    private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        guard count >= 0 else { throw ArchiveReaderError.invalidIndex("A negative read length was requested.") }
        var data = Data(capacity: count)
        while data.count < count {
            let chunk = try handle.read(upToCount: count - data.count) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count == count else {
            throw ArchiveReaderError.invalidIndex("The archive ended before the requested table data was read.")
        }
        return data
    }
}

private struct BinaryCursor {
    let data: Data
    var offset = 0

    mutating func seek(to newOffset: Int) throws {
        guard newOffset >= 0, newOffset <= data.count else {
            throw ArchiveReaderError.invalidHeader("A header field is outside the input data.")
        }
        offset = newOffset
    }

    mutating func readUInt32() throws -> UInt32 {
        try readInteger(UInt32.self)
    }

    mutating func readUInt64() throws -> UInt64 {
        try readInteger(UInt64.self)
    }

    mutating func readInt64() throws -> Int64 {
        try readInteger(Int64.self)
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, offset <= data.count, count <= data.count - offset else {
            throw ArchiveReaderError.invalidIndex("A table record is truncated.")
        }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    private mutating func readInteger<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let count = MemoryLayout<T>.size
        guard offset <= data.count, count <= data.count - offset else {
            throw ArchiveReaderError.invalidIndex("A table record is truncated.")
        }
        let rawValue = data.withUnsafeBytes { bytes in
            bytes.loadUnaligned(fromByteOffset: offset, as: T.self)
        }
        offset += count
        return T(littleEndian: rawValue)
    }
}
