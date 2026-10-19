import Foundation
import Testing
@testable import TeslaKit

@Test func chunksPrefixLength() {
    let message = Data((0..<300).map { UInt8($0 & 0xFF) })
    let chunks = Framing.chunks(for: message, blockLength: 182)
    #expect(chunks.count == 2)
    #expect(chunks[0].count == 182)
    #expect(chunks[1].count == 120)
    #expect(chunks[0].prefix(2) == Data([0x01, 0x2C]))
    #expect(chunks.reduce(Data(), +) == Data([0x01, 0x2C]) + message)
}

@Test func reassemblesSplitMessage() {
    let message = Data((0..<300).map { UInt8($0 & 0xFF) })
    let chunks = Framing.chunks(for: message, blockLength: 182)
    var reassembler = FrameReassembler()
    let t0 = Date(timeIntervalSince1970: 1000)
    #expect(reassembler.append(chunks[0], at: t0) == [])
    #expect(reassembler.append(chunks[1], at: t0.addingTimeInterval(0.5)) == [message])
}

@Test func reassemblesTwoMessagesInOneChunk() {
    var reassembler = FrameReassembler()
    let chunk = Data(hex: "0002AABB0003CCDDEE00")
    let t0 = Date(timeIntervalSince1970: 1000)
    #expect(reassembler.append(chunk, at: t0) == [Data(hex: "AABB"), Data(hex: "CCDDEE")])
    // The trailing 0x00 starts a third frame that completes on the next chunk.
    #expect(reassembler.append(Data(hex: "01FF"), at: t0.addingTimeInterval(0.1)) == [Data(hex: "FF")])
}

@Test func dropsStaleBufferAfterOneSecond() {
    var reassembler = FrameReassembler()
    let t0 = Date(timeIntervalSince1970: 1000)
    #expect(reassembler.append(Data(hex: "0004AABB"), at: t0) == [])
    // Over 1 s later the partial frame is discarded; this chunk is a fresh frame.
    #expect(reassembler.append(Data(hex: "0001CC"), at: t0.addingTimeInterval(1.5)) == [Data(hex: "CC")])
}

@Test func dropsOversizedDeclaredLength() {
    var reassembler = FrameReassembler()
    let t0 = Date(timeIntervalSince1970: 1000)
    // 0x0401 = 1025 bytes, over the 1024 maximum.
    #expect(reassembler.append(Data(hex: "0401AABB"), at: t0) == [])
    #expect(reassembler.append(Data(hex: "0001CC"), at: t0.addingTimeInterval(0.1)) == [Data(hex: "CC")])
}
