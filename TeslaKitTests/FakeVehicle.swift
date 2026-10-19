import CryptoKit
import Foundation
import Synchronization
@testable import TeslaKit

/// An in-process car for `VehicleClient` tests. It holds `TestVectors.vehiclePrivateKey`,
/// answers session-info requests with properly tagged `SessionInfo`, verifies and decrypts
/// commands as the real verifier would (epoch, counter, AES-GCM over the metadata), records
/// what it decoded, and replies according to its script. Replies to commands that set
/// `FLAG_ENCRYPT_RESPONSE` are encrypted, as new firmware does.
final class FakeVehicle: VehicleTransport {
    enum Script: Sendable {
        case success
        /// Replies `OPERATIONSTATUS_WAIT` to the first `times` commands.
        case busy(times: Int)
        case nominalError
        /// Reboots (new epoch) before the first command, so it faults with fresh session info.
        case staleSessionOnce
        /// Reboots before every command, so every command faults with fresh session info.
        case staleSessionAlways
        /// Faults every session-info request with `ERROR_UNKNOWN_KEY_ID`.
        case unknownKey
        /// Never replies.
        case silent
        /// Reports `KEY_NOT_ON_WHITELIST` for the first `polls` infotainment handshakes.
        case pairAfter(polls: Int)
        /// Answers infotainment actions with `OPERATIONSTATUS_ERROR` and `reason`.
        case rejectsAction(reason: String)
        /// Answers infotainment actions with an action status this client does not know, and no data.
        case unrecognisedActionStatus
    }

    struct Command: Sendable {
        var domain: UniversalMessage_Domain
        var counter: UInt32
        var vcsec: VCSEC_UnsignedMessage?
        var carServer: CarServer_Action?
    }

    private struct DomainState {
        var epoch = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        var counter: UInt32 = 0
        var responseCounter: UInt32 = 0
        var clockZero = Date()
        var sessionKey: SessionKey?
        var clientPublicKey = Data()
    }

    private struct State {
        var script: Script
        var bodyStatus = VCSEC_VehicleStatus()
        var chargeState = CarServer_ChargeState()
        var climateState = CarServer_ClimateState()
        var driveState = CarServer_DriveState()
        var unansweredWhileAsleep = 0
        var ignoresWake = false
        var encryptedRepliesSent = 0
        var domains: [UniversalMessage_Domain: DomainState] = [:]
        var sessionInfoRequests: [UniversalMessage_Domain] = []
        var commands: [Command] = []
        var statusRequests = 0
        var addKeyRequests: [VCSEC_ToVCSECMessage] = []
        var staleFaultsSent = 0
        var infotainmentHandshakes = 0
        var busyRepliesSent = 0
        var rebooted = false
        var foreignReplyPending = false
        var corruptReplyPending = false
        var awaitingReply = false
        var requestsReceived = 0
        var overlappingRequests = 0
        var isClosed = false
    }

    private let vin: String
    private let privateKey: P256.KeyAgreement.PrivateKey
    private let replyDelay: Duration
    private let state: Mutex<State>
    /// The current connection's stream; `reconnected()` starts a new one.
    private let link: Mutex<(stream: AsyncStream<Data>, continuation: AsyncStream<Data>.Continuation)>
    private var continuation: AsyncStream<Data>.Continuation { link.withLock { $0.continuation } }
    var incoming: AsyncStream<Data> { link.withLock { $0.stream } }

    init(script: Script = .success, vin: String = TestVectors.vin, replyDelay: Duration = .zero) {
        self.vin = vin
        self.replyDelay = replyDelay
        privateKey = try! P256.KeyAgreement.PrivateKey(rawRepresentation: TestVectors.vehiclePrivateKey)
        state = Mutex(State(script: script))
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        link = Mutex((stream, continuation))
    }

    /// This car as a new connection, for tests that connect more than once: a closed fake gets a
    /// fresh stream and keeps its state, so each `VehicleService` call can connect again.
    func reconnected() -> FakeVehicle {
        state.withLock { state in
            guard state.isClosed else { return }
            state.isClosed = false
            state.awaitingReply = false
            link.withLock { $0 = AsyncStream<Data>.makeStream() }
        }
        return self
    }

    // MARK: Test configuration and observations

    var bodyStatus: VCSEC_VehicleStatus {
        get { state.withLock { $0.bodyStatus } }
        set { state.withLock { $0.bodyStatus = newValue } }
    }

    /// Climate state returned to `getClimateState`.
    var climateState: CarServer_ClimateState {
        get { state.withLock { $0.climateState } }
        set { state.withLock { $0.climateState = newValue } }
    }

    /// Drive state returned to `getDriveState`.
    var driveState: CarServer_DriveState {
        get { state.withLock { $0.driveState } }
        set { state.withLock { $0.driveState = newValue } }
    }

    /// Charge state returned to `getChargeState`.
    var chargeState: CarServer_ChargeState {
        get { state.withLock { $0.chargeState } }
        set { state.withLock { $0.chargeState = newValue } }
    }

    /// Whether infotainment is asleep: VCSEC reports it, and infotainment ignores session-info
    /// requests until a VCSEC wake command arrives.
    var isAsleep: Bool {
        get { state.withLock { $0.bodyStatus.vehicleSleepStatus == .vehicleSleepStatusAsleep } }
        set { state.withLock { $0.bodyStatus.vehicleSleepStatus = newValue ? .vehicleSleepStatusAsleep : .vehicleSleepStatusAwake } }
    }

    /// Whether a wake command leaves the car asleep, as if it were slow to wake.
    var ignoresWake: Bool {
        get { state.withLock { $0.ignoresWake } }
        set { state.withLock { $0.ignoresWake = newValue } }
    }

    var sessionInfoRequests: [UniversalMessage_Domain] { state.withLock { $0.sessionInfoRequests } }
    /// Infotainment session-info requests ignored because the car was asleep.
    var unansweredWhileAsleep: Int { state.withLock { $0.unansweredWhileAsleep } }
    /// Replies sent encrypted with AES-GCM, including interim VCSEC replies.
    var encryptedRepliesSent: Int { state.withLock { $0.encryptedRepliesSent } }
    /// Commands that decrypted and verified, in arrival order.
    var commands: [Command] { state.withLock { $0.commands } }
    var statusRequests: Int { state.withLock { $0.statusRequests } }
    var addKeyRequests: [VCSEC_ToVCSECMessage] { state.withLock { $0.addKeyRequests } }
    var staleFaultsSent: Int { state.withLock { $0.staleFaultsSent } }
    var busyRepliesSent: Int { state.withLock { $0.busyRepliesSent } }
    /// Every RoutableMessage received, including ones a silent car ignores.
    var requestsReceived: Int { state.withLock { $0.requestsReceived } }
    /// Requests that arrived while an earlier one was still awaiting its final reply.
    var overlappingRequests: Int { state.withLock { $0.overlappingRequests } }
    /// Whether `close()` has been called.
    var isClosed: Bool { state.withLock { $0.isClosed } }

    /// Before answering the next request, sends a reply addressed to another app's
    /// routing address, carrying a body status that differs from `bodyStatus`.
    func injectForeignReplyBeforeNext() {
        state.withLock { $0.foreignReplyPending = true }
    }

    /// Before answering the next verified command, sends a reply addressed to us whose
    /// AES-GCM response tag does not verify, like a garbled or stale notification.
    func injectCorruptReplyBeforeNextCommand() {
        state.withLock { $0.corruptReplyPending = true }
    }

    // MARK: VehicleTransport

    func send(_ message: Data) async throws {
        let replies = handle(message)
        guard !replies.isEmpty else { return }
        if replyDelay == .zero {
            deliver(replies)
        } else {
            Task {
                try? await Task.sleep(for: replyDelay)
                deliver(replies)
            }
        }
    }

    func close() {
        state.withLock { $0.isClosed = true }
        continuation.finish()
    }

    private func deliver(_ replies: [Reply]) {
        for reply in replies {
            if reply.isFinal {
                state.withLock { $0.awaitingReply = false }
            }
            continuation.yield(try! reply.message.serializedData())
        }
    }

    // MARK: Car behaviour

    private struct Reply {
        var message: UniversalMessage_RoutableMessage
        var isFinal = true
    }

    private func handle(_ bytes: Data) -> [Reply] {
        guard let request = try? UniversalMessage_RoutableMessage(serializedBytes: bytes),
              request.hasToDestination else {
            // Add-key requests are a bare ToVCSECMessage that the owner approves on the car.
            if let envelope = try? VCSEC_ToVCSECMessage(serializedBytes: bytes) {
                state.withLock { $0.addKeyRequests.append(envelope) }
            }
            return []
        }
        return state.withLock { state in
            state.requestsReceived += 1
            if case .silent = state.script { return [] }
            if state.bodyStatus.vehicleSleepStatus == .vehicleSleepStatusAsleep,
               request.toDestination.domain == .infotainment, case .sessionInfoRequest? = request.payload {
                state.unansweredWhileAsleep += 1
                return []
            }
            if state.awaitingReply { state.overlappingRequests += 1 }
            state.awaitingReply = true

            var replies: [Reply] = []
            if state.foreignReplyPending {
                state.foreignReplyPending = false
                var foreignStatus = VCSEC_VehicleStatus()
                foreignStatus.vehicleLockState = .vehiclelockstateUnlocked
                foreignStatus.closureStatuses.rearTrunk = .closurestateAjar
                var foreign = reply(to: request, domain: .vehicleSecurity)
                foreign.toDestination.routingAddress = Data(repeating: 0xEE, count: 16)
                foreign.protobufMessageAsBytes = try! vcsecReply(.vehicleStatus(foreignStatus))
                replies.append(Reply(message: foreign, isFinal: false))
            }

            switch request.payload {
            case .sessionInfoRequest(let hello)?:
                replies.append(contentsOf: handshake(request, publicKey: hello.publicKey, state: &state))
            case .protobufMessageAsBytes?:
                if case .signatureData? = request.subSigData {
                    let answers = command(request, state: &state)
                    if state.corruptReplyPending, answers.first?.message.signedMessageStatus.signedMessageFault == .rrorNone {
                        state.corruptReplyPending = false
                        replies.append(Reply(message: corruptReply(to: request), isFinal: false))
                    }
                    replies.append(contentsOf: answers)
                } else {
                    replies.append(contentsOf: statusRequest(request, state: &state))
                }
            default:
                break
            }
            return replies
        }
    }

    private func handshake(_ request: UniversalMessage_RoutableMessage, publicKey: Data,
                           state: inout State) -> [Reply] {
        let domain = request.toDestination.domain
        state.sessionInfoRequests.append(domain)
        var response = reply(to: request, domain: domain)
        if case .unknownKey = state.script {
            response.signedMessageStatus.signedMessageFault = .rrorUnknownKeyID
            return [Reply(message: response)]
        }
        var whitelisted = true
        if domain == .infotainment {
            state.infotainmentHandshakes += 1
            if case .pairAfter(let polls) = state.script, state.infotainmentHandshakes <= polls {
                whitelisted = false
            }
        }
        var domainState = state.domains[domain] ?? DomainState()
        let peer = try! P256.KeyAgreement.PublicKey(x963Representation: publicKey)
        let shared = try! privateKey.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes { Data($0) }
        domainState.sessionKey = SessionKey(sharedSecretX: shared)
        domainState.clientPublicKey = publicKey
        state.domains[domain] = domainState
        attachSessionInfo(to: &response, domain: domainState, challenge: request.uuid,
                          status: whitelisted ? .ok : .keyNotOnWhitelist)
        return [Reply(message: response)]
    }

    private func command(_ request: UniversalMessage_RoutableMessage, state: inout State) -> [Reply] {
        let domain = request.toDestination.domain
        var response = reply(to: request, domain: domain)
        guard var domainState = state.domains[domain], let sessionKey = domainState.sessionKey,
              request.signatureData.signerIdentity.publicKey == domainState.clientPublicKey else {
            response.signedMessageStatus.signedMessageFault = .rrorUnknownKeyID
            return [Reply(message: response)]
        }
        let reboots = switch state.script {
        case .staleSessionOnce: !state.rebooted
        case .staleSessionAlways: true
        default: false
        }
        if reboots {
            // The car rebooted: new epoch, counter and clock.
            state.rebooted = true
            domainState.epoch = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
            domainState.counter = 0
            domainState.clockZero = Date()
            state.domains[domain] = domainState
        }

        let gcm = request.signatureData.aesGcmPersonalizedData
        let fault: UniversalMessage_MessageFault_E?
        var plaintext: Data?
        if gcm.epoch != domainState.epoch {
            fault = .rrorIncorrectEpoch
        } else if gcm.counter <= domainState.counter {
            fault = .rrorInvalidTokenOrCounter
        } else if let opened = try? sessionKey.open(
            nonce: gcm.nonce, ciphertext: request.protobufMessageAsBytes, tag: gcm.tag,
            aad: Data(SHA256.hash(data: commandMetadata(request, domain: domain, gcm: gcm)))) {
            fault = nil
            plaintext = opened
        } else {
            fault = .rrorInvalidSignature
        }
        guard let plaintext, fault == nil else {
            state.staleFaultsSent += 1
            response.signedMessageStatus.operationStatus = .rror
            response.signedMessageStatus.signedMessageFault = fault!
            attachSessionInfo(to: &response, domain: domainState, challenge: request.uuid, status: .ok)
            return [Reply(message: response)]
        }
        domainState.counter = gcm.counter
        state.domains[domain] = domainState

        var recorded = Command(domain: domain, counter: gcm.counter)
        if domain == .vehicleSecurity {
            recorded.vcsec = try? VCSEC_UnsignedMessage(serializedBytes: plaintext)
            if recorded.vcsec?.rkeaction == .rkeActionWakeVehicle, !state.ignoresWake {
                state.bodyStatus.vehicleSleepStatus = .vehicleSleepStatusAwake
            }
        } else {
            recorded.carServer = try? CarServer_Action(serializedBytes: plaintext)
        }
        state.commands.append(recorded)

        let replies = commandReplies(response, domain: domain, action: recorded.carServer, state: &state)
        let encrypts = request.flags & (1 << UInt32(UniversalMessage_Flags.flagEncryptResponse.rawValue)) != 0
        guard encrypts else { return replies }
        let requestHash = Data([UInt8(Signatures_SignatureType.aesGcmPersonalized.rawValue)]) + gcm.tag
        return replies.map { reply in
            var reply = reply
            encrypt(&reply.message, domain: domain, requestHash: requestHash, state: &state)
            return reply
        }
    }

    /// The plaintext replies to a verified command, per the script.
    private func commandReplies(_ response: UniversalMessage_RoutableMessage, domain: UniversalMessage_Domain,
                                action: CarServer_Action?, state: inout State) -> [Reply] {
        var response = response

        switch state.script {
        case .busy(let times) where state.busyRepliesSent < times:
            state.busyRepliesSent += 1
            var status = VCSEC_CommandStatus()
            status.operationStatus = .operationstatusWait
            response.protobufMessageAsBytes = try! vcsecReply(.commandStatus(status))
            return [Reply(message: response)]
        case .nominalError:
            var error = Errors_NominalError()
            error.genericError = .genericerrorClosuresOpen
            response.protobufMessageAsBytes = try! vcsecReply(.nominalError(error))
            return [Reply(message: response)]
        default:
            break
        }

        if domain == .infotainment {
            var result = CarServer_Response()
            if case .rejectsAction(let reason) = state.script {
                result.actionStatus.result = .rror
                result.actionStatus.resultReason.plainText = reason
            } else if case .unrecognisedActionStatus = state.script {
                result.actionStatus.result = .UNRECOGNIZED(7)
            } else {
                result.actionStatus.result = .operationstatusOk
                if action?.vehicleAction.getVehicleData.hasGetChargeState == true {
                    result.vehicleData.chargeState = state.chargeState
                }
                if action?.vehicleAction.getVehicleData.hasGetClimateState == true {
                    result.vehicleData.climateState = state.climateState
                }
                if action?.vehicleAction.getVehicleData.hasGetDriveState == true {
                    result.vehicleData.driveState = state.driveState
                }
            }
            response.protobufMessageAsBytes = try! result.serializedData()
            return [Reply(message: response)]
        }
        // VCSEC acknowledges the command, then sends its final (empty) reply.
        var interim = response
        var ack = VCSEC_CommandStatus()
        ack.operationStatus = .operationstatusOk
        interim.protobufMessageAsBytes = try! vcsecReply(.commandStatus(ack))
        return [Reply(message: interim, isFinal: false), Reply(message: response)]
    }

    private func statusRequest(_ request: UniversalMessage_RoutableMessage, state: inout State) -> [Reply] {
        state.statusRequests += 1
        var response = reply(to: request, domain: .vehicleSecurity)
        response.protobufMessageAsBytes = try! vcsecReply(.vehicleStatus(state.bodyStatus))
        return [Reply(message: response)]
    }

    // MARK: Message helpers

    private func reply(to request: UniversalMessage_RoutableMessage,
                       domain: UniversalMessage_Domain) -> UniversalMessage_RoutableMessage {
        var response = UniversalMessage_RoutableMessage()
        response.toDestination.routingAddress = request.fromDestination.routingAddress
        response.fromDestination.domain = domain
        response.requestUuid = request.uuid
        return response
    }

    /// Encrypts `message`'s payload in place per protocol.md "Response metadata".
    private func encrypt(_ message: inout UniversalMessage_RoutableMessage, domain: UniversalMessage_Domain,
                         requestHash: Data, state: inout State) {
        var domainState = state.domains[domain]!
        domainState.responseCounter += 1
        state.domains[domain] = domainState
        state.encryptedRepliesSent += 1
        var meta = Metadata()
        try! meta.add(.signatureType, Data([UInt8(Signatures_SignatureType.aesGcmResponse.rawValue)]))
        try! meta.add(.domain, Data([UInt8(domain.rawValue)]))
        try! meta.add(.personalization, Data(vin.utf8))
        try! meta.add(.counter, uint32: domainState.responseCounter)
        try! meta.add(.flags, uint32: message.flags)
        try! meta.add(.requestHash, requestHash)
        try! meta.add(.fault, uint32: UInt32(message.signedMessageStatus.signedMessageFault.rawValue))
        let sealed = try! domainState.sessionKey!.seal(message.protobufMessageAsBytes,
                                                       aad: Data(SHA256.hash(data: meta.serialized())))
        message.protobufMessageAsBytes = sealed.ciphertext
        message.signatureData.aesGcmResponseData.nonce = sealed.nonce
        message.signatureData.aesGcmResponseData.counter = domainState.responseCounter
        message.signatureData.aesGcmResponseData.tag = sealed.tag
    }

    /// An encrypted-looking reply to `request` whose tag cannot verify.
    private func corruptReply(to request: UniversalMessage_RoutableMessage) -> UniversalMessage_RoutableMessage {
        var corrupt = reply(to: request, domain: request.toDestination.domain)
        corrupt.protobufMessageAsBytes = Data(repeating: 0xAB, count: 8)
        corrupt.signatureData.aesGcmResponseData.nonce = Data(repeating: 0x01, count: 12)
        corrupt.signatureData.aesGcmResponseData.counter = 1
        corrupt.signatureData.aesGcmResponseData.tag = Data(repeating: 0x02, count: 16)
        return corrupt
    }

    private func attachSessionInfo(to response: inout UniversalMessage_RoutableMessage, domain: DomainState,
                                   challenge: Data, status: Signatures_Session_Info_Status) {
        var info = Signatures_SessionInfo()
        info.counter = domain.counter
        info.publicKey = privateKey.publicKey.x963Representation
        info.epoch = domain.epoch
        info.clockTime = UInt32(Date().timeIntervalSince(domain.clockZero))
        info.status = status
        response.sessionInfo = try! info.serializedData()
        response.signatureData.sessionInfoTag.tag = try! domain.sessionKey!
            .sessionInfoTag(vin: vin, challenge: challenge, encodedInfo: response.sessionInfo)
    }

    /// The metadata the client authenticated, rebuilt from the request as the car would.
    private func commandMetadata(_ request: UniversalMessage_RoutableMessage, domain: UniversalMessage_Domain,
                                 gcm: Signatures_AES_GCM_Personalized_Signature_Data) -> Data {
        var meta = Metadata()
        try! meta.add(.signatureType, Data([UInt8(Signatures_SignatureType.aesGcmPersonalized.rawValue)]))
        try! meta.add(.domain, Data([UInt8(domain.rawValue)]))
        try! meta.add(.personalization, Data(vin.utf8))
        try! meta.add(.epoch, gcm.epoch)
        try! meta.add(.expiresAt, uint32: gcm.expiresAt)
        try! meta.add(.counter, uint32: gcm.counter)
        if request.flags != 0 {
            try! meta.add(.flags, uint32: request.flags)
        }
        return meta.serialized()
    }

    private func vcsecReply(_ subMessage: VCSEC_FromVCSECMessage.OneOf_SubMessage) throws -> Data {
        var message = VCSEC_FromVCSECMessage()
        message.subMessage = subMessage
        return try message.serializedData()
    }
}
