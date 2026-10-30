import Foundation

struct CR2WMetadataReader: Sendable {
    private static let magic: UInt32 = 0x57325243
    private static let prefixLength = 160
    private static let maximumStringTableLength = 1_048_576

    func readMetadata(at url: URL) async -> CR2WMetadata? {
        await Task.detached(priority: .utility) {
            try? Self.readSynchronously(at: url)
        }.value
    }

    private static func readSynchronously(at url: URL) throws -> CR2WMetadata? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size >= prefixLength else {
            return nil
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let prefix = try readExactly(prefixLength, from: handle) else { return nil }

        guard readUInt32(prefix, at: 0) == magic else { return nil }
        let version = readUInt32(prefix, at: 4)
        let flags = readUInt32(prefix, at: 8)
        let timestamp = readUInt64(prefix, at: 12)
        let buildVersion = readUInt32(prefix, at: 20)
        let objectDataEnd = readUInt32(prefix, at: 24)
        let bufferDataEnd = readUInt32(prefix, at: 28)
        let checksum = readUInt32(prefix, at: 32)
        let chunkCount = readUInt32(prefix, at: 36)
        let stringTableOffset = readUInt32(prefix, at: 40)
        let stringTableLength = readUInt32(prefix, at: 44)

        guard stringTableOffset <= UInt64(size),
              UInt64(stringTableLength) <= UInt64(size) - UInt64(stringTableOffset),
              stringTableLength > 1 else {
            return CR2WMetadata(
                version: version,
                flags: flags,
                timestamp: timestamp,
                buildVersion: buildVersion,
                objectDataEnd: objectDataEnd,
                bufferDataEnd: bufferDataEnd,
                checksum: checksum,
                chunkCount: chunkCount,
                rootClassName: nil
            )
        }

        let readableLength = min(Int(stringTableLength), maximumStringTableLength)
        try handle.seek(toOffset: UInt64(stringTableOffset))
        guard let stringTable = try readExactly(readableLength, from: handle) else { return nil }
        let rootClassName = parseRootClassName(from: stringTable)

        return CR2WMetadata(
            version: version,
            flags: flags,
            timestamp: timestamp,
            buildVersion: buildVersion,
            objectDataEnd: objectDataEnd,
            bufferDataEnd: bufferDataEnd,
            checksum: checksum,
            chunkCount: chunkCount,
            rootClassName: rootClassName
        )
    }

    private static func parseRootClassName(from stringTable: Data) -> String? {
        guard stringTable.first == 0,
              let end = stringTable.dropFirst().firstIndex(of: 0),
              end > 1 else {
            return nil
        }
        let bytes = stringTable[1..<end]
        guard let value = String(data: bytes, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes { bytes in
            UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        data.withUnsafeBytes { bytes in
            UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
        }
    }

    private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data? {
        var result = Data(capacity: count)
        while result.count < count {
            let chunk = try handle.read(upToCount: count - result.count) ?? Data()
            if chunk.isEmpty { break }
            result.append(chunk)
        }
        guard result.count == count else { return nil }
        return result
    }
}
