import CryptoKit
import Foundation
import Synchronization
@testable import TeslaKit

/// An in-process car for `VehicleClient` tests. It holds `TestVectors.vehiclePrivateKey`,
/// answers session-info requests with properly tagged `SessionInfo`, verifies and decrypts
/// commands as the real verifier would (epoch, counter, AES-GCM over the metadata), records
/// what it decoded, and replies in plaintext according to its script.
final class FakeVehicle: VehicleTransport {
    enum Script: Sendable {
        case success
        /// Replies `OPERATIONSTATUS_WAIT` to the first `times` commands.
        case busy(times: Int)
        case nominalError
        /// Reboots (new epoch) before the first command, so it faults with fresh session info.
        case staleSessionOnce
        /// Faults every session-info request with `ERROR_UNKNOWN_KEY_ID`.
        case unknownKey
        /// Never replies.
        case silent
        /// Reports `KEY_NOT_ON_WHITELIST` for the first `polls` infotainment handshakes.
        case pairAfter(polls: Int)
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
        var clockZero = Date()
        var sessionKey: SessionKey?
        var clientPublicKey = Data()
    }

    private struct State {
        var script: Script
        var bodyStatus = VCSEC_VehicleStatus()
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
        var awaitingReply = false
        var overlappingRequests = 0
    }

    private let vin: String
    private let privateKey: P256.KeyAgreement.PrivateKey
    private let replyDelay: Duration
    private let state: Mutex<State>
    private let continuation: AsyncStream<Data>.Continuation
    let incoming: AsyncStream<Data>

    init(script: Script = .success, vin: String = TestVectors.vin, replyDelay: Duration = .zero) {
        self.vin = vin
        self.replyDelay = replyDelay
        privateKey = try! P256.KeyAgreement.PrivateKey(rawRepresentation: TestVectors.vehiclePrivateKey)
        state = Mutex(State(script: script))
        (incoming, continuation) = AsyncStream.makeStream()
    }

    // MARK: Test configuration and observations

    var bodyStatus: VCSEC_VehicleStatus {
        get { state.withLock { $0.bodyStatus } }
        set { state.withLock { $0.bodyStatus = newValue } }
    }

    var sessionInfoRequests: [UniversalMessage_Domain] { state.withLock { $0.sessionInfoRequests } }
    /// Commands that decrypted and verified, in arrival order.
    var commands: [Command] { state.withLock { $0.commands } }
    var statusRequests: Int { state.withLock { $0.statusRequests } }
    var addKeyRequests: [VCSEC_ToVCSECMessage] { state.withLock { $0.addKeyRequests } }
    var staleFaultsSent: Int { state.withLock { $0.staleFaultsSent } }
    var busyRepliesSent: Int { state.withLock { $0.busyRepliesSent } }
    /// Requests that arrived while an earlier one was still awaiting its final reply.
    var overlappingRequests: Int { state.withLock { $0.overlappingRequests } }

    /// Before answering the next request, sends a reply addressed to another app's
    /// routing address, carrying a body status that differs from `bodyStatus`.
    func injectForeignReplyBeforeNext() {
        state.withLock { $0.foreignReplyPending = true }
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
            if case .silent = state.script { return [] }
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
                    replies.append(contentsOf: command(request, state: &state))
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
        if case .staleSessionOnce = state.script, !state.rebooted {
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
        } else {
            recorded.carServer = try? CarServer_Action(serializedBytes: plaintext)
        }
        state.commands.append(recorded)

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
            result.actionStatus.result = .operationstatusOk
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
