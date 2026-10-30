import Foundation

struct CR2WResourceSerializationService: Sendable {
    let registry: ResourceSchemaRegistry
    let editingService: CR2WEditingService

    init(registry: ResourceSchemaRegistry = ResourceSchemaRegistry(),
         editingService: CR2WEditingService = CR2WEditingService()) {
        self.registry = registry
        self.editingService = editingService
    }

    func decode(export: CR2WExportRecord,
                 resourceType: String,
                 schemaVersion: Int,
                 in document: CR2WDocument) async throws -> [String: ResourceValue] {
        let payload = document.payload(for: export)
        return try await registry.decode(typeIdentifier: resourceType,
                                         version: schemaVersion,
                                         payload: payload)
    }

    func serialize(export: CR2WExportRecord,
                   resourceType: String,
                   schemaVersion: Int,
                   values: [String: ResourceValue],
                   in document: CR2WDocument) async throws {
        let originalPayload = document.payload(for: export)
        let serializedPayload = try await registry.encode(typeIdentifier: resourceType,
                                                          version: schemaVersion,
                                                          values: values,
                                                          preserving: originalPayload)
        try await editingService.replaceChunkPayload(serializedPayload,
                                                     export: export,
                                                     in: document)
    }

    func decode(variable: CR2WVariableRecord,
                in document: CR2WDocument) async throws -> [String: ResourceValue] {
        let schema = try await registry.schema(serializedTypeName: variable.typeName)
        return try schema.decode(variable.data)
    }

    func serialize(variable: CR2WVariableRecord,
                   export: CR2WExportRecord,
                   values: [String: ResourceValue],
                   in document: CR2WDocument) async throws {
        let schema = try await registry.schema(serializedTypeName: variable.typeName)
        let serializedValue = try schema.encode(values, preserving: variable.data)
        try await editingService.replaceVariablePayload(serializedValue,
                                                        variable: variable,
                                                        export: export,
                                                        in: document)
    }

    func decodeTableRecord(tableIndex: Int,
                           recordIndex: Int,
                           schemaTypeIdentifier: String,
                           schemaVersion: Int = 1,
                           in document: CR2WDocument) async throws -> [String: ResourceValue] {
        guard let recordSize = CR2WCoreSchemas.recordSize(forTableIndex: tableIndex),
              let table = document.tables.first(where: { $0.index == tableIndex }),
              recordIndex >= 0, recordIndex < Int(table.itemCount) else {
            throw CR2WDocumentError.malformed("The selected table record is not supported by the registered core schemas.")
        }
        let schema = try await registry.schema(typeIdentifier: schemaTypeIdentifier, version: schemaVersion)
        guard schema.byteCount == recordSize else {
            throw ResourceSchemaError.payloadSize(expected: recordSize, actual: schema.byteCount)
        }
        let start = Int(table.offset) + recordIndex * recordSize
        guard start >= 0, start <= document.rawData.count,
              recordSize <= document.rawData.count - start else {
            throw CR2WDocumentError.malformed("The selected table record extends beyond the resource file.")
        }
        return try schema.decode(document.rawData.subdata(in: start..<(start + recordSize)))
    }

    func serializeTableRecord(tableIndex: Int,
                              recordIndex: Int,
                              schemaTypeIdentifier: String,
                              schemaVersion: Int = 1,
                              values: [String: ResourceValue],
                              in document: CR2WDocument) async throws {
        guard let recordSize = CR2WCoreSchemas.recordSize(forTableIndex: tableIndex),
              let table = document.tables.first(where: { $0.index == tableIndex }),
              recordIndex >= 0, recordIndex < Int(table.itemCount) else {
            throw CR2WDocumentError.malformed("The selected table record is not supported by the registered core schemas.")
        }
        let schema = try await registry.schema(typeIdentifier: schemaTypeIdentifier, version: schemaVersion)
        guard schema.byteCount == recordSize else {
            throw ResourceSchemaError.payloadSize(expected: recordSize, actual: schema.byteCount)
        }
        let start = Int(table.offset) + recordIndex * recordSize
        guard start >= 0, start <= document.rawData.count,
              recordSize <= document.rawData.count - start else {
            throw CR2WDocumentError.malformed("The selected table record extends beyond the resource file.")
        }
        let original = document.rawData.subdata(in: start..<(start + recordSize))
        let serialized = try schema.encode(values, preserving: original)
        try await editingService.replaceTableRecordPayload(serialized,
                                                           tableIndex: tableIndex,
                                                           recordIndex: recordIndex,
                                                           recordSize: recordSize,
                                                           in: document)
    }
}
