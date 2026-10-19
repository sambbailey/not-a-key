import Foundation

public enum MetadataError: Error, Equatable {
    /// Tags must be added in non-decreasing order.
    case outOfOrder
    /// Values are length-prefixed with a single byte.
    case tooLong
}

/// TLV encoding of the authenticated metadata covered by HMAC tags and used as
/// AES-GCM associated data: `tag ‖ len ‖ value` per field, terminated by `0xFF`.
public struct Metadata {
    private var bytes = Data()
    private var lastTag: Int?

    public init() {}

    public mutating func add(_ tag: Signatures_Tag, _ value: Data) throws {
        if let lastTag, tag.rawValue < lastTag {
            throw MetadataError.outOfOrder
        }
        guard value.count <= 255 else {
            throw MetadataError.tooLong
        }
        lastTag = tag.rawValue
        bytes.append(UInt8(tag.rawValue))
        bytes.append(UInt8(value.count))
        bytes.append(value)
    }

    public mutating func add(_ tag: Signatures_Tag, uint32 value: UInt32) throws {
        try add(tag, withUnsafeBytes(of: value.bigEndian) { Data($0) })
    }

    public func serialized() -> Data {
        bytes + [UInt8(Signatures_Tag.end.rawValue)]
    }
}
