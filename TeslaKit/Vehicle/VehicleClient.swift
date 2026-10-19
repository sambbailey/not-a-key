import Foundation
import os

private let log = Logger(subsystem: "com.dodimead.sentry", category: "vehicle")

/// Talks to one vehicle over a `VehicleTransport`: establishes a session per domain on
/// first use, sends signed commands and reads replies until a terminal one arrives,
/// retrying while the vehicle is busy and resyncing a stale session once.
public actor VehicleClient {
    /// Faults that mean our session state is stale; the vehicle attaches fresh session info.
    private static let staleSessionFaults: Set<UniversalMessage_MessageFault_E> = [
        .rrorInvalidSignature, .rrorInvalidTokenOrCounter, .rrorIncorrectEpoch, .rrorTimeExpired,
    ]
    /// How long one pairing poll waits for the vehicle before polling again.
    private static let pairingPollDeadline = Duration.seconds(5)
    /// How long an add-key request may wait behind another request before giving up.
    private static let addKeyQueueDeadline = Duration.seconds(5)

    private enum Attempt<Value> {
        case done(Value)
        case busy
        /// A stale-session fault for the request sent with `challenge`.
        case stale(UniversalMessage_RoutableMessage, domain: UniversalMessage_Domain, challenge: Data)
    }

    private let vin: String
    private let key: KeyAgreementKey
    private let transport: VehicleTransport
    private let now: @Sendable () -> Date
    private let busyRetryInterval: Duration
    private let routingAddress = randomBytes(16)
    private let clock = ContinuousClock()

    private var sessions: [UniversalMessage_Domain: DomainSession] = [:]
    private var receiver: Task<Void, Never>?
    private var transportClosed = false
    private var mailbox: [UniversalMessage_RoutableMessage] = []
    private var waiter: (id: UInt64, continuation: CheckedContinuation<UniversalMessage_RoutableMessage?, Never>)?
    private var lastWaiterID: UInt64 = 0
    private var requestInFlight = false
    private var lastQueueID: UInt64 = 0
    private var queuedRequests: [(id: UInt64, continuation: CheckedContinuation<Bool, Never>)] = []

    public init(vin: String, key: KeyAgreementKey, transport: VehicleTransport,
                now: @escaping @Sendable () -> Date = Date.init, busyRetryInterval: Duration = .seconds(1)) {
        self.vin = vin
        self.key = key
        self.transport = transport
        self.now = now
        self.busyRetryInterval = busyRetryInterval
    }

    deinit {
        receiver?.cancel()
    }

    // MARK: Requests

    /// Reads lock, closure and sleep status. VCSEC answers this unauthenticated, so no handshake is needed.
    public func bodyControllerState(deadline: Duration = .seconds(5)) async throws -> VehicleSnapshot {
        let until = clock.now + deadline
        let payload = try VehicleCommand.bodyControllerStatePayload()
        do {
            let snapshot = try await exclusively(until: until) {
                try await retrying(until: until) { try await statusAttempt(payload: payload, until: until) }
            }
            log.info("Body controller state: \(String(describing: snapshot), privacy: .public)")
            return snapshot
        } catch {
            log.error("Body controller state failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    public func execute(_ command: VehicleCommand, deadline: Duration = .seconds(8)) async throws {
        log.info("Execute \(String(describing: command), privacy: .public)")
        do {
            _ = try await signedRequest(to: command.domain, payload: try command.payload(),
                                        until: clock.now + deadline)
            log.info("Execute \(String(describing: command), privacy: .public) succeeded")
        } catch {
            log.error("Execute \(String(describing: command), privacy: .public) failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Reads battery level, range and charging state from infotainment, which must be awake;
    /// see `waitForInfotainment`.
    public func chargeState(deadline: Duration = .seconds(8)) async throws -> ChargeSnapshot {
        do {
            let response = try await signedRequest(to: .infotainment, payload: try VehicleCommand.chargeStatePayload(),
                                                   until: clock.now + deadline)
            guard let response else { throw VehicleError.protocolFault(.rrorDecoding) }
            let snapshot = try ChargeSnapshot(response.vehicleData.chargeState)
            log.info("Charge state: \(snapshot.batteryLevel, privacy: .public)% \(snapshot.rangeMiles, privacy: .public) mi charging=\(snapshot.isCharging, privacy: .public)")
            return snapshot
        } catch {
            log.error("Charge state failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Establishes the infotainment session, polling about every `pollEvery` while infotainment
    /// wakes up: a sleeping car ignores the handshake until VCSEC wakes it. Returns at once if a
    /// session already exists, and throws `.timeout` once `deadline` passes.
    public func waitForInfotainment(deadline: Duration = .seconds(15), pollEvery: Duration = .seconds(1)) async throws {
        guard sessions[.infotainment] == nil else { return }
        let until = clock.now + deadline
        while true {
            let pollStarted = clock.now
            let pollDeadline = min(until, pollStarted + pollEvery)
            do {
                let session = try await exclusively(until: pollDeadline) {
                    try await retrying(until: pollDeadline) {
                        try await handshakeAttempt(domain: .infotainment, until: pollDeadline)
                    }
                }
                sessions[.infotainment] = session
                log.info("Infotainment awake")
                return
            } catch VehicleError.busy, VehicleError.timeout {
                // Still waking up, or this poll went unanswered.
            } catch {
                log.error("Waiting for infotainment failed: \(String(describing: error), privacy: .public)")
                throw error
            }
            // A poll that failed fast still waits out its interval, so this never spins.
            let nextPoll = pollStarted + pollEvery
            guard nextPoll < until else {
                log.error("Waiting for infotainment timed out")
                throw VehicleError.timeout
            }
            try await Task.sleep(until: nextPoll, clock: clock)
        }
    }

    /// Asks the vehicle to whitelist `publicKeyX963`. The owner approves on the car with a
    /// key card, so this does not wait for an answer; use `waitForPairing` to detect success.
    public func sendAddKeyRequest(publicKeyX963: Data) async throws {
        let envelope = try VehicleCommand.addKeyEnvelope(publicKeyX963: publicKeyX963)
        let until = clock.now + Self.addKeyQueueDeadline
        try await exclusively(until: until) { try await send(envelope, before: until) }
        log.info("Sent add-key request")
    }

    /// Polls the infotainment handshake until the vehicle reports our key as enrolled.
    public func waitForPairing(timeout: Duration = .seconds(120), pollEvery: Duration = .seconds(2)) async throws {
        let until = clock.now + timeout
        while true {
            let pollDeadline = min(until, clock.now + Self.pairingPollDeadline)
            do {
                let session = try await exclusively(until: pollDeadline) {
                    try await retrying(until: pollDeadline) {
                        try await handshakeAttempt(domain: .infotainment, until: pollDeadline)
                    }
                }
                sessions[.infotainment] = session
                log.info("Pairing confirmed")
                return
            } catch VehicleError.notPaired, VehicleError.busy, VehicleError.timeout {
                // Not approved yet, or this poll went unanswered.
            } catch {
                log.error("Waiting for pairing failed: \(String(describing: error), privacy: .public)")
                throw error
            }
            guard clock.now + pollEvery < until else {
                log.error("Waiting for pairing timed out")
                throw VehicleError.timeout
            }
            try await Task.sleep(for: pollEvery)
        }
    }

    // MARK: Attempts

    /// Signs and sends `payload` to `domain`, handshaking first if needed. Returns infotainment's
    /// `CarServer.Response` once its action status is OK, or nil for VCSEC.
    private func signedRequest(to domain: UniversalMessage_Domain, payload: Data,
                               until deadline: ContinuousClock.Instant) async throws -> CarServer_Response? {
        try await exclusively(until: deadline) {
            do {
                if sessions[domain] == nil {
                    sessions[domain] = try await retrying(until: deadline) {
                        try await handshakeAttempt(domain: domain, until: deadline)
                    }
                }
                return try await retrying(until: deadline) {
                    try await commandAttempt(domain: domain, payload: payload, until: deadline)
                }
            } catch VehicleError.notPaired {
                sessions[domain] = nil
                throw VehicleError.notPaired
            }
        }
    }

    /// Runs `attempt` until it finishes: after `busyRetryInterval` while the vehicle is busy
    /// (throwing `.busy` once the deadline would pass), and once more after a resync.
    private func retrying<Value>(until deadline: ContinuousClock.Instant,
                                 _ attempt: () async throws -> Attempt<Value>) async throws -> Value {
        var resynced = false
        while true {
            switch try await attempt() {
            case .done(let value):
                return value
            case .busy:
                guard clock.now + busyRetryInterval < deadline else { throw VehicleError.busy }
                log.info("Vehicle busy, retrying")
                try await Task.sleep(for: busyRetryInterval)
            case .stale(let reply, let domain, let challenge):
                guard !resynced, sessions[domain] != nil else {
                    throw VehicleError.from(fault: reply.signedMessageStatus.signedMessageFault)
                }
                try sessions[domain]!.resync(response: reply, challenge: challenge, now: now())
                resynced = true
                log.info("Resynced \(String(describing: domain), privacy: .public) session, retrying once")
            }
        }
    }

    private func handshakeAttempt(domain: UniversalMessage_Domain,
                                  until deadline: ContinuousClock.Instant) async throws -> Attempt<DomainSession> {
        let uuid = Self.randomBytes(16)
        try await send(DomainSession.handshakeRequest(domain: domain, publicKeyX963: key.publicKeyX963,
                                                      routingAddress: routingAddress, uuid: uuid),
                       before: deadline)
        while true {
            let reply = try await nextReply(from: domain, uuid: uuid, until: deadline)
            if Self.isBusy(reply) { return .busy }
            // A handshake is answered with session info or a fault; skip anything else.
            var answersHandshake = reply.signedMessageStatus.signedMessageFault != .rrorNone
            if case .sessionInfo? = reply.payload { answersHandshake = true }
            guard answersHandshake else { continue }
            let session = try DomainSession(domain: domain, vin: vin, key: key, challenge: uuid,
                                            response: reply, now: now())
            log.info("Session established with \(String(describing: domain), privacy: .public)")
            return .done(session)
        }
    }

    private func commandAttempt(domain: UniversalMessage_Domain, payload: Data,
                                until deadline: ContinuousClock.Instant) async throws -> Attempt<CarServer_Response?> {
        let uuid = Self.randomBytes(16)
        var message = request(to: domain, payload: payload, uuid: uuid)
        let requestHash = try sessions[domain]!.encrypt(&message, now: now())
        try await send(message, before: deadline)
        while true {
            var reply = try await nextReply(from: domain, uuid: uuid, until: deadline)
            let fault = reply.signedMessageStatus.signedMessageFault
            if Self.staleSessionFaults.contains(fault), case .sessionInfo? = reply.payload {
                return .stale(reply, domain: domain, challenge: uuid)
            }
            if Self.isBusy(reply) { return .busy }
            guard fault == .rrorNone else { throw VehicleError.from(fault: fault) }
            do {
                try sessions[domain]!.decryptResponse(&reply, requestHash: requestHash)
            } catch {
                // A garbled notification, a duplicate, or a late reply to an earlier attempt:
                // drop it and keep waiting, as Go's dispatcher does.
                log.warning("Dropped reply that failed to decrypt: \(String(describing: error), privacy: .public)")
                continue
            }
            log.debug("Reply decrypted, counter OK")

            if domain == .vehicleSecurity {
                switch try VCSECReply.classify(Self.vcsecMessage(in: reply)) {
                case .done:
                    log.info("VCSEC: done")
                    return .done(nil)
                case .pending:
                    log.info("VCSEC: pending")
                    continue
                case .busy:
                    log.info("VCSEC: busy")
                    return .busy
                }
            }
            let response: CarServer_Response
            do {
                response = try CarServer_Response(serializedBytes: reply.protobufMessageAsBytes)
            } catch {
                throw VehicleError.protocolFault(.rrorDecoding)
            }
            // Like Go's getCarServerResponse, only OPERATIONSTATUS_ERROR is a rejection.
            if response.actionStatus.result == .rror {
                let reason = response.actionStatus.resultReason.plainText
                throw VehicleError.rejected(reason.isEmpty ? "unspecified error" : reason)
            }
            return .done(response)
        }
    }

    /// Status requests are unsigned (Go's `AuthMethodNone`), and the first reply is terminal.
    private func statusAttempt(payload: Data,
                               until deadline: ContinuousClock.Instant) async throws -> Attempt<VehicleSnapshot> {
        let uuid = Self.randomBytes(16)
        try await send(request(to: .vehicleSecurity, payload: payload, uuid: uuid), before: deadline)
        let reply = try await nextReply(from: .vehicleSecurity, uuid: uuid, until: deadline)
        if Self.isBusy(reply) { return .busy }
        let fault = reply.signedMessageStatus.signedMessageFault
        guard fault == .rrorNone else { throw VehicleError.from(fault: fault) }
        switch try VCSECReply.classify(Self.vcsecMessage(in: reply)) {
        case .busy:
            return .busy
        case .done(let message):
            guard case .vehicleStatus(let status)? = message.subMessage else {
                throw VehicleError.protocolFault(.rrorDecoding)
            }
            return .done(VehicleSnapshot(status))
        case .pending:
            throw VehicleError.protocolFault(.rrorDecoding)
        }
    }

    private func request(to domain: UniversalMessage_Domain, payload: Data,
                         uuid: Data) -> UniversalMessage_RoutableMessage {
        var message = UniversalMessage_RoutableMessage()
        message.toDestination.domain = domain
        message.fromDestination.routingAddress = routingAddress
        message.protobufMessageAsBytes = payload
        message.uuid = uuid
        return message
    }

    private static func isBusy(_ reply: UniversalMessage_RoutableMessage) -> Bool {
        reply.signedMessageStatus.signedMessageFault == .rrorBusy
            || reply.signedMessageStatus.operationStatus == .operationstatusWait
    }

    private static func vcsecMessage(in reply: UniversalMessage_RoutableMessage) throws -> VCSEC_FromVCSECMessage {
        switch reply.payload {
        case nil:
            return VCSEC_FromVCSECMessage()
        case .protobufMessageAsBytes(let bytes)?:
            do {
                return try VCSEC_FromVCSECMessage(serializedBytes: bytes)
            } catch {
                throw VehicleError.protocolFault(.rrorDecoding)
            }
        default:
            throw VehicleError.protocolFault(.rrorDecoding)
        }
    }

    /// Domains, payload kind and status enums only; never key material or payload bytes.
    private static func summary(of message: UniversalMessage_RoutableMessage) -> String {
        let kind = switch message.payload {
        case .sessionInfoRequest?: "session info request"
        case .sessionInfo?: "session info"
        case .protobufMessageAsBytes?:
            if case .signatureData? = message.subSigData { "signed message" } else { "unsigned message" }
        case nil: "empty"
        }
        let to = message.toDestination.domain
        let from = message.fromDestination.domain
        let status = message.signedMessageStatus
        return "\(kind) to=\(to) from=\(from) fault=\(status.signedMessageFault) status=\(status.operationStatus)"
    }

    private static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    // MARK: One request at a time

    /// VCSEC cannot handle concurrent requests, so each request waits for the previous one,
    /// throwing `.timeout` if `deadline` passes first.
    private func exclusively<Value>(until deadline: ContinuousClock.Instant,
                                    _ body: () async throws -> Value) async throws -> Value {
        if requestInFlight {
            lastQueueID += 1
            let id = lastQueueID
            let timer = Task { [weak self] in
                try? await Task.sleep(until: deadline, clock: .continuous)
                await self?.dropQueuedRequest(id)
            }
            let acquired = await withTaskCancellationHandler {
                await withCheckedContinuation { queuedRequests.append((id, $0)) }
            } onCancel: {
                Task { [weak self] in await self?.dropQueuedRequest(id) }
            }
            timer.cancel()
            guard acquired else {
                try Task.checkCancellation()
                throw VehicleError.timeout
            }
        } else {
            requestInFlight = true
        }
        defer { handOffRequestSlot() }
        guard clock.now < deadline else { throw VehicleError.timeout }
        return try await body()
    }

    private func handOffRequestSlot() {
        if queuedRequests.isEmpty {
            requestInFlight = false
        } else {
            queuedRequests.removeFirst().continuation.resume(returning: true)
        }
    }

    private func dropQueuedRequest(_ id: UInt64) {
        guard let index = queuedRequests.firstIndex(where: { $0.id == id }) else { return }
        queuedRequests.remove(at: index).continuation.resume(returning: false)
    }

    // MARK: Transport

    private func send(_ message: UniversalMessage_RoutableMessage, before deadline: ContinuousClock.Instant) async throws {
        try await send(try message.serializedData(), before: deadline)
        log.info("Sent \(Self.summary(of: message), privacy: .public)")
    }

    /// Never sends once `deadline` has passed or the caller is cancelled: the caller would
    /// report a failure for a command the vehicle then carries out. Every send goes through here.
    private func send(_ bytes: Data, before deadline: ContinuousClock.Instant) async throws {
        try Task.checkCancellation()
        guard clock.now < deadline else { throw VehicleError.timeout }
        startReceiving()
        // Anything still queued answers an earlier request.
        mailbox.removeAll()
        try await transport.send(bytes)
    }

    private func startReceiving() {
        guard receiver == nil else { return }
        let stream = transport.incoming
        receiver = Task { [weak self] in
            for await bytes in stream {
                await self?.receive(bytes)
            }
            await self?.transportDidClose()
        }
    }

    /// Keeps only messages addressed to us; the vehicle also answers other apps, such as Tesla's own.
    private func receive(_ bytes: Data) {
        guard let message = try? UniversalMessage_RoutableMessage(serializedBytes: bytes) else {
            log.warning("Dropped \(bytes.count, privacy: .public) bytes that are not a RoutableMessage")
            return
        }
        guard message.toDestination.routingAddress == routingAddress else {
            log.debug("Ignored message for another app")
            return
        }
        if let waiter {
            self.waiter = nil
            waiter.continuation.resume(returning: message)
        } else {
            mailbox.append(message)
        }
    }

    private func transportDidClose() {
        log.info("Transport closed")
        transportClosed = true
        expireWaiter(lastWaiterID)
    }

    /// The next reply from `domain` for the request sent with `uuid`. VCSEC replies are matched
    /// by address only, as VCSEC does not reliably echo request UUIDs (Go does the same).
    private func nextReply(from domain: UniversalMessage_Domain, uuid: Data,
                           until deadline: ContinuousClock.Instant) async throws -> UniversalMessage_RoutableMessage {
        while true {
            guard let reply = await nextMessage(until: deadline) else {
                try Task.checkCancellation()
                throw VehicleError.timeout
            }
            log.info("Received \(Self.summary(of: reply), privacy: .public)")
            guard reply.fromDestination.domain == domain else { continue }
            if domain != .vehicleSecurity, reply.requestUuid != uuid { continue }
            return reply
        }
    }

    /// The next message addressed to us, or nil once `deadline` passes or the transport closes.
    private func nextMessage(until deadline: ContinuousClock.Instant) async -> UniversalMessage_RoutableMessage? {
        if !mailbox.isEmpty { return mailbox.removeFirst() }
        if transportClosed || clock.now >= deadline { return nil }
        lastWaiterID += 1
        let id = lastWaiterID
        let timer = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            await self?.expireWaiter(id)
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiter = (id, $0) }
        } onCancel: {
            Task { [weak self] in await self?.expireWaiter(id) }
        }
    }

    private func expireWaiter(_ id: UInt64) {
        guard let waiter, waiter.id == id else { return }
        self.waiter = nil
        waiter.continuation.resume(returning: nil)
    }
}
