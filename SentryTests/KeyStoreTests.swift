import CryptoKit
import Foundation
import Testing
import TeslaKit
@testable import Sentry

struct KeyStoreTests {
    /// A unique service per test so runs never share or clobber the app's real key.
    let store = KeyStore(service: "com.dodimead.sentry.tests.\(UUID().uuidString)")

    @Test func loadOrCreateIsStable() throws {
        defer { try? store.delete() }
        let first = try store.loadOrCreate()
        let second = try store.loadOrCreate()
        #expect(first.publicKeyX963 == second.publicKeyX963)
        #expect(try store.load()?.publicKeyX963 == first.publicKeyX963)
    }

    @Test func loadReturnsNilWhenEmpty() throws {
        defer { try? store.delete() }
        #expect(try store.load() == nil)
    }

    @Test func deleteRemovesKey() throws {
        defer { try? store.delete() }
        _ = try store.loadOrCreate()
        try store.delete()
        #expect(try store.load() == nil)
        try store.delete()  // deleting nothing is not an error
    }

    @Test func keyAgreesWithPeer() throws {
        defer { try? store.delete() }
        let key = try store.loadOrCreate()
        let peer = SoftwareKeyAgreementKey(P256.KeyAgreement.PrivateKey())
        let ours = try key.sharedSecretX(peerPublicX963: peer.publicKeyX963)
        let theirs = try peer.sharedSecretX(peerPublicX963: key.publicKeyX963)
        #expect(ours.count == 32)
        #expect(ours == theirs)
    }
}
