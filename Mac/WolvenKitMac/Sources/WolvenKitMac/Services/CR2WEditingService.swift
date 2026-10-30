import Foundation

struct CR2WEditingService: Sendable {
    func replaceChunkPayload(_ payload: Data, export: CR2WExportRecord, in document: CR2WDocument) async throws {
        try await Task.detached(priority: .userInitiated) {
            try Self.replaceSynchronously(payload, at: Int(export.dataOffset), expectedSize: Int(export.dataSize), export: export, in: document)
        }.value
    }

    func replaceVariablePayload(_ payload: Data, variable: CR2WVariableRecord, export: CR2WExportRecord, in document: CR2WDocument) async throws {
        try await Task.detached(priority: .userInitiated) {
            try Self.replaceSynchronously(payload, at: Int(variable.dataOffset), expectedSize: variable.data.count, export: export, in: document)
        }.value
    }

    func replaceTableRecordPayload(_ payload: Data,
                                   tableIndex: Int,
                                   recordIndex: Int,
                                   recordSize: Int,
                                   in document: CR2WDocument) async throws {
        try await Task.detached(priority: .userInitiated) {
            try Self.replaceTableRecordSynchronously(payload,
                                                     tableIndex: tableIndex,
                                                     recordIndex: recordIndex,
                                                     recordSize: recordSize,
                                                     in: document)
        }.value
    }

    private static func replaceSynchronously(_ payload: Data, at offset: Int, expectedSize: Int, export: CR2WExportRecord, in document: CR2WDocument) throws {
        let chunkRange = Int(export.dataOffset)..<(Int(export.dataOffset) + Int(export.dataSize))
        guard payload.count == expectedSize,
              offset >= chunkRange.lowerBound,
              offset <= chunkRange.upperBound,
              payload.count <= chunkRange.upperBound - offset else {
            throw CR2WDocumentError.changedPayloadSize
        }
        guard let currentData = try? Data(contentsOf: document.url, options: [.mappedIfSafe]), currentData == document.rawData else {
            throw CR2WEditingError.fileChanged
        }

        var edited = document.rawData
        edited.replaceSubrange(offset..<(offset + payload.count), with: payload)

        guard let exportsTable = document.tables.first(where: { $0.index == 4 }) else {
            throw CR2WDocumentError.malformed("The export table is missing.")
        }
        let exportCRCOffset = Int(exportsTable.offset) + export.index * 24 + 20
        writeUInt32(crc32(edited.subdata(in: chunkRange)), into: &edited, at: exportCRCOffset)

        let updatedExportsRange = Int(exportsTable.offset)..<(Int(exportsTable.offset) + Int(exportsTable.itemCount) * 24)
        let updatedExportsCRC = crc32(edited.subdata(in: updatedExportsRange))
        let tableCRCOffset = 40 + exportsTable.index * 12 + 8
        writeUInt32(updatedExportsCRC, into: &edited, at: tableCRCOffset)

        writeUInt32(0xDEADBEEF, into: &edited, at: 32)
        let headerCRC = crc32(edited.subdata(in: 0..<160))
        writeUInt32(headerCRC, into: &edited, at: 32)

        try writeAtomically(edited, to: document.url)
    }

    private static func replaceTableRecordSynchronously(_ payload: Data,
                                                        tableIndex: Int,
                                                        recordIndex: Int,
                                                        recordSize: Int,
                                                        in document: CR2WDocument) throws {
        guard tableIndex >= 0, tableIndex < 10, recordIndex >= 0, recordSize > 0,
              CR2WCoreSchemas.recordSize(forTableIndex: tableIndex) == recordSize,
              let table = document.tables.first(where: { $0.index == tableIndex }),
              recordIndex < Int(table.itemCount),
              payload.count == recordSize else {
            throw CR2WDocumentError.malformed("The selected table record does not match its registered schema.")
        }
        let tableLength = Int(table.itemCount) * recordSize
        let tableStart = Int(table.offset)
        guard tableStart >= 0, tableStart <= document.rawData.count,
              tableLength <= document.rawData.count - tableStart else {
            throw CR2WDocumentError.malformed("The selected table extends beyond the resource file.")
        }
        let recordStart = tableStart + recordIndex * recordSize
        guard let currentData = try? Data(contentsOf: document.url, options: [.mappedIfSafe]), currentData == document.rawData else {
            throw CR2WEditingError.fileChanged
        }

        var edited = document.rawData
        edited.replaceSubrange(recordStart..<(recordStart + recordSize), with: payload)
        let tableCRC = crc32(edited.subdata(in: tableStart..<(tableStart + tableLength)))
        writeUInt32(tableCRC, into: &edited, at: 40 + tableIndex * 12 + 8)
        writeUInt32(0xDEADBEEF, into: &edited, at: 32)
        let headerCRC = crc32(edited.subdata(in: 0..<160))
        writeUInt32(headerCRC, into: &edited, at: 32)
        try writeAtomically(edited, to: document.url)
    }

    private static func writeAtomically(_ data: Data, to destination: URL) throws {
        let temporaryURL = destination.deletingLastPathComponent()
            .appendingPathComponent(".resource-\(UUID().uuidString).tmp")
        try data.write(to: temporaryURL, options: .atomic)
        do {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporaryURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private static func writeUInt32(_ value: UInt32, into data: inout Data, at offset: Int) {
        guard offset >= 0, offset + 4 <= data.count else { return }
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.replaceSubrange(offset..<(offset + 4), with: bytes)
        }
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
}

private enum CR2WEditingError: LocalizedError {
    case fileChanged

    var errorDescription: String? {
        "This resource changed on disk after it was opened. Reopen it before saving edits."
    }
}
