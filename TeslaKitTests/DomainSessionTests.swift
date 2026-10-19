import CryptoKit
import Foundation
import Testing
@testable import TeslaKit

private let challenge = Data(hex: "1588d5a30eabc6f8fc9a951b11f6fd11")
private let vectorEpoch = Data(hex: "4c463f9cc0d3d26906e982ed224adde6")
/// The vector's session info carries clock time 2650, so this puts `timeZero` at 7350.
private let handshakeTime = Date(timeIntervalSince1970: 10_000)

private func vectorSession() throws -> DomainSession {
    try DomainSession(domain: .infotainment, vin: TestVectors.vin, key: TestVectors.clientKey,
        challenge: challenge, response: TestVectors.handshakeResponse, now: handshakeTime)
}

private func hvacCommand() -> UniversalMessage_RoutableMessage {
    var msg = UniversalMessage_RoutableMessage()
    msg.toDestination.domain = .infotainment
    msg.protobufMessageAsBytes = Data(hex: "120452020801")
    return msg
}

/// Builds the encrypted reply a vehicle would send to the request identified by `requestHash`.
private func encryptedReply(_ plaintext: Data, counter: UInt32, requestHash: Data) throws
    -> UniversalMessage_RoutableMessage {
    var reply = UniversalMessage_RoutableMessage()
    reply.fromDestination.domain = .infotainment
    reply.flags = 0
    var meta = Metadata()
    try meta.add(.signatureType, Data([UInt8(Signatures_SignatureType.aesGcmResponse.rawValue)]))
    try meta.add(.domain, Data([UInt8(UniversalMessage_Domain.infotainment.rawValue)]))
    try meta.add(.personalization, Data(TestVectors.vin.utf8))
    try meta.add(.counter, uint32: counter)
    try meta.add(.flags, uint32: reply.flags)
    try meta.add(.requestHash, requestHash)
    try meta.add(.fault, uint32: 0)
    let key = SessionKey(keyBytesForTesting: TestVectors.sharedKeyK)
    let sealed = try key.seal(plaintext, aad: Data(SHA256.hash(data: meta.serialized())))
    reply.protobufMessageAsBytes = sealed.ciphertext
    reply.signatureData.aesGcmResponseData.nonce = sealed.nonce
    reply.signatureData.aesGcmResponseData.counter = counter
    reply.signatureData.aesGcmResponseData.tag = sealed.tag
    return reply
}

@Test func handshakeRequestCarriesKeyAndAddressing() {
    let req = DomainSession.handshakeRequest(domain: .vehicleSecurity, publicKeyX963: Data([4, 1, 2]),
        routingAddress: Data(repeating: 7, count: 16), uuid: challenge)
    #expect(req.toDestination.domain == .vehicleSecurity)
    #expect(req.fromDestination.routingAddress == Data(repeating: 7, count: 16))
    #expect(req.sessionInfoRequest.publicKey == Data([4, 1, 2]))
    #expect(req.uuid == challenge)
}

@Test func acceptsVectorHandshake() throws {
    let s = try vectorSession()
    #expect(s.counter == 6)
    #expect(s.epoch == vectorEpoch)
    #expect(s.timeZero == Date(timeIntervalSince1970: 10_000 - 2650))
}

@Test func rejectsTamperedHandshake() {
    var response = TestVectors.handshakeResponse
    response.signatureData.sessionInfoTag.tag[0] ^= 0x01
    #expect(throws: VehicleError.protocolFault(.rrorInvalidSignature)) {
        try DomainSession(domain: .infotainment, vin: TestVectors.vin, key: TestVectors.clientKey,
            challenge: challenge, response: response, now: handshakeTime)
    }
}

@Test func handshakeFaultMapsToVehicleError() {
    var response = TestVectors.handshakeResponse
    response.signedMessageStatus.signedMessageFault = .rrorUnknownKeyID
    #expect(throws: VehicleError.notPaired) {
        try DomainSession(domain: .infotainment, vin: TestVectors.vin, key: TestVectors.clientKey,
            challenge: challenge, response: response, now: handshakeTime)
    }
}

@Test func encryptBuildsVectorMetadata() throws {
    var s = try vectorSession()
    var msg = hvacCommand()
    let requestHash = try s.encrypt(&msg, now: s.timeZero.addingTimeInterval(2650), lifetime: 5)

    let gcm = msg.signatureData.aesGcmPersonalizedData
    #expect(s.counter == 7)
    #expect(gcm.counter == 7)
    #expect(gcm.expiresAt == 2655)
    #expect(gcm.epoch == vectorEpoch)
    #expect(msg.flags == 2)
    #expect(msg.signatureData.signerIdentity.publicKey == TestVectors.clientKey.publicKeyX963)
    #expect(s.commandMetadata(for: msg, counter: 7, expiresAt: 2655) == TestVectors.hvacOnMetadata)
    #expect(requestHash == Data([5]) + gcm.tag)

    // The ciphertext authenticates against the protocol.md metadata exactly.
    let key = SessionKey(keyBytesForTesting: TestVectors.sharedKeyK)
    let plaintext = try key.open(nonce: gcm.nonce, ciphertext: msg.protobufMessageAsBytes, tag: gcm.tag,
        aad: Data(SHA256.hash(data: TestVectors.hvacOnMetadata)))
    #expect(plaintext == Data(hex: "120452020801"))
}

@Test func encryptRequiresProtobufPayload() throws {
    var s = try vectorSession()
    var msg = UniversalMessage_RoutableMessage()
    #expect(throws: VehicleError.protocolFault(.rrorBadParameter)) {
        try s.encrypt(&msg, now: handshakeTime)
    }
}

@Test func decryptResponseRoundTrip() throws {
    var s = try vectorSession()
    var request = hvacCommand()
    let requestHash = try s.encrypt(&request, now: handshakeTime)

    var reply = try encryptedReply(Data(hex: "3a00"), counter: 42, requestHash: requestHash)
    let replayed = reply
    try s.decryptResponse(&reply, requestHash: requestHash)
    #expect(reply.protobufMessageAsBytes == Data(hex: "3a00"))

    var again = replayed
    #expect(throws: VehicleError.protocolFault(.rrorInvalidTokenOrCounter)) {
        try s.decryptResponse(&again, requestHash: requestHash)
    }
}

@Test func decryptResponseRejectsWrongRequestHash() throws {
    var s = try vectorSession()
    var request = hvacCommand()
    let requestHash = try s.encrypt(&request, now: handshakeTime)
    var reply = try encryptedReply(Data(hex: "3a00"), counter: 1, requestHash: Data([5]) + Data(count: 16))
    #expect(throws: VehicleError.protocolFault(.rrorInvalidSignature)) {
        try s.decryptResponse(&reply, requestHash: requestHash)
    }
}

@Test func decryptResponseLeavesPlaintextReplies() throws {
    var s = try vectorSession()
    var reply = UniversalMessage_RoutableMessage()
    reply.protobufMessageAsBytes = Data(hex: "3a00")
    try s.decryptResponse(&reply, requestHash: Data([5]))
    #expect(reply.protobufMessageAsBytes == Data(hex: "3a00"))
}

@Test func resyncNeverRollsCounterBackInSameEpoch() throws {
    var s = try vectorSession()
    var info = try Signatures_SessionInfo(serializedBytes: TestVectors.sessionInfoBytes)
    info.counter = 10
    info.clockTime = 2700
    s.resync(from: info, now: handshakeTime)
    #expect(s.counter == 10)

    info.counter = 4
    info.clockTime = 2800
    s.resync(from: info, now: handshakeTime)
    #expect(s.counter == 10)

    info.epoch = Data(repeating: 0xAB, count: 16)
    info.clockTime = 3
    s.resync(from: info, now: handshakeTime)
    #expect(s.counter == 4)
    #expect(s.epoch == Data(repeating: 0xAB, count: 16))
    #expect(s.timeZero == handshakeTime.addingTimeInterval(-3))
}

@Test func resyncIgnoresOlderClockInSameEpoch() throws {
    var s = try vectorSession()
    var info = try Signatures_SessionInfo(serializedBytes: TestVectors.sessionInfoBytes)
    info.counter = 20
    info.clockTime = 100
    s.resync(from: info, now: handshakeTime)
    #expect(s.counter == 6)
    #expect(s.timeZero == handshakeTime.addingTimeInterval(-2650))
}

/// A fault reply carrying fresh session info, tagged with K for `requestUUID`.
private func resyncReply(_ info: Signatures_SessionInfo, requestUUID: Data) throws -> UniversalMessage_RoutableMessage {
    var reply = UniversalMessage_RoutableMessage()
    reply.fromDestination.domain = .infotainment
    reply.requestUuid = requestUUID
    reply.signedMessageStatus.signedMessageFault = .rrorInvalidTokenOrCounter
    reply.sessionInfo = try info.serializedData()
    reply.signatureData.sessionInfoTag.tag = try SessionKey(keyBytesForTesting: TestVectors.sharedKeyK)
        .sessionInfoTag(vin: TestVectors.vin, challenge: requestUUID, encodedInfo: reply.sessionInfo)
    return reply
}

@Test func authenticatedResyncAppliesValidInfo() throws {
    var s = try vectorSession()
    var info = try Signatures_SessionInfo(serializedBytes: TestVectors.sessionInfoBytes)
    info.epoch = Data(repeating: 0xCD, count: 16)
    info.counter = 2
    info.clockTime = 9
    let uuid = Data(repeating: 0x42, count: 16)
    try s.resync(response: resyncReply(info, requestUUID: uuid), challenge: uuid, now: handshakeTime)
    #expect(s.counter == 2)
    #expect(s.epoch == Data(repeating: 0xCD, count: 16))
    #expect(s.timeZero == handshakeTime.addingTimeInterval(-9))
}

@Test func authenticatedResyncRejectsTamperedTag() throws {
    var s = try vectorSession()
    var info = try Signatures_SessionInfo(serializedBytes: TestVectors.sessionInfoBytes)
    info.epoch = Data(repeating: 0xCD, count: 16)
    info.counter = 2
    let uuid = Data(repeating: 0x42, count: 16)
    var reply = try resyncReply(info, requestUUID: uuid)
    reply.signatureData.sessionInfoTag.tag[0] ^= 0x01
    #expect(throws: VehicleError.protocolFault(.rrorInvalidSignature)) {
        try s.resync(response: reply, challenge: uuid, now: handshakeTime.addingTimeInterval(60))
    }
    // A valid tag for a different challenge is rejected too.
    let otherChallenge = try resyncReply(info, requestUUID: Data(repeating: 0x43, count: 16))
    #expect(throws: VehicleError.protocolFault(.rrorInvalidSignature)) {
        try s.resync(response: otherChallenge, challenge: uuid, now: handshakeTime.addingTimeInterval(60))
    }
    #expect(s.counter == 6)
    #expect(s.epoch == vectorEpoch)
    #expect(s.timeZero == handshakeTime.addingTimeInterval(-2650))
}

@Test func slidingWindowRejectsReplays() {
    var w = SlidingWindow()
    // 7 is 33 behind 40, older than the 32-entry window; 8 is exactly 32 behind and still tracked.
    let results = [5, 5, 3, 3, 40, 7, 8].map { w.accept($0) }
    #expect(results == [true, false, true, false, true, false, true])
}

@Test func vehicleErrorMapsFaults() {
    #expect(VehicleError.from(fault: .rrorUnknownKeyID) == .notPaired)
    #expect(VehicleError.from(fault: .rrorInactiveKey) == .notPaired)
    #expect(VehicleError.from(fault: .rrorBusy) == .busy)
    #expect(VehicleError.from(fault: .rrorIncorrectEpoch) == .protocolFault(.rrorIncorrectEpoch))
}
