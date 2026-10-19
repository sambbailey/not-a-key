import CryptoKit
import Foundation

/// Tesla's per-domain session key `K = SHA1(sharedX)[0..<16]`, used for
/// AES-128-GCM and as the root of HMAC subkeys.
public struct SessionKey: Sendable {
    public let keyBytes: Data

    private var key: SymmetricKey { SymmetricKey(data: keyBytes) }

    public init(sharedSecretX: Data) {
        keyBytes = Data(Insecure.SHA1.hash(data: sharedSecretX).prefix(16))
    }

    init(keyBytesForTesting keyBytes: Data) {
        self.keyBytes = keyBytes
    }

    /// HMAC the vehicle attaches to a session-info response, proving it holds `K`.
    public func sessionInfoTag(vin: String, challenge: Data, encodedInfo: Data) throws -> Data {
        var metadata = Metadata()
        try metadata.add(.signatureType, Data([UInt8(Signatures_SignatureType.hmac.rawValue)]))
        try metadata.add(.personalization, Data(vin.utf8))
        try metadata.add(.challenge, challenge)
        let subkey = Data(HMAC<SHA256>.authenticationCode(for: Data("session info".utf8), using: key))
        let mac = HMAC<SHA256>.authenticationCode(
            for: metadata.serialized() + encodedInfo, using: SymmetricKey(data: subkey))
        return Data(mac)
    }

    /// Encrypts with AES-128-GCM. `aad` is `SHA256(metadata.serialized())`.
    public func seal(_ plaintext: Data, aad: Data, nonce: AES.GCM.Nonce = .init()) throws
        -> (nonce: Data, ciphertext: Data, tag: Data) {
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        return (Data(box.nonce), box.ciphertext, box.tag)
    }

    /// Decrypts and authenticates; throws if the tag does not verify.
    public func open(nonce: Data, ciphertext: Data, tag: Data, aad: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(nonce: .init(data: nonce), ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(box, using: key, authenticating: aad)
    }
}
