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
}
