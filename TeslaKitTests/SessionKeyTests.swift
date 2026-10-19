import CryptoKit
import Foundation
import Testing
@testable import TeslaKit

@Test func derivesSharedKeyK() throws {
    let client = SoftwareKeyAgreementKey(try .init(rawRepresentation: TestVectors.clientPrivateKey))
    let k = SessionKey(sharedSecretX: try client.sharedSecretX(peerPublicX963: TestVectors.vehiclePublicX963))
    #expect(k.keyBytes == TestVectors.sharedKeyK)
}

@Test func sessionInfoTagMatchesVector() {
    let k = SessionKey(keyBytesForTesting: TestVectors.sharedKeyK)
    let tag = k.sessionInfoTag(vin: TestVectors.vin,
        challenge: Data(hex: "1588d5a30eabc6f8fc9a951b11f6fd11"),
        encodedInfo: TestVectors.sessionInfoBytes)
    #expect(tag == Data(hex: "996c1fe38331be138f8039c194b14db2198846ed7d8251e6749284d7b32ea002"))
}

@Test func sealMatchesVectorWithFixedNonce() throws {
    let k = SessionKey(keyBytesForTesting: TestVectors.sharedKeyK)
    let aad = Data(SHA256.hash(data: TestVectors.hvacOnMetadata))
    let out = try k.seal(Data(hex: "120452020801"), aad: aad,
                         nonce: try .init(data: Data(hex: "dbf79447fa156674dae1caed")))
    #expect(out.ciphertext == Data(hex: "38038e8c0f2e"))
    #expect(out.tag == Data(hex: "c228e0ff64991481db3a7bbc133696c5"))
    #expect(try k.open(nonce: out.nonce, ciphertext: out.ciphertext, tag: out.tag, aad: aad) == Data(hex: "120452020801"))
}

@Test func openRejectsTamperedAAD() throws {
    let k = SessionKey(keyBytesForTesting: TestVectors.sharedKeyK)
    let aad = Data(SHA256.hash(data: TestVectors.hvacOnMetadata))
    let out = try k.seal(Data(hex: "120452020801"), aad: aad)
    var tampered = aad
    tampered[0] ^= 0x01
    #expect(throws: (any Error).self) {
        try k.open(nonce: out.nonce, ciphertext: out.ciphertext, tag: out.tag, aad: tampered)
    }
}
