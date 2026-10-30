import Foundation

/// Decodes the KARK envelope and Kraken block forms whose layout is fully
/// specified by the archive format notes: stored blocks and repeated-byte blocks.
/// Entropy-coded Kraken blocks are reported explicitly until a complete bitstream
/// specification is available.
struct KrakenDecoder: Sendable {
    let limits: Limits

    struct Limits: Sendable {
        var maximumOutputSize: Int
        var maximumInputSize: Int

        static let `default` = Limits(maximumOutputSize: 2 * 1024 * 1024 * 1024,
                                      maximumInputSize: 2 * 1024 * 1024 * 1024)
    }

    init(limits: Limits = .default) {
        self.limits = limits
    }

    func decode(_ framedData: Data) throws -> Data {
        guard framedData.count <= limits.maximumInputSize else {
            throw KrakenDecodingError.inputLimitExceeded
        }
        guard framedData.count >= 8,
              framedData.prefix(4).elementsEqual([0x4B, 0x41, 0x52, 0x4B]) else {
            throw KrakenDecodingError.invalidFrame
        }
        guard let declaredSize = framedData.littleEndianInteger(at: 4, as: UInt32.self) else {
            throw KrakenDecodingError.truncatedFrame
        }
        let outputSize = Int(declaredSize)
        guard outputSize <= limits.maximumOutputSize else {
            throw KrakenDecodingError.outputLimitExceeded
        }
        if outputSize == 0 {
            guard framedData.count == 8 else { throw KrakenDecodingError.trailingData }
            return Data()
        }

        var cursor = KrakenByteCursor(data: framedData, offset: 8)
        var output = Data(capacity: outputSize)
        while output.count < outputSize {
            let targetCount = min(0x40000, outputSize - output.count)
            let firstHeader = try cursor.readByte()
            let secondHeader = try cursor.readByte()
            guard firstHeader & 0x0F == 0x0C,
                  secondHeader & 0x7F == 6 else {
                throw KrakenDecodingError.invalidBlockHeader(offset: cursor.offset - 2)
            }

            let quantumHeader = try cursor.readBigEndian24()
            let repeatedByteBlock = quantumHeader & 0x7FFFF == 0x7FFFF
            if repeatedByteBlock {
                let value = try cursor.readByte()
                output.append(contentsOf: repeatElement(value, count: targetCount))
                continue
            }

            let packedSize = Int(quantumHeader & 0x3FFFF) + 1
            guard packedSize <= cursor.remaining else { throw KrakenDecodingError.truncatedBlock }
            let storedBlock = firstHeader & 0x20 != 0
            guard storedBlock else {
                throw KrakenDecodingError.unsupportedEntropyBlock(offset: cursor.offset,
                                                                  packedSize: packedSize,
                                                                  outputSize: targetCount)
            }
            guard packedSize == targetCount else {
                throw KrakenDecodingError.invalidStoredBlockSize(expected: targetCount,
                                                                 actual: packedSize)
            }
            output.append(try cursor.readData(count: packedSize))
        }

        guard output.count == outputSize else { throw KrakenDecodingError.outputSizeMismatch }
        guard cursor.remaining == 0 else { throw KrakenDecodingError.trailingData }
        return output
    }
}

private struct KrakenByteCursor {
    let data: Data
    private(set) var offset: Int

    var remaining: Int { data.count - offset }

    mutating func readByte() throws -> UInt8 {
        guard offset < data.count else { throw KrakenDecodingError.truncatedBlock }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readBigEndian24() throws -> UInt32 {
        let a = UInt32(try readByte())
        let b = UInt32(try readByte())
        let c = UInt32(try readByte())
        return (a << 16) | (b << 8) | c
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw KrakenDecodingError.truncatedBlock }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }
}

private extension Data {
    func littleEndianInteger<T: FixedWidthInteger>(at offset: Int, as: T.Type) -> T? {
        guard offset >= 0, offset <= count, MemoryLayout<T>.size <= count - offset else { return nil }
        var value: T = 0
        for index in 0..<MemoryLayout<T>.size {
            value |= T(self[offset + index]) << (index * 8)
        }
        return value
    }
}

enum KrakenDecodingError: LocalizedError {
    case invalidFrame
    case truncatedFrame
    case inputLimitExceeded
    case outputLimitExceeded
    case invalidBlockHeader(offset: Int)
    case truncatedBlock
    case unsupportedEntropyBlock(offset: Int, packedSize: Int, outputSize: Int)
    case invalidStoredBlockSize(expected: Int, actual: Int)
    case outputSizeMismatch
    case trailingData

    var errorDescription: String? {
        switch self {
        case .invalidFrame: return "The data does not begin with a valid KARK frame."
        case .truncatedFrame: return "The KARK frame header is incomplete."
        case .inputLimitExceeded: return "The compressed input exceeds the configured size limit."
        case .outputLimitExceeded: return "The declared output exceeds the configured size limit."
        case let .invalidBlockHeader(offset): return "The Kraken block header at byte \(offset) is invalid."
        case .truncatedBlock: return "The Kraken block ends before its declared data is complete."
        case let .unsupportedEntropyBlock(offset, packedSize, outputSize):
            return "The Kraken entropy-coded block at byte \(offset) (\(packedSize) packed bytes, \(outputSize) output bytes) is not supported by this decoder."
        case let .invalidStoredBlockSize(expected, actual):
            return "A stored Kraken block has \(actual) bytes; \(expected) were expected."
        case .outputSizeMismatch: return "The decoded size does not match the KARK frame declaration."
        case .trailingData: return "The KARK frame contains unexpected trailing bytes."
        }
    }
}
