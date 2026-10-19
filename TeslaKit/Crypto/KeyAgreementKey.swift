import CryptoKit
import Foundation

/// A P-256 private key that can perform ECDH with a vehicle's public key.
public protocol KeyAgreementKey: Sendable {
    /// Uncompressed SEC1 public point: `04 ‖ X ‖ Y`.
    var publicKeyX963: Data { get }
    /// Returns the 32-byte big-endian X coordinate of the ECDH shared point.
    func sharedSecretX(peerPublicX963: Data) throws -> Data
}

/// A key held in memory. Used for tests and keys without Secure Enclave backing.
public struct SoftwareKeyAgreementKey: KeyAgreementKey {
    private let key: P256.KeyAgreement.PrivateKey

    public init(_ key: P256.KeyAgreement.PrivateKey) {
        self.key = key
    }

    public var publicKeyX963: Data { key.publicKey.x963Representation }

    public func sharedSecretX(peerPublicX963: Data) throws -> Data {
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: peerPublicX963)
        return try key.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes { Data($0) }
    }
}

/// A key whose private half never leaves the Secure Enclave.
public struct SecureEnclaveKeyAgreementKey: KeyAgreementKey {
    private let key: SecureEnclave.P256.KeyAgreement.PrivateKey

    public init(_ key: SecureEnclave.P256.KeyAgreement.PrivateKey) {
        self.key = key
    }

    public var publicKeyX963: Data { key.publicKey.x963Representation }

    public func sharedSecretX(peerPublicX963: Data) throws -> Data {
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: peerPublicX963)
        return try key.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes { Data($0) }
    }
}
