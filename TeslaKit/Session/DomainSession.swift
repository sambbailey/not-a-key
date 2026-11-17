import CryptoKit
import Foundation

/// Authenticated session with one vehicle domain (VCSEC or infotainment):
/// signs and encrypts commands, decrypts responses, and tracks the vehicle's
/// epoch, anti-replay counter and clock. Port of Go's `authentication.Signer`.
public struct DomainSession: Sendable {
    public let domain: UniversalMessage_Domain
    public let vin: String
    public private(set) var counter: UInt32
    public private(set) var epoch: Data
    /// The local time at which the vehicle's epoch clock read zero.
    public private(set) var timeZero: Date

    private let sessionKey: SessionKey
    private let localPublicKey: Data
    private let vehiclePublicKey: Data
    /// Vehicle clock time of the newest session info applied, to discard stale resyncs.
    private var clockTime: UInt32
    private var responseWindow = SlidingWindow()
    private var windowRequestHash: Data?

    /// The unauthenticated request that asks `domain` for its session info.
    public static func handshakeRequest(domain: UniversalMessage_Domain, publicKeyX963: Data,
                                        routingAddress: Data, uuid: Data) -> UniversalMessage_RoutableMessage {
        var msg = UniversalMessage_RoutableMessage()
        msg.toDestination.domain = domain
        msg.fromDestination.routingAddress = routingAddress
        msg.sessionInfoRequest.publicKey = publicKeyX963
        msg.uuid = uuid
        return msg
    }

    /// Establishes a session from the vehicle's reply to `handshakeRequest`,
    /// where `challenge` is the request's UUID.
    public init(domain: UniversalMessage_Domain, vin: String, key: KeyAgreementKey, challenge: Data,
                response: UniversalMessage_RoutableMessage, now: Date) throws {
        let fault = response.signedMessageStatus.signedMessageFault
        guard fault == .rrorNone else {
            throw VehicleError.from(fault: fault)
        }
        let info: Signatures_SessionInfo
        do {
            info = try Signatures_SessionInfo(serializedBytes: response.sessionInfo)
        } catch {
            throw VehicleError.protocolFault(.rrorDecoding)
        }
        let sessionKey = SessionKey(sharedSecretX: try key.sharedSecretX(peerPublicX963: info.publicKey))
        let expectedTag = try sessionKey.sessionInfoTag(vin: vin, challenge: challenge, encodedInfo: response.sessionInfo)
        guard constantTimeEqual(expectedTag, response.signatureData.sessionInfoTag.tag) else {
            throw VehicleError.protocolFault(.rrorInvalidSignature)
        }
        guard info.status == .ok else {
            throw VehicleError.notPaired
        }
        self.domain = domain
        self.vin = vin
        self.sessionKey = sessionKey
        localPublicKey = key.publicKeyX963
        vehiclePublicKey = info.publicKey
        counter = info.counter
        epoch = info.epoch
        clockTime = info.clockTime
        timeZero = now.addingTimeInterval(-TimeInterval(info.clockTime))
    }

    /// Encrypts `message`'s payload in place and attaches its signature data.
    /// Returns the request hash needed to decrypt the vehicle's response.
    public mutating func encrypt(_ message: inout UniversalMessage_RoutableMessage, now: Date,
                                 lifetime: TimeInterval = 5) throws -> Data {
        guard case .protobufMessageAsBytes(let plaintext)? = message.payload else {
            throw VehicleError.protocolFault(.rrorBadParameter)
        }
        guard counter < .max else {
            throw VehicleError.protocolFault(.rrorInvalidTokenOrCounter)
        }
        let expiry = (now.addingTimeInterval(lifetime).timeIntervalSince(timeZero)).rounded(.down)
        guard expiry >= 0, expiry <= TimeInterval(UInt32.max) else {
            throw VehicleError.protocolFault(.rrorBadParameter)
        }
        let expiresAt = UInt32(expiry)
        counter += 1
        message.toDestination.domain = domain
        message.flags = 1 << UInt32(UniversalMessage_Flags.flagEncryptResponse.rawValue)

        let metadata = try commandMetadata(for: message, counter: counter, expiresAt: expiresAt)
        let sealed = try sessionKey.seal(plaintext, aad: Data(SHA256.hash(data: metadata)))
        message.protobufMessageAsBytes = sealed.ciphertext

        var gcm = Signatures_AES_GCM_Personalized_Signature_Data()
        gcm.epoch = epoch
        gcm.nonce = sealed.nonce
        gcm.counter = counter
        gcm.expiresAt = expiresAt
        gcm.tag = sealed.tag
        var signature = Signatures_SignatureData()
        signature.signerIdentity.publicKey = localPublicKey
        signature.aesGcmPersonalizedData = gcm
        message.signatureData = signature

        return Data([UInt8(Signatures_SignatureType.aesGcmPersonalized.rawValue)]) + sealed.tag
    }

    /// Serialized metadata authenticated as AES-GCM associated data for a command.
    func commandMetadata(for message: UniversalMessage_RoutableMessage, counter: UInt32, expiresAt: UInt32) throws -> Data {
        var meta = Metadata()
        // Tags are added in order; the VIN (17 bytes) and epoch (16 bytes) fit the TLV limit.
        try meta.add(.signatureType, Data([UInt8(Signatures_SignatureType.aesGcmPersonalized.rawValue)]))
        try meta.add(.domain, Data([UInt8(domain.rawValue)]))
        try meta.add(.personalization, Data(vin.utf8))
        try meta.add(.epoch, epoch)
        try meta.add(.expiresAt, uint32: expiresAt)
        try meta.add(.counter, uint32: counter)
        // Flags are only authenticated when set, for compatibility with older vehicles.
        if message.flags != 0 {
            try meta.add(.flags, uint32: message.flags)
        }
        return meta.serialized()
    }

    /// Decrypts a response in place. Plaintext replies (no AES-GCM response data)
    /// are left untouched. Rejects responses whose counter was already seen for this request.
    public mutating func decryptResponse(_ message: inout UniversalMessage_RoutableMessage, requestHash: Data) throws {
        guard case .signatureData(let signature)? = message.subSigData,
              case .aesGcmResponseData(let gcm)? = signature.sigType else {
            return
        }
        var meta = Metadata()
        do {
            try meta.add(.signatureType, Data([UInt8(Signatures_SignatureType.aesGcmResponse.rawValue)]))
            try meta.add(.domain, Data([UInt8(truncatingIfNeeded: message.fromDestination.domain.rawValue)]))
            try meta.add(.personalization, Data(vin.utf8))
            try meta.add(.counter, uint32: gcm.counter)
            try meta.add(.flags, uint32: message.flags)
            try meta.add(.requestHash, requestHash)
            try meta.add(.fault, uint32: UInt32(truncatingIfNeeded: message.signedMessageStatus.signedMessageFault.rawValue))
        } catch {
            throw VehicleError.protocolFault(.rrorBadParameter)
        }
        let plaintext: Data
        do {
            plaintext = try sessionKey.open(nonce: gcm.nonce, ciphertext: message.protobufMessageAsBytes,
                                            tag: gcm.tag, aad: Data(SHA256.hash(data: meta.serialized())))
        } catch {
            throw VehicleError.protocolFault(.rrorInvalidSignature)
        }
        // Counters are unique per request, so each request gets a fresh window.
        if windowRequestHash != requestHash {
            windowRequestHash = requestHash
            responseWindow = SlidingWindow()
        }
        guard responseWindow.accept(gcm.counter) else {
            throw VehicleError.protocolFault(.rrorInvalidTokenOrCounter)
        }
        message.protobufMessageAsBytes = plaintext
        message.subSigData = nil
    }

    /// Applies the session info the vehicle attached to a fault, after verifying
    /// its HMAC. `challenge` is the UUID of the request that faulted. Throws
    /// without changing state if the tag or encoding is invalid.
    public mutating func resync(response: UniversalMessage_RoutableMessage, challenge: Data, now: Date) throws {
        let expectedTag = try sessionKey.sessionInfoTag(vin: vin, challenge: challenge, encodedInfo: response.sessionInfo)
        guard constantTimeEqual(expectedTag, response.signatureData.sessionInfoTag.tag) else {
            throw VehicleError.protocolFault(.rrorInvalidSignature)
        }
        let info: Signatures_SessionInfo
        do {
            info = try Signatures_SessionInfo(serializedBytes: response.sessionInfo)
        } catch {
            throw VehicleError.protocolFault(.rrorDecoding)
        }
        resync(from: info, now: now)
    }

    /// Applies already-authenticated session info, per protocol.md "Recovering
    /// from synchronization errors". Info for a different vehicle key, or older
    /// than what was last applied in the same epoch, is ignored; the counter
    /// only moves backwards when the epoch changes.
    mutating func resync(from info: Signatures_SessionInfo, now: Date) {
        guard info.publicKey == vehiclePublicKey else { return }
        if info.epoch != epoch {
            counter = info.counter
        } else if info.clockTime >= clockTime {
            counter = max(counter, info.counter)
        } else {
            return
        }
        epoch = info.epoch
        clockTime = info.clockTime
        timeZero = now.addingTimeInterval(-TimeInterval(info.clockTime))
    }
}

private func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    for (x, y) in zip(a, b) {
        diff |= x ^ y
    }
    return diff == 0
}
