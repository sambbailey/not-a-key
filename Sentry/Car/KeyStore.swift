import CryptoKit
import Foundation
import Security
import TeslaKit

/// Loads or creates the single device key Sentry uses as a car key.
///
/// On a device the private key lives in the Secure Enclave and the Keychain holds only its
/// device-bound handle. Where there is no Secure Enclave (the Simulator), a software P-256 key
/// is stored in the Keychain instead. Either way the item is `AfterFirstUnlockThisDeviceOnly`,
/// so it works while the phone is locked and never syncs or migrates off the device.
struct KeyStore {
    enum Failure: Error, Equatable {
        case keychain(OSStatus)
        case accessControl
        case unreadableItem
    }

    private enum Kind: UInt8 {
        case secureEnclave = 0x01
        case software = 0x02
    }

    private let service: String
    private let account = "default"

    init(service: String = "com.dodimead.sentry.vehicle-key") {
        self.service = service
    }

    func loadOrCreate() throws -> KeyAgreementKey {
        if let key = try load() { return key }
        let (key, data) = try makeKey()
        var attributes = baseQuery
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecValueData as String] = data
        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return key
        case errSecDuplicateItem:
            // Another caller stored a key first; theirs wins so everyone uses the same one.
            guard let stored = try load() else { throw Failure.keychain(status) }
            return stored
        default:
            throw Failure.keychain(status)
        }
    }

    func load() throws -> KeyAgreementKey? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        guard let data = result as? Data else { throw Failure.unreadableItem }
        return try decode(data)
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    /// Creates a fresh key and its storage form: one kind byte followed by the key's bytes.
    private func makeKey() throws -> (KeyAgreementKey, Data) {
        if SecureEnclave.isAvailable {
            guard let access = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, nil
            ) else { throw Failure.accessControl }
            let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
            return (SecureEnclaveKeyAgreementKey(key), Data([Kind.secureEnclave.rawValue]) + key.dataRepresentation)
        }
        let key = P256.KeyAgreement.PrivateKey()
        return (SoftwareKeyAgreementKey(key), Data([Kind.software.rawValue]) + key.rawRepresentation)
    }

    private func decode(_ data: Data) throws -> KeyAgreementKey {
        guard let first = data.first, let kind = Kind(rawValue: first) else { throw Failure.unreadableItem }
        let body = data.dropFirst()
        switch kind {
        case .secureEnclave:
            return SecureEnclaveKeyAgreementKey(try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: body))
        case .software:
            return SoftwareKeyAgreementKey(try P256.KeyAgreement.PrivateKey(rawRepresentation: body))
        }
    }
}
