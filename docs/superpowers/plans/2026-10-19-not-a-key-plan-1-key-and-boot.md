# Not a Key Plan 1 — Bluetooth Key & Toggle Boot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pair the iPhone as a Bluetooth key with the owner's Model Y and toggle the boot from an Action Button shortcut.

**Architecture:** A `TeslaKit` framework holds a Swift port of Tesla's vehicle-command BLE protocol: protobuf messages, metadata TLV, ECDH/AES-GCM sessions, framing, CoreBluetooth transport, and a `VehicleClient` actor. The `NotAKey` app target holds key storage, pairing UI, a temporary debug home screen, and the `ToggleBootIntent`. All protocol logic is unit-tested against Tesla's published test vectors and an in-process `FakeVehicle` before touching the real car.

**Tech Stack:** Swift 6, SwiftUI, iOS 18+, CoreBluetooth, CryptoKit (Secure Enclave), AppIntents, SwiftProtobuf 1.39.0, XcodeGen, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-19-sentry-design.md`

**Scope split:** This is Plan 1 of 2. Plan 2 adds lock/unlock/frunk/climate controls + intents, infotainment state (battery, climate), the "C · Minimal + drawer" home screen, and the "Require Face ID to unlock" setting. Plan 1's debug home screen is temporary and gets replaced in Plan 2.

**Protocol reference:** https://github.com/teslamotors/vehicle-command (Apache-2.0). Read `pkg/protocol/protocol.md` before Tasks 2–4. Go sources referenced below: `internal/authentication/{native,signer,peer,metadata,window}.go`, `pkg/vehicle/{vcsec,actions,security,state}.go`, `pkg/connector/ble/ble.go`.

## Global Constraints

- Repo `~/Development/not-a-key`, trunk branch `master`. XcodeGen-managed: edit `project.yml`, never hand-edit `NotAKey.xcodeproj`; run `xcodegen generate` after changing it.
- Deployment target iOS 18.0; `SWIFT_VERSION: "6.0"`; bundle id prefix `com.nevelen`.
- Only external dependency: `apple/swift-protobuf` pinned `from: 1.39.0` (must match the `protoc-gen-swift` used to generate code). Everything else is Apple frameworks.
- Tests: Swift Testing (`import Testing`, `@Test`, `#expect`). Run all with:
  `xcodebuild test -project NotAKey.xcodeproj -scheme NotAKey -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -quiet`
- BLE identifiers (verbatim): service `00000211-b2d1-43f0-9b88-960cebf8b91e`, write `00000212-b2d1-43f0-9b88-960cebf8b91e` (write **with** response), read/notify `00000213-b2d1-43f0-9b88-960cebf8b91e`.
- Every outgoing authenticated command sets `flags = 1 << FLAG_ENCRYPT_RESPONSE` (= 2) and uses AES-GCM (not HMAC). Command lifetime 5 s (Go `defaultExpiration`).
- Private key never leaves the device: Secure Enclave on device, software P-256 key in Keychain only where Secure Enclave is unavailable (Simulator). Keychain accessibility `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, no biometric flag. The key must work while the phone is locked.
- Pair with role `ROLE_DRIVER`, form factor `KEY_FORM_FACTOR_IOS_DEVICE` (builder's call recorded here: least privilege that covers every v1 command).
- No retry loops: VCSEC "busy" is retried every 1 s only until the overall deadline; stale-session faults get exactly one resync-and-retry.
- Intent copy (exact): success `"Opening boot"`, `"Closing boot"`, `"Moving boot"`; failures `"Car not in range"`, `"Key not paired"`, `"Bluetooth is off"`, `"Allow Bluetooth for Not a Key in Settings"`, `"Car busy, try again"`, `"Car didn't respond"`, `"Set up Not a Key first"`.

## Review Focus

1. **Car out of range or Bluetooth off when the Action Button is pressed** → the user sees "Car not in range" / "Bluetooth is off" within the 10 s scan timeout, never a hang. Pinned in Task 10 (`toggleBootReportsNotInRange`) and Task 12 (`messageForEveryError`).
2. **Car rebooted since the last session (epoch changed / counter desync)** → vehicle replies with a fault plus fresh session info; the client resyncs and retries once and the command succeeds. Pinned in Task 7 (`resyncsOnceOnStaleSession`).
3. **VCSEC busy (`OPERATIONSTATUS_WAIT`)** → retried every 1 s until it succeeds or the deadline passes, then "Car busy, try again". Pinned in Task 7 (`retriesWhileBusy`, `busyPastDeadlineThrowsBusy`).
4. **VIN typed with lowercase letters or spaces, or with invalid characters** → normalized to uppercase, no spaces; invalid VINs (wrong length, contains I/O/Q) are rejected before any scanning. Pinned in Task 10 (`vinNormalization`).
5. **Boot is mid-movement or its state is unknown** when toggled → still sends the move command, and the banner says "Moving boot" rather than guessing open/closed. Pinned in Task 10 (`toggleBootWording`).

---

## File Structure

```
sentry/
  project.yml
  Protos/                         # verbatim copies of Tesla .proto files + NOTICE
  scripts/gen-protos.sh           # regenerates TeslaKit/Proto/*.pb.swift
  TeslaKit/
    Proto/*.pb.swift              # generated, committed
    Crypto/Metadata.swift         # TLV metadata serializer
    Crypto/KeyAgreementKey.swift  # protocol + software + Secure Enclave impls
    Crypto/SessionKey.swift       # K derivation, HMAC subkeys, AES-GCM
    Session/DomainSession.swift   # per-domain signer state (epoch, counter, clock)
    Session/SlidingWindow.swift   # response anti-replay
    Transport/VehicleLocalName.swift
    Transport/Framing.swift       # length prefix, chunking, reassembly
    Transport/VehicleTransport.swift  # protocol
    Transport/BLETransport.swift  # CoreBluetooth
    Vehicle/VehicleCommand.swift  # command → (domain, payload)
    Vehicle/VCSECResponse.swift   # classify VCSEC replies, VehicleSnapshot
    Vehicle/VehicleError.swift
    Vehicle/VehicleClient.swift   # actor: handshake, execute, state, pairing
  TeslaKitTests/
    TestVectors.swift             # constants from protocol.md
    FakeVehicle.swift             # in-process car implementing VehicleTransport
    *Tests.swift
  NotAKey/
    NotAKeyApp.swift
    Car/VIN.swift
    Car/CarStore.swift            # @Observable: VIN, paired flag (UserDefaults)
    Car/KeyStore.swift            # load-or-create device key (Keychain / SE)
    Car/VehicleService.swift      # connect → run → close; toggleBoot()
    Onboarding/OnboardingView.swift
    Onboarding/PairingModel.swift
    Debug/DebugHomeView.swift     # temporary, replaced in Plan 2
    Intents/IntentMessages.swift
    Intents/ToggleBootIntent.swift
    Intents/NotAKeyShortcuts.swift
  NotAKeyTests/
    *Tests.swift
```

---

### Task 1: Project scaffold and generated protobufs

**Files:**
- Create: `project.yml`, `Protos/*.proto`, `Protos/NOTICE`, `scripts/gen-protos.sh`, `TeslaKit/Proto/*.pb.swift` (generated), `NotAKey/NotAKeyApp.swift`, `TeslaKitTests/ProtoSmokeTests.swift`
- Modify: `.gitignore` (add `NotAKey.xcodeproj/xcuserdata/`, `DerivedData/`)

**Interfaces:**
- Produces: module `TeslaKit` (framework) exposing generated types `UniversalMessage_RoutableMessage`, `Signatures_SessionInfo`, `VCSEC_UnsignedMessage`, `VCSEC_FromVCSECMessage`, `VCSEC_ToVCSECMessage`, `CarServer_Action`, `CarServer_Response`, etc. Generated with `--swift_opt=Visibility=Public`.

- [ ] **Step 1: Install generators**

Run: `brew install protobuf swift-protobuf && protoc-gen-swift --version`
Expected: `protoc-gen-swift 1.39.0`

- [ ] **Step 2: Copy protos**

Copy every `pkg/protocol/protobuf/*.proto` from a clone of `teslamotors/vehicle-command` (main) into `Protos/`, unmodified. `Protos/NOTICE` records the source URL, commit SHA, and Apache-2.0 license.

- [ ] **Step 3: Write `scripts/gen-protos.sh`**

Runs `protoc -I Protos --swift_out=TeslaKit/Proto --swift_opt=Visibility=Public Protos/*.proto`. Run it and commit the output.

- [ ] **Step 4: Write `project.yml`**

Model it on `~/Development/moor/project.yml`. Targets:
- `TeslaKit`: `framework`, sources `[TeslaKit]`, depends on package `SwiftProtobuf` (product `SwiftProtobuf`).
- `NotAKey`: `application`, sources `[NotAKey]`, depends on `TeslaKit` (embed). Info.plist keys via settings: `INFOPLIST_KEY_NSBluetoothAlwaysUsageDescription: "Not a Key uses Bluetooth to talk to your car."`, `INFOPLIST_KEY_UILaunchScreen_Generation: YES`. `UIBackgroundModes: [bluetooth-central]` via an `info:` properties block.
- `TeslaKitTests`: `bundle.unit-test` → `TeslaKit`.
- `NotAKeyTests`: `bundle.unit-test` → `NotAKey`.
- Scheme `NotAKey` tests both test targets.

`NotAKey/NotAKeyApp.swift` is a placeholder `WindowGroup { Text("Not a Key") }`.

- [ ] **Step 5: Write the smoke test**

```swift
@Test func routableMessageRoundTrips() throws {
    var msg = UniversalMessage_RoutableMessage()
    msg.toDestination.domain = .vehicleSecurity
    msg.uuid = Data(repeating: 1, count: 16)
    let decoded = try UniversalMessage_RoutableMessage(serializedBytes: msg.serializedData())
    #expect(decoded.toDestination.domain == .vehicleSecurity)
    #expect(decoded.uuid == msg.uuid)
}
```

- [ ] **Step 6: Generate and run**

Run: `xcodegen generate && xcodebuild test … (Global Constraints command)`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 7: Commit** — `chore: scaffold Not a Key app, TeslaKit framework and generated protobufs`

---

### Task 2: Metadata TLV and BLE local name

**Files:**
- Create: `TeslaKit/Crypto/Metadata.swift`, `TeslaKit/Transport/VehicleLocalName.swift`, `TeslaKitTests/TestVectors.swift`, `TeslaKitTests/MetadataTests.swift`

**Interfaces:**
- Produces:
  - `public struct Metadata { public init(); public mutating func add(_ tag: Signatures_Tag, _ value: Data) throws; public mutating func add(_ tag: Signatures_Tag, uint32: UInt32) throws; public func serialized() -> Data }`. `serialized()` appends terminal `0xFF`. `add` throws `MetadataError.outOfOrder` if the tag is lower than the last tag, and `MetadataError.tooLong` if the value is more than 255 bytes. A zero-length value is still encoded (tag, 0x00).
  - `public enum VehicleLocalName { public static func make(vin: String) -> String }`: `"S" + lowercase hex(SHA1(vin)[0..<8]) + "C"`.
  - `TestVectors` (test target): `vin = "5YJ30123456789ABC"`, `clientPrivateKey` (hex `2538CDC29A97C19C1E99A637D6CF4F8C970C118B56EDE1E6323E6D162C4B30DB`), `vehiclePrivateKey` (hex `344EE5B466A7CF1EEB12B6F50331DB2E5EC5834EF5F4BEFCFD8CBE55C2528D70`), `vehiclePublicX963` (`04` ‖ Vx ‖ Vy from protocol.md), `sharedKeyK = 1b2fce19967b79db696f909cff89ea9a`, `clientKey` (SoftwareKeyAgreementKey of clientPrivateKey), `sessionInfoBytes` (protocol.md example `session_info` hex), `handshakeResponse` (protocol.md example response as a RoutableMessage: routing address `2c907bd76c640d360b3027dc7404efde`, tag `996c…a002`, request_uuid `1588…fd11`), `hvacOnMetadata` (hex `000105010103021135594a333031323334353637383941424303104c463f9cc0d3d26906e982ed224adde6040400000a5f050400000007070400000002ff`), plus a `Data(hex:)` helper.

- [ ] **Step 1: Write failing tests**

```swift
@Test func serializesSortedTLVWithTerminator() throws {
    var m = Metadata()
    try m.add(.personalization, Data("abc".utf8))
    try m.add(.counter, uint32: 100)
    #expect(m.serialized() == Data(hex: "0203616263050400000064FF"))
}
@Test func rejectsOutOfOrderTags() {
    var m = Metadata()
    #expect(throws: MetadataError.outOfOrder) {
        try m.add(.counter, uint32: 1); try m.add(.domain, Data([2]))
    }
}
@Test func rejectsLongValues() {
    var m = Metadata()
    #expect(throws: MetadataError.tooLong) { try m.add(.personalization, Data(count: 256)) }
}
@Test func localNameMatchesSpec() {
    #expect(VehicleLocalName.make(vin: "5YJS0000000000000") == "S1a87a5a75f3df858C")
}
```

- [ ] **Step 2: Run, verify FAIL** (types not defined)
- [ ] **Step 3: Implement** `Metadata` and `VehicleLocalName` (SHA1 via `Insecure.SHA1`).
- [ ] **Step 4: Run, verify PASS**
- [ ] **Step 5: Commit** — `feat(teslakit): metadata TLV serializer and BLE local name`

---

### Task 3: Key agreement and session crypto

**Files:**
- Create: `TeslaKit/Crypto/KeyAgreementKey.swift`, `TeslaKit/Crypto/SessionKey.swift`, `TeslaKitTests/SessionKeyTests.swift`

**Interfaces:**
- Produces:
  - `public protocol KeyAgreementKey: Sendable { var publicKeyX963: Data { get }; func sharedSecretX(peerPublicX963: Data) throws -> Data }`. Returns the 32-byte big-endian shared X coordinate (CryptoKit `SharedSecret` raw bytes).
  - `public struct SoftwareKeyAgreementKey: KeyAgreementKey { public init(_ key: P256.KeyAgreement.PrivateKey) }`
  - `public struct SecureEnclaveKeyAgreementKey: KeyAgreementKey { public init(_ key: SecureEnclave.P256.KeyAgreement.PrivateKey) }`
  - `public struct SessionKey: Sendable { public init(sharedSecretX: Data); public var keyBytes: Data /*16 bytes*/; public func sessionInfoTag(vin: String, challenge: Data, encodedInfo: Data) -> Data; public func seal(_ plaintext: Data, aad: Data, nonce: AES.GCM.Nonce = .init()) throws -> (nonce: Data, ciphertext: Data, tag: Data); public func open(nonce: Data, ciphertext: Data, tag: Data, aad: Data) throws -> Data }`

Algorithms (from protocol.md; the implementer cannot guess these):
- `K = SHA1(sharedX)[0..<16]`, used as an AES-128-GCM key.
- `subkey(label) = HMAC-SHA256(key: K, data: label UTF-8)`.
- `sessionInfoTag` = `HMAC-SHA256(key: subkey("session info"), data: M ‖ encodedInfo)`, where `M` = Metadata{ signatureType: `[6]` (SIGNATURE_TYPE_HMAC), personalization: VIN, challenge }`.serialized()` (including `0xFF`).
- The AES-GCM AAD for commands and responses is `SHA256(metadata.serialized())`. The caller passes that hash as `aad`.

- [ ] **Step 1: Write failing tests (Tesla's vectors)**

```swift
@Test func derivesSharedKeyK() throws {
    let client = SoftwareKeyAgreementKey(try .init(rawRepresentation: TestVectors.clientPrivateKey))
    let k = SessionKey(sharedSecretX: try client.sharedSecretX(peerPublicX963: TestVectors.vehiclePublicX963))
    #expect(k.keyBytes == TestVectors.sharedKeyK)
}
@Test func sessionInfoTagMatchesVector() {
    let k = SessionKey(keyBytesForTesting: TestVectors.sharedKeyK)
    let tag = k.sessionInfoTag(vin: TestVectors.vin,
        challenge: Data(hex: "1588d5a30eabc6f8fc9a951b11f6fd11"),
        encodedInfo: TestVectors.sessionInfoBytes)   // "0806124104c7a1…255a0a0000" from protocol.md
    #expect(tag == Data(hex: "996c1fe38331be138f8039c194b14db2198846ed7d8251e6749284d7b32ea002"))
}
@Test func sealMatchesVectorWithFixedNonce() throws {
    let k = SessionKey(keyBytesForTesting: TestVectors.sharedKeyK)
    let aad = Data(SHA256.hash(data: TestVectors.hvacOnMetadata))   // "000105…070400000002ff"
    let out = try k.seal(Data(hex: "120452020801"), aad: aad,
                         nonce: try .init(data: Data(hex: "dbf79447fa156674dae1caed")))
    #expect(out.ciphertext == Data(hex: "38038e8c0f2e"))
    #expect(out.tag == Data(hex: "c228e0ff64991481db3a7bbc133696c5"))
    #expect(try k.open(nonce: out.nonce, ciphertext: out.ciphertext, tag: out.tag, aad: aad) == Data(hex: "120452020801"))
}
@Test func openRejectsTamperedAAD() throws { /* seal, then open with different aad → throws */ }
```

`init(keyBytesForTesting:)` is `internal`, reached via `@testable import TeslaKit`.

- [ ] **Step 2: Run, verify FAIL**
- [ ] **Step 3: Implement both files.** `SecureEnclaveKeyAgreementKey` mirrors the software impl, using `sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation:))`. It is not unit-tested, because the Simulator has no Secure Enclave; Task 11 verifies it on device.
- [ ] **Step 4: Run, verify PASS**
- [ ] **Step 5: Commit** — `feat(teslakit): ECDH session key, session-info HMAC, AES-GCM`

---

### Task 4: Domain session (signer state)

**Files:**
- Create: `TeslaKit/Session/DomainSession.swift`, `TeslaKit/Session/SlidingWindow.swift`, `TeslaKitTests/DomainSessionTests.swift`

**Interfaces:**
- Consumes: `Metadata`, `SessionKey`, `KeyAgreementKey` (Tasks 2–3).
- Produces:
  - `public struct DomainSession: Sendable`
    - `public static func handshakeRequest(domain: UniversalMessage_Domain, publicKeyX963: Data, routingAddress: Data, uuid: Data) -> UniversalMessage_RoutableMessage`
    - `public init(domain:, vin: String, key: KeyAgreementKey, challenge: Data, response: UniversalMessage_RoutableMessage, now: Date) throws`. It verifies `response.signatureData.sessionInfoTag.tag` against `sessionInfoTag(...)` with a constant-time compare, then parses `response.sessionInfo` as `Signatures_SessionInfo`. It sets `counter`, `epoch`, and `timeZero = now - clockTime`. It throws `VehicleError.protocolFault(.invalidSignature)` on a tag mismatch. If the response carries `signedMessageStatus.signedMessageFault != .errorNone`, it throws `VehicleError.from(fault:)` (Task 6).
    - `public mutating func encrypt(_ message: inout UniversalMessage_RoutableMessage, now: Date, lifetime: TimeInterval = 5) throws -> Data`. It increments the counter and sets `flags = 2`. Metadata, in tag order: signatureType `[5]`, domain `[domain]`, personalization VIN, epoch, expiresAt (uint32 `now + lifetime − timeZero`, whole seconds), counter, and flags (only if non-zero). AAD = SHA256(metadata). It replaces the payload with ciphertext and fills `signatureData.signerIdentity.publicKey` and `signatureData.aesGcmPersonalizedData{epoch, nonce, counter, expiresAt, tag}`. It **returns the request hash** `[5] ‖ tag`.
    - `public mutating func decryptResponse(_ message: inout UniversalMessage_RoutableMessage, requestHash: Data) throws`. If `signatureData.aesGcmResponseData` is absent, it's a no-op (plaintext reply). Otherwise metadata is: signatureType `[9]`, domain `[message.fromDestination.domain]`, personalization VIN, counter (response counter), flags (response `message.flags`, **always** included), requestHash, and fault (uint32 of `signedMessageStatus.signedMessageFault`). It decrypts in place and rejects a replayed counter via `SlidingWindow`.
    - `public mutating func resync(from info: Signatures_SessionInfo, now: Date)`. Per protocol.md "Recovering from synchronization errors": never roll the counter back within the same epoch.
  - `struct SlidingWindow { mutating func accept(_ counter: UInt32) -> Bool }`, ported from `window.go` (window size 32).

- [ ] **Step 1: Write failing tests**

```swift
@Test func acceptsVectorHandshake() throws {
    // response = protocol.md example (session_info bytes + tag 996c…, uuid 1588…)
    let s = try DomainSession(domain: .infotainment, vin: TestVectors.vin, key: TestVectors.clientKey,
        challenge: Data(hex: "1588d5a30eabc6f8fc9a951b11f6fd11"), response: TestVectors.handshakeResponse, now: .init(timeIntervalSince1970: 10_000))
    #expect(s.counter == 6); #expect(s.epoch == Data(hex: "4c463f9cc0d3d26906e982ed224adde6"))
}
@Test func rejectsTamperedHandshake() { /* flip one byte of tag → throws .protocolFault(.errorInvalidSignature) */ }
@Test func encryptBuildsVectorMetadata() throws {
    // session from vector, now = timeZero + 2650 s, lifetime 5 → expiresAt 2655, counter 6→7, flags 2
    // payload 120452020801; capture AAD via internal hook → equals SHA256(TestVectors.hvacOnMetadata)
    // message.signatureData.aesGcmPersonalizedData.counter == 7, .expiresAt == 2655, message.flags == 2
}
@Test func decryptResponseRoundTrip() throws { /* build an AES_GCM_RESPONSE reply with test helper, decrypt → plaintext; replay same counter → throws */ }
@Test func resyncNeverRollsCounterBackInSameEpoch() { /* counter 10, resync with counter 4 same epoch → counter stays 10; new epoch → takes new counter */ }
@Test func slidingWindowRejectsReplays() { /* 5 ok, 5 no, 3 ok, 3 no, 40 ok, 7 no (too old) */ }
```

`TestVectors.handshakeResponse` builds the RoutableMessage from protocol.md's example response. `TestVectors.clientKey` wraps `clientPrivateKey`.

- [ ] **Step 2: Run, verify FAIL**
- [ ] **Step 3: Implement.** Inject a test-only `internal var aadObserver: ((Data) -> Void)?` hook, or expose `internal func commandMetadata(...) -> Data` for the vector assertion.
- [ ] **Step 4: Run, verify PASS**
- [ ] **Step 5: Commit** — `feat(teslakit): per-domain session with AES-GCM command signing and response decryption`

---

### Task 5: BLE framing

**Files:**
- Create: `TeslaKit/Transport/Framing.swift`, `TeslaKitTests/FramingTests.swift`

**Interfaces:**
- Produces:
  - `public enum Framing { public static func chunks(for message: Data, blockLength: Int) -> [Data] }`. Prefixes a 2-byte big-endian length, then splits into `blockLength`-sized writes.
  - `public struct FrameReassembler { public init(); public mutating func append(_ chunk: Data, at time: Date) -> [Data] }`. Returns zero or more complete messages. If more than 1 s has passed since the previous chunk, it discards the buffer first. A declared length over 1024 clears the buffer.

- [ ] **Step 1: Failing tests:** `chunksPrefixLength` (300-byte message, block 182 → 2 chunks, first starts `0x01 0x2C`); `reassemblesSplitMessage`; `reassemblesTwoMessagesInOneChunk`; `dropsStaleBufferAfterOneSecond`; `dropsOversizedDeclaredLength`.
- [ ] **Step 2: Run, verify FAIL** · **Step 3: Implement** · **Step 4: PASS**
- [ ] **Step 5: Commit** — `feat(teslakit): BLE length-prefixed framing`

---

### Task 6: Commands, VCSEC responses and errors

**Files:**
- Create: `TeslaKit/Vehicle/VehicleCommand.swift`, `TeslaKit/Vehicle/VCSECResponse.swift`, `TeslaKit/Vehicle/VehicleError.swift`, `TeslaKitTests/CommandTests.swift`

**Interfaces:**
- Produces:
  - `public enum VehicleCommand: Sendable { case moveTrunk, openFrunk, lock, unlock, wake, climateOn, climateOff }` with `var domain: UniversalMessage_Domain` and `func payload() throws -> Data`. Payloads mirror the Go sources:
    - moveTrunk → `VCSEC_UnsignedMessage.closureMoveRequest.rearTrunk = .closureMoveTypeMove`
    - openFrunk → `.frontTrunk = .closureMoveTypeMove`
    - lock / unlock / wake → `.rkeaction = .rkeActionLock` / `.rkeActionUnlock` / `.rkeActionWakeVehicle`
    - climateOn / Off → `CarServer_Action.vehicleAction.hvacAutoAction.powerOn = true / false` (infotainment)
    (Plan 1 uses only moveTrunk; the rest are cheap to define now and are exercised in Plan 2.)
  - `public static func bodyControllerStatePayload() throws -> Data`, which builds `VCSEC_UnsignedMessage.informationRequest.informationRequestType = .getStatus`.
  - `public static func addKeyEnvelope(publicKeyX963: Data) throws -> Data`, which serializes `VCSEC_ToVCSECMessage{ signedMessage{ protobufMessageAsBytes: UnsignedMessage{ whitelistOperation{ addKeyToWhitelistAndAddPermissions{ key.publicKeyRaw, keyRole: .roleDriver }, metadataForKey.keyFormFactor: .iosDevice } }, signatureType: .presentKey } }`. These are raw bytes, not wrapped in a RoutableMessage.
  - `public enum VCSECReply { case done(VCSEC_FromVCSECMessage), pending, busy }` with `static func classify(_ msg: VCSEC_FromVCSECMessage) throws -> VCSECReply`, following protocol.md "VCSEC application-layer responses" and Go `unmarshalVCSECResponse`:
    - `nominalError` → throw `.rejected(description)`
    - `commandStatus.operationStatus == .wait` → `.busy`
    - other `commandStatus` → `.pending` (keep reading)
    - empty message or `vehicleStatus` → `.done`
  - `public struct VehicleSnapshot: Sendable, Equatable { public var isLocked: Bool; public var rearTrunk: ClosureState; public var frontTrunk: ClosureState; public var isAsleep: Bool }` with `public enum ClosureState { case closed, open, ajar, opening, closing, unknown }` and `init(_ status: VCSEC_VehicleStatus)`. `failedUnlatch` maps to `.unknown`, and `internalLocked` counts as locked.
  - `public enum VehicleError: Error, Equatable, Sendable { case bluetoothOff, bluetoothUnauthorized, notInRange, notPaired, busy, timeout, rejected(String), protocolFault(UniversalMessage_MessageFault_E) }` and `static func from(fault:) -> VehicleError`. `.errorUnknownKeyID` and `.errorInactiveKey` map to `.notPaired`; `.errorBusy` maps to `.busy`; everything else maps to `.protocolFault`.

- [ ] **Step 1: Failing tests:**
  - `climateOnMatchesVector`: `VehicleCommand.climateOn.payload() == Data(hex: "120452020801")`
  - `moveTrunkPayload`: decodes back to `rearTrunk == .closureMoveTypeMove` with `domain == .vehicleSecurity`
  - `addKeyEnvelopeShape`: role `.roleDriver`, form factor `.iosDevice`, key bytes, signature type `.presentKey`
  - `classifyWaitIsBusy`, `classifyEmptyIsDone`, `classifyNominalErrorThrows`
  - `snapshotMapping`: rearTrunk `.closurestateOpen` → `.open`, lock state `.vehiclelockstateInternalLocked` → `isLocked`, sleep `.asleep` → `isAsleep`
  - `faultMapping`: unknownKeyID → `.notPaired`
- [ ] **Step 2: Run, verify FAIL** · **Step 3: Implement** · **Step 4: PASS**
- [ ] **Step 5: Commit** — `feat(teslakit): command payloads, VCSEC reply classification, snapshot and errors`

---

### Task 7: VehicleClient actor with FakeVehicle

**Files:**
- Create: `TeslaKit/Transport/VehicleTransport.swift`, `TeslaKit/Vehicle/VehicleClient.swift`, `TeslaKitTests/FakeVehicle.swift`, `TeslaKitTests/VehicleClientTests.swift`

**Interfaces:**
- Consumes: Tasks 2–6.
- Produces:
  - `public protocol VehicleTransport: AnyObject, Sendable { func send(_ message: Data) async throws; var incoming: AsyncStream<Data> { get }; func close() }`. Messages are whole, already de-framed.
  - `public actor VehicleClient`
    - `public init(vin: String, key: KeyAgreementKey, transport: VehicleTransport, now: @escaping @Sendable () -> Date = Date.init, busyRetryInterval: Duration = .seconds(1))`. It generates a random 16-byte routing address.
    - `public func bodyControllerState(deadline: Duration = .seconds(5)) async throws -> VehicleSnapshot`: unauthenticated, VCSEC, no handshake.
    - `public func execute(_ command: VehicleCommand, deadline: Duration = .seconds(8)) async throws`: lazily handshakes the command's domain, encrypts, sends, and reads replies until terminal.
    - `public func sendAddKeyRequest(publicKeyX963: Data) async throws`: sends `VehicleCommand.addKeyEnvelope` raw. Doesn't wait.
    - `public func waitForPairing(timeout: Duration = .seconds(120), pollEvery: Duration = .seconds(2)) async throws`: repeats the INFOTAINMENT handshake until it succeeds (the key is enrolled). It throws `.timeout` when the time is up. A `.notPaired` result means keep polling.

  Behaviour the tests pin:
  - It only consumes incoming messages whose `toDestination.routingAddress` equals its own; others are ignored (the official Tesla app shares the car).
  - One request is in flight at a time (VCSEC can't handle concurrent requests).
  - If a reply carries `signedMessageStatus.signedMessageFault` in {`.errorInvalidSignature`, `.errorInvalidTokenOrCounter`, `.errorIncorrectEpoch`, `.errorTimeExpired`} and has `sessionInfo`, it calls `resync` and retries **once**.
  - `.busy` → wait `busyRetryInterval`, resend (new counter), until the deadline → then throw `.busy`.
  - No reply before the deadline → `.timeout`.
- `FakeVehicle: VehicleTransport` (test target) plays the car using `TestVectors.vehiclePrivateKey`:
  - It answers session-info requests with a properly tagged `SessionInfo` (computed through `SessionKey`, with its own epoch, counter and clock).
  - It decrypts commands, checks metadata, and records the decoded `VCSEC_UnsignedMessage` / `CarServer_Action`.
  - It replies from a script: `.success`, `.busy(times: n)`, `.nominalError`, `.staleSessionOnce`, `.unknownKey`, `.silent`, `.pairAfter(polls: n)`.
  - It replies in plaintext (no response encryption). Task 4 already covers decrypting encrypted responses.
  - `bodyStatus: VCSEC_VehicleStatus` is configurable.
  - It can inject a foreign message addressed to another routing address.

- [ ] **Step 1: Failing tests:**
  - `executesMoveTrunk`: fake records `closureMoveRequest.rearTrunk == .closureMoveTypeMove`
  - `readsBodyControllerStateWithoutHandshake`: no session-info request seen; snapshot matches fake
  - `retriesWhileBusy`: `.busy(times: 2)` → succeeds; fake saw 3 commands with strictly increasing counters
  - `busyPastDeadlineThrowsBusy`: `.busy(times: 100)`, deadline 3 s, retry interval 1 s → throws `.busy`
  - `resyncsOnceOnStaleSession`: `.staleSessionOnce` → succeeds on second attempt
  - `unknownKeyThrowsNotPaired`
  - `silentCarTimesOut`: deadline 1 s → `.timeout`
  - `ignoresForeignRoutingAddress`: a foreign success reply arrives first and is ignored; the real reply completes the call
  - `waitForPairingSucceedsAfterApproval`: `.pairAfter(polls: 3)` with pollEvery 10 ms → returns
- [ ] **Step 2: Run, verify FAIL** · **Step 3: Implement** · **Step 4: PASS** (run 3×, with no flakes)
- [ ] **Step 5: Commit** — `feat(teslakit): VehicleClient actor with handshake, retry, resync and pairing poll`

---

### Task 8: CoreBluetooth transport

**Files:**
- Create: `TeslaKit/Transport/BLETransport.swift`, `TeslaKitTests/BLETransportTests.swift`

**Interfaces:**
- Consumes: `VehicleTransport`, `Framing`, `FrameReassembler`, `VehicleLocalName`.
- Produces: `public final class BLETransport: NSObject, VehicleTransport` with `public static func connect(vin: String, scanTimeout: Duration = .seconds(10)) async throws -> BLETransport`.
  - Uses its own `CBCentralManager` on a private serial queue.
  - Waits for `.poweredOn`: `.poweredOff` → throws `.bluetoothOff`; `.unauthorized` → `.bluetoothUnauthorized`.
  - Scans for service UUID `…0211…`, matches `CBAdvertisementDataLocalNameKey == VehicleLocalName.make(vin:)`. Timeout → `.notInRange`.
  - After connect, discovers the service and the `…0212…`/`…0213…` characteristics, then subscribes to `…0213…`.
  - `blockLength = peripheral.maximumWriteValueLength(for: .withResponse)`. Each chunk is written `.withResponse`, awaiting `didWriteValueFor` before the next.
  - Notifications feed a `FrameReassembler` into `incoming`. `close()` cancels the connection and finishes the stream.
  - Write the matching logic as a pure `static func matches(advertisement: [String: Any], vin: String) -> Bool` so it can be tested.

- [ ] **Step 1: Failing tests:** `matchesAdvertisedLocalName` (correct name → true, other VIN's name → false, missing key → false).
- [ ] **Step 2: FAIL** · **Step 3: Implement** · **Step 4: PASS**, then confirm the whole scheme builds for a generic iOS device: `xcodebuild build -project NotAKey.xcodeproj -scheme NotAKey -destination 'generic/platform=iOS' -quiet` → `** BUILD SUCCEEDED **`
- [ ] **Step 5: Commit** — `feat(teslakit): CoreBluetooth transport`

---

### Task 9: Device key storage

**Files:**
- Create: `NotAKey/Car/KeyStore.swift`, `NotAKeyTests/KeyStoreTests.swift`

**Interfaces:**
- Consumes: `KeyAgreementKey`, `SoftwareKeyAgreementKey`, `SecureEnclaveKeyAgreementKey`.
- Produces: `struct KeyStore { init(service: String = "com.nevelen.notakey.vehicle-key"); func loadOrCreate() throws -> KeyAgreementKey; func load() throws -> KeyAgreementKey?; func delete() throws }`.
  - When `SecureEnclave.isAvailable`, it creates `SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, nil))` and stores its `dataRepresentation`.
  - Otherwise it creates a software key and stores its `rawRepresentation`.
  - Storage is a Keychain generic password (service as given, account `"default"`, accessibility `AfterFirstUnlockThisDeviceOnly`), with a 1-byte kind prefix (`0x01` SE, `0x02` software).

- [ ] **Step 1: Failing tests** (unique service per test, deleted in teardown): `loadOrCreateIsStable` (same `publicKeyX963` twice), `loadReturnsNilWhenEmpty`, `deleteRemovesKey`, `keyAgreesWithPeer` (shared secret with a fresh software peer matches the peer's side).
- [ ] **Step 2: FAIL** · **Step 3: Implement** · **Step 4: PASS**
- [ ] **Step 5: Commit** — `feat(app): device key storage in Secure Enclave / Keychain`

---

### Task 10: App shell — VIN, onboarding, pairing, toggle logic, debug home

**Files:**
- Create: `NotAKey/Car/VIN.swift`, `NotAKey/Car/CarStore.swift`, `NotAKey/Car/VehicleService.swift`, `NotAKey/Onboarding/OnboardingView.swift`, `NotAKey/Onboarding/PairingModel.swift`, `NotAKey/Debug/DebugHomeView.swift`, `NotAKeyTests/VINTests.swift`, `NotAKeyTests/VehicleServiceTests.swift`
- Modify: `NotAKey/NotAKeyApp.swift`, `project.yml` (add `TeslaKitTests/FakeVehicle.swift` + `TestVectors.swift` to `NotAKeyTests` sources so the fake is shared)

**Interfaces:**
- Consumes: `VehicleClient`, `BLETransport`, `VehicleTransport`, `VehicleSnapshot`, `VehicleError`, `KeyStore`.
- Produces:
  - `enum VIN { static func normalize(_ raw: String) -> String? }`: uppercases and strips whitespace. It returns nil unless the result is 17 characters from `[A-HJ-NPR-Z0-9]`.
  - `@Observable @MainActor final class CarStore { var vin: String?; var isPaired: Bool }`, persisted in `UserDefaults.standard` (keys `sentry.vin`, `sentry.paired`).
  - `enum BootToggleOutcome: Equatable { case opening, closing, moving }`
  - `struct VehicleService: Sendable { init(vin: String, key: KeyAgreementKey, connect: @escaping @Sendable (String) async throws -> VehicleTransport = { try await BLETransport.connect(vin: $0) }); func withClient<T: Sendable>(_ body: @Sendable (VehicleClient) async throws -> T) async throws -> T; func toggleBoot() async throws -> BootToggleOutcome; func snapshot() async throws -> VehicleSnapshot }`. `withClient` always closes the transport. `toggleBoot` reads `bodyControllerState`; it returns `.opening` if rearTrunk is `.closed`, `.closing` if `.open`/`.ajar`, and `.moving` otherwise, then executes `.moveTrunk`.
  - `@Observable @MainActor final class PairingModel { enum Phase { case enterVIN, connecting, tapCard, done, failed(String) }; func start(vin: String) async }`: normalizes the VIN → `loadOrCreate` key → connect → `sendAddKeyRequest` → phase `.tapCard` → `waitForPairing` → sets `CarStore.isPaired`.
  - UI: `OnboardingView` shows a VIN field and Pair button, then the phase copy (`.tapCard`: "Tap your key card on the centre console, then confirm on the car's screen."). `DebugHomeView` shows the snapshot fields, a "Refresh" button, a "Toggle Boot" button, the last error, and "Re-pair" (deletes key, clears paired flag). `NotAKeyApp` routes to onboarding until paired.

- [ ] **Step 1: Failing tests:**

```swift
@Test("vinNormalization", arguments: [
    (" 7saygdee5ta123456 ", "7SAYGDEE5TA123456"),
    ("7SAYGDEE5TA12345", nil),        // 16 chars
    ("7SAYGDEE5TA12345O", nil),       // contains O
])
func vinNormalization(raw: String, expected: String?) { #expect(VIN.normalize(raw) == expected) }

@Test("toggleBootWording", arguments: [
    (VCSEC_ClosureState_E.closurestateClosed, BootToggleOutcome.opening),
    (.closurestateOpen, .closing), (.closurestateAjar, .closing),
    (.closurestateOpening, .moving), (.closurestateUnknown, .moving),
])
func toggleBootWording(state: VCSEC_ClosureState_E, expected: BootToggleOutcome) async throws {
    // FakeVehicle with rearTrunk = state → toggleBoot() == expected, and fake recorded a moveTrunk
}

@Test func toggleBootReportsNotInRange() async {
    let service = VehicleService(vin: "…", key: TestVectors.clientKey, connect: { _ in throw VehicleError.notInRange })
    await #expect(throws: VehicleError.notInRange) { try await service.toggleBoot() }
}
@Test func withClientClosesTransportOnError() async { /* fake records close() after .unknownKey */ }
```

- [ ] **Step 2: FAIL** · **Step 3: Implement** · **Step 4: PASS**
- [ ] **Step 5: Run app in Simulator** (`xcodebuild build … iPhone 17 Pro` then launch): onboarding shows, an invalid VIN is rejected inline, and Pair with a valid VIN ends at "Bluetooth is off"/"Car not in range" (no car in Simulator), with no crash.
- [ ] **Step 6: Commit** — `feat(app): onboarding, pairing flow, boot toggle service and debug home`

---

### Task 11: HARDWARE CHECKPOINT — real car (owner present)

No code unless something fails. This is the spec's de-risking spike. **Stop and get the owner.**

- [ ] **Step 1:** Install on the owner's iPhone. In Xcode, select the device and the team from the owner's Apple Developer account, then Run.
- [ ] **Step 2: Pair.** Sit in the car, enter the VIN (from the car's Controls → Software screen), and tap Pair. Then tap the key card on the console and confirm on the car screen. Expect: Debug home appears. Record how long pairing took.
- [ ] **Step 3: State.** Tap Refresh. Expect lock and boot state to match reality, open the boot by hand, and Refresh shows `open`.
- [ ] **Step 4: Toggle.** Use Toggle Boot ×4 from the debug screen: the boot alternates open/close. Record the button-to-motion latency for each, with the official Tesla app installed and its phone key active.
- [ ] **Step 5: Asleep car.** After the car has slept (≥15 min untouched), Toggle Boot again. Expect it to work. If it doesn't, add a `.wake` execute before `.moveTrunk` when `snapshot.isAsleep`, with a test in `VehicleServiceTests`.
- [ ] **Step 6:** Record the findings (latencies, any failures and fixes) in `docs/superpowers/notes/2026-10-hardware-checkpoint.md` and commit — `docs: hardware checkpoint results`.

Fix any protocol discrepancy found here with a failing unit test first (systematic-debugging), never by guesswork on the car.

---

### Task 12: Toggle Boot intent and Action Button

**Files:**
- Create: `NotAKey/Intents/IntentMessages.swift`, `NotAKey/Intents/ToggleBootIntent.swift`, `NotAKey/Intents/NotAKeyShortcuts.swift`, `NotAKeyTests/IntentMessagesTests.swift`

**Interfaces:**
- Consumes: `VehicleService`, `BootToggleOutcome`, `VehicleError`, `KeyStore`, `CarStore` persisted keys (read `UserDefaults` directly, since intents run off the main actor).
- Produces:
  - `enum IntentMessages { static func success(_ o: BootToggleOutcome) -> String; static func failure(_ e: Error) -> String }`. Copy comes verbatim from Global Constraints. Any error that isn't a `VehicleError`, and `.timeout`/`.protocolFault`/`.rejected`, map to `"Car didn't respond"`. Missing VIN, missing key, or not paired → `"Set up Not a Key first"`.
  - `struct ToggleBootIntent: AppIntent`: `title "Toggle Boot"`, `openAppWhenRun = false`, `authenticationPolicy = .alwaysAllowed` (owner decision: works while locked). `perform() async throws -> some IntentResult & ProvidesDialog` always returns `.result(dialog: IntentDialog(stringLiteral: message))` with the success or failure copy. It doesn't throw for vehicle errors, so the banner shows the reason. Overall deadline is 15 s.
  - `struct NotAKeyShortcuts: AppShortcutsProvider` exposes `ToggleBootIntent` with phrases `"Toggle boot with \(.applicationName)"`, `"Open boot with \(.applicationName)"`, system image `car.rear`.

- [ ] **Step 1: Failing tests:** `successCopy` (three outcomes → exact strings); `messageForEveryError` (each `VehicleError` case → its exact string per Global Constraints, `.bluetoothUnauthorized` → `"Allow Bluetooth for Not a Key in Settings"`, `.busy` → `"Car busy, try again"`, `.notPaired` → `"Key not paired"`, `.timeout` → `"Car didn't respond"`).
- [ ] **Step 2: FAIL** · **Step 3: Implement** · **Step 4: PASS**, and run the full suite.
- [ ] **Step 5: Device test (owner)**
  1. Settings → Action Button → Shortcut → Not a Key "Toggle Boot".
  2. Next to the car, with the phone **locked** in a pocket, press the Action Button. Boot opens and the banner reads "Opening boot". Press again: it closes and reads "Closing boot".
  3. Walk out of range and press. The banner reads "Car not in range" within about 10 s.
  4. **Haptics:** note whether iOS plays a haptic on the intent result. If none, try `UINotificationFeedbackGenerator` inside `perform()` and record whether it fires from a background intent. Keep it only if it works; the banner is the guaranteed feedback (spec risk 3).
  5. Record the latency of the pocket-press path in the checkpoint notes.
- [ ] **Step 6: Commit** — `feat(app): Toggle Boot App Intent for the Action Button`

---

## Self-review notes

- Spec coverage for Plan 1: pairing ✔ (T6/7/9/10/11), Action Button toggle + banner + failure reasons ✔ (T10/12), offline BLE ✔ (T8), Secure Enclave key usable while locked ✔ (T9/12), coexistence with the Tesla app ✔ (T7 routing filter, T11 latency), transport abstraction for a future Fleet API ✔ (`VehicleTransport`). Deferred to Plan 2 by design: lock/unlock/frunk/climate UI and intents, infotainment state (battery/climate), wake-on-open refresh model, the C home screen, and the Face ID unlock toggle.
- Haptics are a verify-on-device step (T12) because iOS behaviour for background intents can't be decided up front.
