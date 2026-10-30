import Foundation

struct CR2WTableDescriptor: Hashable, Sendable {
    let index: Int
    let offset: UInt32
    let itemCount: UInt32
    let crc32: UInt32
}

struct CR2WNameRecord: Hashable, Sendable, Identifiable {
    let index: Int
    let value: String
    let hash: UInt32

    var id: Int { index }
}

struct CR2WImportRecord: Hashable, Sendable, Identifiable {
    let index: Int
    let depotPath: String
    let className: String
    let flags: UInt16

    var id: Int { index }
}

struct CR2WPropertyRecord: Hashable, Sendable, Identifiable {
    let index: Int
    let className: String
    let propertyName: String
    let classFlags: UInt16
    let propertyFlags: UInt16
    let hash: UInt64

    var id: Int { index }
}

struct CR2WExportRecord: Hashable, Sendable, Identifiable {
    let index: Int
    let className: String
    let objectFlags: UInt16
    let parentID: UInt32
    let dataSize: UInt32
    let dataOffset: UInt32
    let template: UInt32
    let crc32: UInt32
    let variables: [CR2WVariableRecord]

    var id: Int { index }
}

struct CR2WVariableRecord: Hashable, Sendable, Identifiable {
    let index: Int
    let propertyName: String
    let typeName: String
    let dataOffset: UInt32
    let data: Data
    let scalarKind: CR2WScalarKind?

    var id: Int { index }
    var preview: String {
        let bytes = data.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
        return data.count > 16 ? bytes + " …" : bytes
    }
}

enum CR2WScalarKind: String, Hashable, Sendable {
    case boolean
    case signed8
    case unsigned8
    case signed16
    case unsigned16
    case signed32
    case unsigned32
    case signed64
    case unsigned64
    case float32
    case float64

    static func resolve(typeName: String, byteCount: Int) -> CR2WScalarKind? {
        let normalized = typeName.lowercased()
        let candidate: CR2WScalarKind
        switch normalized {
        case "bool": candidate = .boolean
        case "int8": candidate = .signed8
        case "uint8": candidate = .unsigned8
        case "int16": candidate = .signed16
        case "uint16": candidate = .unsigned16
        case "int32": candidate = .signed32
        case "uint32": candidate = .unsigned32
        case "int64": candidate = .signed64
        case "uint64": candidate = .unsigned64
        case "float": candidate = .float32
        case "double": candidate = .float64
        default: return nil
        }
        return candidate.byteCount == byteCount ? candidate : nil
    }

    var byteCount: Int {
        switch self {
        case .boolean, .signed8, .unsigned8: return 1
        case .signed16, .unsigned16: return 2
        case .signed32, .unsigned32, .float32: return 4
        case .signed64, .unsigned64, .float64: return 8
        }
    }

    func decode(_ data: Data) -> String? {
        guard data.count == byteCount else { return nil }
        switch self {
        case .boolean:
            return data.first.map { $0 == 0 ? "false" : "true" }
        case .signed8:
            return data.first.map { String(Int8(bitPattern: $0)) }
        case .unsigned8:
            return data.first.map { String($0) }
        case .signed16:
            return data.integer(at: 0, as: Int16.self).map { String($0) }
        case .unsigned16:
            return data.integer(at: 0, as: UInt16.self).map { String($0) }
        case .signed32:
            return data.integer(at: 0, as: Int32.self).map { String($0) }
        case .unsigned32:
            return data.integer(at: 0, as: UInt32.self).map { String($0) }
        case .signed64:
            return data.integer(at: 0, as: Int64.self).map { String($0) }
        case .unsigned64:
            return data.integer(at: 0, as: UInt64.self).map { String($0) }
        case .float32:
            guard let bits = data.integer(at: 0, as: UInt32.self) else { return nil }
            let value = Float(bitPattern: bits)
            return value.isFinite ? String(value) : nil
        case .float64:
            guard let bits = data.integer(at: 0, as: UInt64.self) else { return nil }
            let value = Double(bitPattern: bits)
            return value.isFinite ? String(value) : nil
        }
    }

    func encode(_ value: String) throws -> Data {
        var data = Data()
        switch self {
        case .boolean:
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1": data.append(1)
            case "false", "0": data.append(0)
            default: throw CR2WScalarError.invalidValue
            }
        case .signed8:
            guard let parsed = Int8(value) else { throw CR2WScalarError.invalidValue }
            data.append(UInt8(bitPattern: parsed))
        case .unsigned8:
            guard let parsed = UInt8(value) else { throw CR2WScalarError.invalidValue }
            data.append(parsed)
        case .signed16:
            guard let parsed = Int16(value) else { throw CR2WScalarError.invalidValue }
            data.appendLittleEndian(parsed)
        case .unsigned16:
            guard let parsed = UInt16(value) else { throw CR2WScalarError.invalidValue }
            data.appendLittleEndian(parsed)
        case .signed32:
            guard let parsed = Int32(value) else { throw CR2WScalarError.invalidValue }
            data.appendLittleEndian(parsed)
        case .unsigned32:
            guard let parsed = UInt32(value) else { throw CR2WScalarError.invalidValue }
            data.appendLittleEndian(parsed)
        case .signed64:
            guard let parsed = Int64(value) else { throw CR2WScalarError.invalidValue }
            data.appendLittleEndian(parsed)
        case .unsigned64:
            guard let parsed = UInt64(value) else { throw CR2WScalarError.invalidValue }
            data.appendLittleEndian(parsed)
        case .float32:
            guard let parsed = Float(value), parsed.isFinite else { throw CR2WScalarError.invalidValue }
            data.appendLittleEndian(parsed.bitPattern)
        case .float64:
            guard let parsed = Double(value), parsed.isFinite else { throw CR2WScalarError.invalidValue }
            data.appendLittleEndian(parsed.bitPattern)
        }
        return data
    }
}

enum CR2WScalarError: LocalizedError {
    case invalidValue

    var errorDescription: String? {
        "Enter a valid value within this property's numeric range."
    }
}

struct CR2WEditSelection: Identifiable {
    let export: CR2WExportRecord
    let variable: CR2WVariableRecord?

    var id: String { "\(export.index)-\(variable?.index ?? -1)" }
}

struct CR2WBufferRecord: Hashable, Sendable, Identifiable {
    let index: Int
    let flags: UInt32
    let bufferIndex: UInt32
    let offset: UInt32
    let compressedSize: UInt32
    let uncompressedSize: UInt32
    let crc32: UInt32

    var id: Int { index }
}

struct CR2WEmbeddedRecord: Hashable, Sendable, Identifiable {
    let index: Int
    let importIndex: UInt32
    let chunkIndex: UInt32
    let pathHash: UInt64

    var id: Int { index }
}

struct CR2WDocument: Hashable, Sendable {
    let url: URL
    let version: UInt32
    let flags: UInt32
    let timestamp: UInt64
    let buildVersion: UInt32
    let objectDataEnd: UInt32
    let bufferDataEnd: UInt32
    let checksum: UInt32
    let chunkCount: UInt32
    let tables: [CR2WTableDescriptor]
    let names: [CR2WNameRecord]
    let imports: [CR2WImportRecord]
    let properties: [CR2WPropertyRecord]
    let exports: [CR2WExportRecord]
    let buffers: [CR2WBufferRecord]
    let embedded: [CR2WEmbeddedRecord]
    let rawData: Data

    var rootClassName: String? { exports.first?.className }

    func payload(for export: CR2WExportRecord) -> Data {
        let start = Int(export.dataOffset)
        let end = start + Int(export.dataSize)
        guard start >= 0, end <= rawData.count, start <= end else { return Data() }
        return rawData.subdata(in: start..<end)
    }
}

private extension Data {
    func integer<T: FixedWidthInteger>(at offset: Int, as type: T.Type) -> T? {
        guard offset >= 0, offset <= count, MemoryLayout<T>.size <= count - offset else { return nil }
        let raw = withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        return T(littleEndian: raw)
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}

enum CR2WDocumentError: LocalizedError {
    case notResource
    case unsupportedVersion(UInt32)
    case malformed(String)
    case changedPayloadSize

    var errorDescription: String? {
        switch self {
        case .notResource:
            return "The selected file is not a supported resource file."
        case .unsupportedVersion(let version):
            return "Resource format version \(version) is outside the supported range 163–195."
        case .malformed(let detail):
            return "The resource structure is invalid: \(detail)"
        case .changedPayloadSize:
            return "A chunk replacement must keep the original byte length so table offsets remain valid."
        }
    }
}
