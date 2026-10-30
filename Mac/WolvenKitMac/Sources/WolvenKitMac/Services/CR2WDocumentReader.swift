import Foundation

struct CR2WDocumentReader: Sendable {
    private static let magic: UInt32 = 0x57325243
    private static let headerLength = 160
    private static let maximumTableEntries: UInt32 = 8_000_000

    func readDocument(at url: URL) async throws -> CR2WDocument {
        try await Task.detached(priority: .userInitiated) {
            try Self.readSynchronously(at: url)
        }.value
    }

    private static func readSynchronously(at url: URL) throws -> CR2WDocument {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count >= headerLength else { throw CR2WDocumentError.notResource }
        var cursor = ResourceCursor(data: data)

        guard try cursor.readUInt32() == magic else { throw CR2WDocumentError.notResource }
        let version = try cursor.readUInt32()
        guard (163...195).contains(version) else { throw CR2WDocumentError.unsupportedVersion(version) }
        let flags = try cursor.readUInt32()
        let timestamp = try cursor.readUInt64()
        let buildVersion = try cursor.readUInt32()
        let objectDataEnd = try cursor.readUInt32()
        let bufferDataEnd = try cursor.readUInt32()
        let checksum = try cursor.readUInt32()
        let chunkCount = try cursor.readUInt32()

        var tables: [CR2WTableDescriptor] = []
        for index in 0..<10 {
            tables.append(CR2WTableDescriptor(
                index: index,
                offset: try cursor.readUInt32(),
                itemCount: try cursor.readUInt32(),
                crc32: try cursor.readUInt32()
            ))
        }

        guard cursor.offset == headerLength else {
            throw CR2WDocumentError.malformed("The fixed header has an unexpected size.")
        }

        let stringBytes = try tableData(tables[0], recordSize: 1, in: data)
        let stringMap = decodeStrings(stringBytes)
        let nameData = try tableData(tables[1], recordSize: 8, in: data)
        let importData = try tableData(tables[2], recordSize: 8, in: data)
        let propertyData = try tableData(tables[3], recordSize: 16, in: data)
        let exportData = try tableData(tables[4], recordSize: 24, in: data)
        let bufferData = try tableData(tables[5], recordSize: 24, in: data)
        let embeddedData = try tableData(tables[6], recordSize: 16, in: data)
        try verifyTableCRC(tables[0], bytes: stringBytes)
        try verifyTableCRC(tables[1], bytes: nameData)
        try verifyTableCRC(tables[2], bytes: importData)
        try verifyTableCRC(tables[3], bytes: propertyData)
        try verifyTableCRC(tables[4], bytes: exportData)
        try verifyTableCRC(tables[5], bytes: bufferData)
        try verifyTableCRC(tables[6], bytes: embeddedData)

        let names = try parseNames(nameData, strings: stringMap)
        let imports = try parseImports(importData, strings: stringMap, names: names)
        let properties = try parseProperties(propertyData, names: names)
        let rawExports = try parseExports(exportData, names: names, fileSize: data.count)
        let exports = try rawExports.map { export in
            CR2WExportRecord(
                index: export.index,
                className: export.className,
                objectFlags: export.objectFlags,
                parentID: export.parentID,
                dataSize: export.dataSize,
                dataOffset: export.dataOffset,
                template: export.template,
                crc32: export.crc32,
                variables: try parseVariables(for: export, names: names, fileData: data)
            )
        }
        let buffers = try parseBuffers(bufferData, fileSize: data.count)
        let embedded = try parseEmbedded(embeddedData)

        return CR2WDocument(
            url: url.standardizedFileURL,
            version: version,
            flags: flags,
            timestamp: timestamp,
            buildVersion: buildVersion,
            objectDataEnd: objectDataEnd,
            bufferDataEnd: bufferDataEnd,
            checksum: checksum,
            chunkCount: chunkCount,
            tables: tables,
            names: names,
            imports: imports,
            properties: properties,
            exports: exports,
            buffers: buffers,
            embedded: embedded,
            rawData: data
        )
    }

    private static func tableData(_ table: CR2WTableDescriptor, recordSize: UInt32, in data: Data) throws -> Data {
        guard table.itemCount <= maximumTableEntries else {
            throw CR2WDocumentError.malformed("Table \(table.index) contains too many entries.")
        }
        let length = UInt64(table.itemCount) * UInt64(recordSize)
        guard UInt64(table.offset) <= UInt64(data.count),
              length <= UInt64(data.count) - UInt64(table.offset) else {
            throw CR2WDocumentError.malformed("Table \(table.index) extends beyond the file.")
        }
        let start = Int(table.offset)
        return data.subdata(in: start..<(start + Int(length)))
    }

    private static func decodeStrings(_ bytes: Data) -> [UInt32: String] {
        guard !bytes.isEmpty else { return [:] }
        var result: [UInt32: String] = [:]
        var start = 0
        for index in 0..<bytes.count where bytes[index] == 0 {
            let value = String(data: bytes[start..<index], encoding: .utf8) ?? String(decoding: bytes[start..<index], as: UTF8.self)
            result[UInt32(start)] = value.isEmpty ? "None" : value
            start = index + 1
        }
        if start < bytes.count {
            let value = String(data: bytes[start..<bytes.count], encoding: .utf8) ?? String(decoding: bytes[start..<bytes.count], as: UTF8.self)
            result[UInt32(start)] = value
        }
        return result
    }

    private static func verifyTableCRC(_ table: CR2WTableDescriptor, bytes: Data) throws {
        guard table.itemCount > 0, table.crc32 != crc32(bytes) else { return }
        throw CR2WDocumentError.malformed("Table \(table.index) failed its checksum validation.")
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1
            }
        }
        return ~crc
    }

    private static func parseNames(_ bytes: Data, strings: [UInt32: String]) throws -> [CR2WNameRecord] {
        var cursor = ResourceCursor(data: bytes)
        var result: [CR2WNameRecord] = []
        while cursor.offset < bytes.count {
            let offset = try cursor.readUInt32()
            let hash = try cursor.readUInt32()
            guard let name = strings[offset] else {
                throw CR2WDocumentError.malformed("A name references a missing string-table offset.")
            }
            result.append(CR2WNameRecord(index: result.count, value: name, hash: hash))
        }
        return result
    }

    private static func parseImports(_ bytes: Data, strings: [UInt32: String], names: [CR2WNameRecord]) throws -> [CR2WImportRecord] {
        var cursor = ResourceCursor(data: bytes)
        var result: [CR2WImportRecord] = []
        while cursor.offset < bytes.count {
            let pathOffset = try cursor.readUInt32()
            let classNameIndex = Int(try cursor.readUInt16())
            let flags = try cursor.readUInt16()
            guard let path = strings[pathOffset] else {
                throw CR2WDocumentError.malformed("An import references a missing path string.")
            }
            result.append(CR2WImportRecord(
                index: result.count,
                depotPath: path,
                className: names[safe: classNameIndex]?.value ?? "Unknown",
                flags: flags
            ))
        }
        return result
    }

    private static func parseProperties(_ bytes: Data, names: [CR2WNameRecord]) throws -> [CR2WPropertyRecord] {
        var cursor = ResourceCursor(data: bytes)
        var result: [CR2WPropertyRecord] = []
        while cursor.offset < bytes.count {
            let classNameIndex = Int(try cursor.readUInt16())
            let classFlags = try cursor.readUInt16()
            let propertyNameIndex = Int(try cursor.readUInt16())
            let propertyFlags = try cursor.readUInt16()
            let hash = try cursor.readUInt64()
            result.append(CR2WPropertyRecord(
                index: result.count,
                className: names[safe: classNameIndex]?.value ?? "Unknown",
                propertyName: names[safe: propertyNameIndex]?.value ?? "Unknown",
                classFlags: classFlags,
                propertyFlags: propertyFlags,
                hash: hash
            ))
        }
        return result
    }

    private static func parseExports(_ bytes: Data, names: [CR2WNameRecord], fileSize: Int) throws -> [CR2WExportRecord] {
        var cursor = ResourceCursor(data: bytes)
        var result: [CR2WExportRecord] = []
        while cursor.offset < bytes.count {
            let classNameIndex = Int(try cursor.readUInt16())
            let objectFlags = try cursor.readUInt16()
            let parentID = try cursor.readUInt32()
            let dataSize = try cursor.readUInt32()
            let dataOffset = try cursor.readUInt32()
            let template = try cursor.readUInt32()
            let crc32 = try cursor.readUInt32()
            guard UInt64(dataOffset) <= UInt64(fileSize), UInt64(dataSize) <= UInt64(fileSize) - UInt64(dataOffset) else {
                throw CR2WDocumentError.malformed("Export \(result.count) points outside the file.")
            }
            result.append(CR2WExportRecord(
                index: result.count,
                className: names[safe: classNameIndex]?.value ?? "Unknown",
                objectFlags: objectFlags,
                parentID: parentID,
                dataSize: dataSize,
                dataOffset: dataOffset,
                template: template,
                crc32: crc32,
                variables: []
            ))
        }
        return result
    }

    private static func parseVariables(for export: CR2WExportRecord, names: [CR2WNameRecord], fileData: Data) throws -> [CR2WVariableRecord] {
        guard export.dataSize > 0 else { return [] }
        let start = Int(export.dataOffset)
        let length = Int(export.dataSize)
        var cursor = ResourceCursor(data: fileData.subdata(in: start..<(start + length)))
        guard try cursor.readUInt8() == 0 else {
            throw CR2WDocumentError.malformed("Chunk \(export.index) does not begin with the required class marker.")
        }

        var variables: [CR2WVariableRecord] = []
        while cursor.offset < cursor.data.count {
            guard cursor.offset + 2 <= cursor.data.count else {
                throw CR2WDocumentError.malformed("Chunk \(export.index) ends inside a property index.")
            }
            let propertyIndex = Int(try cursor.readUInt16())
            if propertyIndex == 0 { return variables }
            guard cursor.offset + 6 <= cursor.data.count else {
                throw CR2WDocumentError.malformed("Chunk \(export.index) ends inside a property header.")
            }
            let typeIndex = Int(try cursor.readUInt16())
            let encodedSize = try cursor.readUInt32()
            guard encodedSize >= 4 else {
                throw CR2WDocumentError.malformed("Chunk \(export.index) contains a property with an invalid size.")
            }
            let payloadSize = Int(encodedSize - 4)
            let relativeDataOffset = cursor.offset
            let rawValue = try cursor.readData(count: payloadSize)
            variables.append(CR2WVariableRecord(
                index: variables.count,
                propertyName: names[safe: propertyIndex]?.value ?? "Unknown",
                typeName: names[safe: typeIndex]?.value ?? "Unknown",
                dataOffset: UInt32(start + relativeDataOffset),
                data: rawValue,
                scalarKind: CR2WScalarKind.resolve(
                    typeName: names[safe: typeIndex]?.value ?? "Unknown",
                    byteCount: rawValue.count
                )
            ))
        }
        return variables
    }

    private static func parseBuffers(_ bytes: Data, fileSize: Int) throws -> [CR2WBufferRecord] {
        var cursor = ResourceCursor(data: bytes)
        var result: [CR2WBufferRecord] = []
        while cursor.offset < bytes.count {
            let flags = try cursor.readUInt32()
            let bufferIndex = try cursor.readUInt32()
            let offset = try cursor.readUInt32()
            let compressedSize = try cursor.readUInt32()
            let uncompressedSize = try cursor.readUInt32()
            let crc32 = try cursor.readUInt32()
            guard UInt64(offset) <= UInt64(fileSize), UInt64(compressedSize) <= UInt64(fileSize) - UInt64(offset) else {
                throw CR2WDocumentError.malformed("Buffer \(result.count) points outside the file.")
            }
            result.append(CR2WBufferRecord(
                index: result.count,
                flags: flags,
                bufferIndex: bufferIndex,
                offset: offset,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                crc32: crc32
            ))
        }
        return result
    }

    private static func parseEmbedded(_ bytes: Data) throws -> [CR2WEmbeddedRecord] {
        var cursor = ResourceCursor(data: bytes)
        var result: [CR2WEmbeddedRecord] = []
        while cursor.offset < bytes.count {
            result.append(CR2WEmbeddedRecord(
                index: result.count,
                importIndex: try cursor.readUInt32(),
                chunkIndex: try cursor.readUInt32(),
                pathHash: try cursor.readUInt64()
            ))
        }
        return result
    }
}

private struct ResourceCursor {
    let data: Data
    var offset = 0

    mutating func readUInt16() throws -> UInt16 { try readInteger(UInt16.self) }
    mutating func readUInt32() throws -> UInt32 { try readInteger(UInt32.self) }
    mutating func readUInt64() throws -> UInt64 { try readInteger(UInt64.self) }

    mutating func readUInt8() throws -> UInt8 {
        guard offset < data.count else { throw CR2WDocumentError.malformed("A chunk is truncated.") }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, offset <= data.count, count <= data.count - offset else {
            throw CR2WDocumentError.malformed("A variable payload is truncated.")
        }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    private mutating func readInteger<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard offset <= data.count, size <= data.count - offset else {
            throw CR2WDocumentError.malformed("A table record is truncated.")
        }
        defer { offset += size }
        let raw = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        return T(littleEndian: raw)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}
