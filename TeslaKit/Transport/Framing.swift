import Foundation

/// BLE message framing: each message is prefixed with its 2-byte big-endian length,
/// then written in `blockLength`-sized chunks.
public enum Framing {
    public static let maxMessageLength = 1024

    public static func chunks(for message: Data, blockLength: Int) -> [Data] {
        precondition(blockLength > 0, "blockLength must be positive")
        let length = UInt16(message.count)
        let framed = Data([UInt8(length >> 8), UInt8(length & 0xFF)]) + message
        return stride(from: 0, to: framed.count, by: blockLength).map {
            Data(framed[$0..<min($0 + blockLength, framed.count)])
        }
    }
}

/// Reassembles length-prefixed messages from BLE notification chunks.
public struct FrameReassembler {
    static let staleAfter: TimeInterval = 1

    private var buffer = Data()
    private var lastChunkAt: Date?

    public init() {}

    /// Appends `chunk` and returns every message it completes, in order.
    public mutating func append(_ chunk: Data, at time: Date) -> [Data] {
        if let last = lastChunkAt, time.timeIntervalSince(last) > Self.staleAfter {
            buffer.removeAll()
        }
        lastChunkAt = time
        buffer.append(chunk)

        var messages: [Data] = []
        while buffer.count >= 2 {
            let start = buffer.startIndex
            let length = Int(buffer[start]) << 8 | Int(buffer[start + 1])
            if length > Framing.maxMessageLength {
                buffer.removeAll()
                break
            }
            guard buffer.count >= 2 + length else { break }
            messages.append(Data(buffer[(start + 2)..<(start + 2 + length)]))
            buffer = Data(buffer[(start + 2 + length)...])
        }
        return messages
    }
}
