import Foundation
import XCTest
@testable import WolvenKitMac

final class KrakenDecoderTests: XCTestCase {
    func testDecodesStoredBlock() throws {
        let expected = Data("native stored Kraken block".utf8)
        let decoded = try KrakenDecoder().decode(frameWithStoredBlock(expected))
        XCTAssertEqual(decoded, expected)
    }

    func testDecodesRepeatedByteBlock() throws {
        let expected = Data(repeating: 0xA7, count: 19)
        let decoded = try KrakenDecoder().decode(frameWithRepeatedByte(0xA7, outputCount: expected.count))
        XCTAssertEqual(decoded, expected)
    }

    func testRejectsEntropyBlockWithExplicitError() {
        var frame = frameHeader(outputCount: 1)
        frame.append(contentsOf: [0x0C, 0x06, 0x00, 0x00, 0x00, 0x00])

        XCTAssertThrowsError(try KrakenDecoder().decode(frame)) { error in
            guard case KrakenDecodingError.unsupportedEntropyBlock = error else {
                return XCTFail("Expected an explicit unsupported entropy block error, got \(error).")
            }
        }
    }

    func testRejectsOutputSizeLimitBeforeAllocation() {
        let frame = frameHeader(outputCount: 0x400)
        let decoder = KrakenDecoder(limits: .init(maximumOutputSize: 32, maximumInputSize: 64))

        XCTAssertThrowsError(try decoder.decode(frame)) { error in
            guard case KrakenDecodingError.outputLimitExceeded = error else {
                return XCTFail("Expected the configured output limit error, got \(error).")
            }
        }
    }

    private func frameWithStoredBlock(_ payload: Data) -> Data {
        precondition(!payload.isEmpty && payload.count <= 0x40000)
        var frame = frameHeader(outputCount: payload.count)
        frame.append(0x2C)
        frame.append(0x06)
        appendBigEndian24(UInt32(payload.count - 1), to: &frame)
        frame.append(payload)
        return frame
    }

    private func frameWithRepeatedByte(_ byte: UInt8, outputCount: Int) -> Data {
        precondition(outputCount > 0 && outputCount <= 0x40000)
        var frame = frameHeader(outputCount: outputCount)
        frame.append(contentsOf: [0x0C, 0x06])
        appendBigEndian24(0x7FFFF, to: &frame)
        frame.append(byte)
        return frame
    }

    private func frameHeader(outputCount: Int) -> Data {
        var frame = Data("KARK".utf8)
        var size = UInt32(outputCount).littleEndian
        frame.append(contentsOf: withUnsafeBytes(of: &size) { Array($0) })
        return frame
    }

    private func appendBigEndian24(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }
}

final class ResourceSchemaTests: XCTestCase {
    func testTypedRoundTripPreservesUnmappedBytes() throws {
        let schema = ResourceSchema(
            typeIdentifier: "Tests.Sample",
            version: 1,
            byteCount: 16,
            fields: [
                ResourceFieldSchema(name: "enabled", offset: 0, width: 1, storage: .boolean),
                ResourceFieldSchema(name: "count", offset: 1, width: 4, storage: .signedInteger),
                ResourceFieldSchema(name: "weight", offset: 5, width: 4, storage: .float32),
                ResourceFieldSchema(name: "label", offset: 9, width: 3, storage: .utf8Fixed)
            ]
        )
        var original = Data(repeating: 0, count: 16)
        original.replaceSubrange(12..<16, with: [0xCA, 0xFE, 0xBA, 0xBE])
        let values: [String: ResourceValue] = [
            "enabled": .boolean(true),
            "count": .signed(-1234),
            "weight": .floating(1.25),
            "label": .string("OK")
        ]

        let encoded = try schema.encode(values, preserving: original)
        XCTAssertEqual(encoded.count, original.count)
        XCTAssertEqual(encoded.suffix(4), original.suffix(4))
        XCTAssertEqual(try schema.decode(encoded), values)
    }

    func testRejectsOverlappingFields() {
        let schema = ResourceSchema(
            typeIdentifier: "Tests.Invalid",
            version: 1,
            byteCount: 8,
            fields: [
                ResourceFieldSchema(name: "left", offset: 0, width: 4, storage: .unsignedInteger),
                ResourceFieldSchema(name: "right", offset: 3, width: 4, storage: .unsignedInteger)
            ]
        )

        XCTAssertThrowsError(try schema.validate())
    }

    func testRegistryRegistersAndDecodesAtRuntime() async throws {
        let registry = ResourceSchemaRegistry()
        let schema = ResourceSchema(
            typeIdentifier: "Tests.Runtime",
            version: 2,
            byteCount: 4,
            fields: [ResourceFieldSchema(name: "code", offset: 0, width: 4, storage: .unsignedInteger)]
        )
        try await registry.register(schema)

        let values = try await registry.decode(typeIdentifier: "Tests.Runtime",
                                                version: 2,
                                                payload: Data([0x78, 0x56, 0x34, 0x12]))
        XCTAssertEqual(values, ["code": .unsigned(0x12345678)])
        let registered = await registry.registeredSchemas()
        XCTAssertTrue(registered.contains(schema))
        XCTAssertTrue(registered.contains { $0.id == "CR2W.Header@1" })
        XCTAssertTrue(registered.contains { $0.id == "RED4.Vector3@1" })
    }

    func testEveryBuiltInSchemaPassesValidation() throws {
        for schema in CR2WCoreSchemas.all {
            XCTAssertNoThrow(try schema.validate(), "Built-in schema \(schema.id) must be valid.")
        }
    }

    func testSerializedPropertyNamesResolveToBuiltInSchemas() async throws {
        let registry = ResourceSchemaRegistry()
        let floatSchema = try await registry.schema(serializedTypeName: "Float")
        let vectorSchema = try await registry.schema(serializedTypeName: "Vector3")

        XCTAssertEqual(floatSchema.id, "RED4.Float@1")
        XCTAssertEqual(vectorSchema.byteCount, 12)
        XCTAssertEqual(CR2WCoreSchemas.recordSize(forTableIndex: 5), 24)
        XCTAssertNil(CR2WCoreSchemas.recordSize(forTableIndex: 0))
    }
}
