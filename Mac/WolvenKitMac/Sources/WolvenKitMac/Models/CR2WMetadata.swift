import Foundation

struct CR2WMetadata: Hashable, Sendable {
    let version: UInt32
    let flags: UInt32
    let timestamp: UInt64
    let buildVersion: UInt32
    let objectDataEnd: UInt32
    let bufferDataEnd: UInt32
    let checksum: UInt32
    let chunkCount: UInt32
    let rootClassName: String?
}
