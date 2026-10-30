import Foundation

enum ResourceFieldStorage: String, Codable, CaseIterable, Sendable {
    case boolean
    case signedInteger
    case unsignedInteger
    case float32
    case float64
    case utf8Fixed
    case bytes

    var fixedNumericWidth: Int? {
        switch self {
        case .boolean: return 1
        case .signedInteger, .unsignedInteger: return nil
        case .float32: return 4
        case .float64: return 8
        case .utf8Fixed, .bytes: return nil
        }
    }
}

enum ResourceByteOrder: String, Codable, Sendable {
    case littleEndian
    case bigEndian
}

struct ResourceFieldSchema: Codable, Hashable, Sendable, Identifiable {
    let name: String
    let offset: Int
    let width: Int
    let storage: ResourceFieldStorage
    var byteOrder: ResourceByteOrder = .littleEndian

    var id: String { name }
}

struct ResourceSchema: Codable, Hashable, Sendable, Identifiable {
    let typeIdentifier: String
    let version: Int
    let byteCount: Int
    let fields: [ResourceFieldSchema]

    var id: String { "\(typeIdentifier)@\(version)" }

    func validate() throws {
        guard !typeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              version >= 0,
              byteCount >= 0 else {
            throw ResourceSchemaError.invalidSchema("The type identifier, version, or payload size is invalid.")
        }

        var names = Set<String>()
        var occupied: [(Range<Int>, String)] = []
        for field in fields {
            guard !field.name.isEmpty, names.insert(field.name).inserted else {
                throw ResourceSchemaError.invalidSchema("Field names must be non-empty and unique.")
            }
            guard field.offset >= 0, field.width > 0,
                  field.offset <= byteCount,
                  field.width <= byteCount - field.offset else {
                throw ResourceSchemaError.invalidSchema("Field \(field.name) lies outside the declared payload.")
            }
            if let numericWidth = field.storage.fixedNumericWidth, numericWidth != field.width {
                throw ResourceSchemaError.invalidSchema("Field \(field.name) must be \(numericWidth) bytes wide.")
            }
            if field.storage == .signedInteger || field.storage == .unsignedInteger {
                guard [1, 2, 4, 8].contains(field.width) else {
                    throw ResourceSchemaError.invalidSchema("Integer field \(field.name) must be 1, 2, 4, or 8 bytes wide.")
                }
            }
            let range = field.offset..<(field.offset + field.width)
            if let prior = occupied.first(where: { $0.0.overlaps(range) }) {
                throw ResourceSchemaError.invalidSchema("Fields \(prior.1) and \(field.name) overlap.")
            }
            occupied.append((range, field.name))
        }
    }

    func decode(_ payload: Data) throws -> [String: ResourceValue] {
        try validate()
        guard payload.count == byteCount else {
            throw ResourceSchemaError.payloadSize(expected: byteCount, actual: payload.count)
        }
        var result: [String: ResourceValue] = [:]
        for field in fields {
            let bytes = payload.subdata(in: field.offset..<(field.offset + field.width))
            result[field.name] = try decode(bytes, using: field)
        }
        return result
    }

    func encode(_ values: [String: ResourceValue], preserving payload: Data) throws -> Data {
        try validate()
        guard payload.count == byteCount else {
            throw ResourceSchemaError.payloadSize(expected: byteCount, actual: payload.count)
        }
        let fieldNames = Set(fields.map(\.name))
        if let unknown = values.keys.first(where: { !fieldNames.contains($0) }) {
            throw ResourceSchemaError.unknownField(unknown)
        }

        var output = payload
        for field in fields {
            guard let value = values[field.name] else { continue }
            let bytes = try encode(value, using: field)
            guard bytes.count == field.width else {
                throw ResourceSchemaError.valueSize(field: field.name, expected: field.width, actual: bytes.count)
            }
            output.replaceSubrange(field.offset..<(field.offset + field.width), with: bytes)
        }
        return output
    }

    private func decode(_ bytes: Data, using field: ResourceFieldSchema) throws -> ResourceValue {
        switch field.storage {
        case .boolean:
            guard let byte = bytes.first, byte == 0 || byte == 1 else {
                throw ResourceSchemaError.invalidValue(field.name)
            }
            return .boolean(byte == 1)
        case .signedInteger:
            return .signed(try bytes.signedInteger(order: field.byteOrder))
        case .unsignedInteger:
            return .unsigned(try bytes.unsignedInteger(order: field.byteOrder))
        case .float32:
            let bits = try bytes.unsignedInteger(order: field.byteOrder, as: UInt32.self)
            let value = Float(bitPattern: UInt32(bits))
            guard value.isFinite else { throw ResourceSchemaError.invalidValue(field.name) }
            return .floating(Double(value))
        case .float64:
            let bits = try bytes.unsignedInteger(order: field.byteOrder, as: UInt64.self)
            let value = Double(bitPattern: bits)
            guard value.isFinite else { throw ResourceSchemaError.invalidValue(field.name) }
            return .floating(value)
        case .utf8Fixed:
            let content = bytes.prefix { $0 != 0 }
            guard let value = String(data: Data(content), encoding: .utf8) else {
                throw ResourceSchemaError.invalidValue(field.name)
            }
            return .string(value)
        case .bytes:
            return .data(bytes)
        }
    }

    private func encode(_ value: ResourceValue, using field: ResourceFieldSchema) throws -> Data {
        switch (field.storage, value) {
        case let (.boolean, .boolean(value)):
            return Data([value ? 1 : 0])
        case let (.signedInteger, .signed(value)):
            return try Data.signedInteger(value, width: field.width, order: field.byteOrder)
        case let (.unsignedInteger, .unsigned(value)):
            return try Data.unsignedInteger(value, width: field.width, order: field.byteOrder)
        case let (.float32, .floating(value)):
            guard value.isFinite else {
                throw ResourceSchemaError.invalidValue(field.name)
            }
            let float = Float(value)
            guard float.isFinite else { throw ResourceSchemaError.invalidValue(field.name) }
            return try Data.unsignedInteger(UInt64(float.bitPattern), width: 4, order: field.byteOrder)
        case let (.float64, .floating(value)):
            guard value.isFinite else { throw ResourceSchemaError.invalidValue(field.name) }
            return try Data.unsignedInteger(value.bitPattern, width: 8, order: field.byteOrder)
        case let (.utf8Fixed, .string(value)):
            guard !value.utf8.contains(0), value.utf8.count <= field.width else {
                throw ResourceSchemaError.valueSize(field: field.name, expected: field.width, actual: value.utf8.count)
            }
            var bytes = Data(value.utf8)
            bytes.append(contentsOf: repeatElement(0, count: field.width - bytes.count))
            return bytes
        case let (.bytes, .data(value)):
            return value
        default:
            throw ResourceSchemaError.typeMismatch(field: field.name, expected: field.storage)
        }
    }
}

enum ResourceValue: Codable, Hashable, Sendable {
    case boolean(Bool)
    case signed(Int64)
    case unsigned(UInt64)
    case floating(Double)
    case string(String)
    case data(Data)
}

actor ResourceSchemaRegistry {
    private var schemas: [String: ResourceSchema] = [:]

    func register(_ schema: ResourceSchema, replacingExisting: Bool = false) throws {
        try schema.validate()
        guard replacingExisting || schemas[schema.id] == nil else {
            throw ResourceSchemaError.duplicateSchema(schema.id)
        }
        schemas[schema.id] = schema
    }

    func remove(typeIdentifier: String, version: Int) {
        schemas["\(typeIdentifier)@\(version)"] = nil
    }

    func schema(typeIdentifier: String, version: Int) throws -> ResourceSchema {
        let identifier = "\(typeIdentifier)@\(version)"
        guard let schema = schemas[identifier] else {
            throw ResourceSchemaError.schemaNotFound(identifier)
        }
        return schema
    }

    func decode(typeIdentifier: String, version: Int, payload: Data) throws -> [String: ResourceValue] {
        try schema(typeIdentifier: typeIdentifier, version: version).decode(payload)
    }

    func encode(typeIdentifier: String,
                version: Int,
                values: [String: ResourceValue],
                preserving payload: Data) throws -> Data {
        try schema(typeIdentifier: typeIdentifier, version: version).encode(values, preserving: payload)
    }

    func registeredSchemas() -> [ResourceSchema] {
        schemas.values.sorted {
            ($0.typeIdentifier, $0.version) < ($1.typeIdentifier, $1.version)
        }
    }
}

enum ResourceSchemaError: LocalizedError {
    case invalidSchema(String)
    case duplicateSchema(String)
    case schemaNotFound(String)
    case payloadSize(expected: Int, actual: Int)
    case valueSize(field: String, expected: Int, actual: Int)
    case unknownField(String)
    case invalidValue(String)
    case typeMismatch(field: String, expected: ResourceFieldStorage)
    case integerOutOfRange

    var errorDescription: String? {
        switch self {
        case let .invalidSchema(message): return "Invalid resource schema: \(message)"
        case let .duplicateSchema(identifier): return "Schema \(identifier) is already registered."
        case let .schemaNotFound(identifier): return "No schema is registered for \(identifier)."
        case let .payloadSize(expected, actual): return "The payload has \(actual) bytes; the schema requires \(expected)."
        case let .valueSize(field, expected, actual): return "Field \(field) has \(actual) bytes; it requires \(expected)."
        case let .unknownField(field): return "The schema has no field named \(field)."
        case let .invalidValue(field): return "Field \(field) contains an invalid serialized value."
        case let .typeMismatch(field, expected): return "Field \(field) requires a value compatible with \(expected.rawValue)."
        case .integerOutOfRange: return "The integer does not fit the registered field width."
        }
    }
}

private extension Data {
    func unsignedInteger<T: FixedWidthInteger>(order: ResourceByteOrder, as: T.Type = T.self) throws -> T {
        guard count == MemoryLayout<T>.size else { throw ResourceSchemaError.integerOutOfRange }
        var value: T = 0
        for index in 0..<count {
            let sourceIndex = order == .littleEndian ? index : count - index - 1
            value |= T(self[sourceIndex]) << (index * 8)
        }
        return value
    }

    func signedInteger(order: ResourceByteOrder) throws -> Int64 {
        var unsigned: UInt64 = 0
        for index in 0..<count {
            let sourceIndex = order == .littleEndian ? index : count - index - 1
            unsigned |= UInt64(self[sourceIndex]) << (index * 8)
        }
        switch count {
        case 1: return Int64(Int8(bitPattern: UInt8(truncatingIfNeeded: unsigned)))
        case 2: return Int64(Int16(bitPattern: UInt16(truncatingIfNeeded: unsigned)))
        case 4: return Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: unsigned)))
        case 8: return Int64(bitPattern: unsigned)
        default: throw ResourceSchemaError.integerOutOfRange
        }
    }

    static func unsignedInteger(_ value: UInt64, width: Int, order: ResourceByteOrder) throws -> Data {
        guard [1, 2, 4, 8].contains(width), width == 8 || value < (UInt64(1) << (width * 8)) else {
            throw ResourceSchemaError.integerOutOfRange
        }
        var result = Data(repeating: 0, count: width)
        for index in 0..<width {
            let destinationIndex = order == .littleEndian ? index : width - index - 1
            result[destinationIndex] = UInt8(truncatingIfNeeded: value >> (index * 8))
        }
        return result
    }

    static func signedInteger(_ value: Int64, width: Int, order: ResourceByteOrder) throws -> Data {
        guard [1, 2, 4, 8].contains(width) else { throw ResourceSchemaError.integerOutOfRange }
        if width < 8 {
            let bits = width * 8
            let minimum = -(Int64(1) << (bits - 1))
            let maximum = (Int64(1) << (bits - 1)) - 1
            guard (minimum...maximum).contains(value) else { throw ResourceSchemaError.integerOutOfRange }
        }
        var result = Data(repeating: 0, count: width)
        let bits = UInt64(bitPattern: value)
        for index in 0..<width {
            let destinationIndex = order == .littleEndian ? index : width - index - 1
            result[destinationIndex] = UInt8(truncatingIfNeeded: bits >> (index * 8))
        }
        return result
    }
}
