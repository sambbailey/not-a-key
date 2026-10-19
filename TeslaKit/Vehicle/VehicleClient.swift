import Foundation

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
    private var queuedRequests: [CheckedContinuation<Void, Never>] = []

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
        return try await exclusively {
            try await retrying(until: until) { try await statusAttempt(payload: payload, until: until) }
        }
    }

    public func execute(_ command: VehicleCommand, deadline: Duration = .seconds(8)) async throws {
        let until = clock.now + deadline
        let domain = command.domain
        let payload = try command.payload()
        try await exclusively {
            do {
                if sessions[domain] == nil {
                    sessions[domain] = try await retrying(until: until) {
                        try await handshakeAttempt(domain: domain, until: until)
                    }
                }
                try await retrying(until: until) {
                    try await commandAttempt(domain: domain, payload: payload, until: until)
                }
            } catch VehicleError.notPaired {
                sessions[domain] = nil
                throw VehicleError.notPaired
            }
        }
    }

    /// Asks the vehicle to whitelist `publicKeyX963`. The owner approves on the car with a
    /// key card, so this does not wait for an answer; use `waitForPairing` to detect success.
    public func sendAddKeyRequest(publicKeyX963: Data) async throws {
        let envelope = try VehicleCommand.addKeyEnvelope(publicKeyX963: publicKeyX963)
        try await exclusively { try await send(envelope) }
    }

    /// Polls the infotainment handshake until the vehicle reports our key as enrolled.
    public func waitForPairing(timeout: Duration = .seconds(120), pollEvery: Duration = .seconds(2)) async throws {
        let until = clock.now + timeout
        while true {
            let pollDeadline = min(until, clock.now + Self.pairingPollDeadline)
            do {
                let session = try await exclusively {
                    try await retrying(until: pollDeadline) {
                        try await handshakeAttempt(domain: .infotainment, until: pollDeadline)
                    }
                }
                sessions[.infotainment] = session
                return
            } catch VehicleError.notPaired, VehicleError.busy, VehicleError.timeout {
                // Not approved yet, or this poll went unanswered.
            }
            guard clock.now + pollEvery < until else { throw VehicleError.timeout }
            try await Task.sleep(for: pollEvery)
        }
    }

    // MARK: Attempts

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
                try await Task.sleep(for: busyRetryInterval)
            case .stale(let reply, let domain, let challenge):
                guard !resynced, sessions[domain] != nil else {
                    throw VehicleError.from(fault: reply.signedMessageStatus.signedMessageFault)
                }
                try sessions[domain]!.resync(response: reply, challenge: challenge, now: now())
                resynced = true
            }
        }
    }

    private func handshakeAttempt(domain: UniversalMessage_Domain,
                                  until deadline: ContinuousClock.Instant) async throws -> Attempt<DomainSession> {
        let uuid = Self.randomBytes(16)
        try await send(DomainSession.handshakeRequest(domain: domain, publicKeyX963: key.publicKeyX963,
                                                      routingAddress: routingAddress, uuid: uuid))
        while true {
            let reply = try await nextReply(from: domain, uuid: uuid, until: deadline)
            if Self.isBusy(reply) { return .busy }
            // A handshake is answered with session info or a fault; skip anything else.
            var answersHandshake = reply.signedMessageStatus.signedMessageFault != .rrorNone
            if case .sessionInfo? = reply.payload { answersHandshake = true }
            guard answersHandshake else { continue }
            return .done(try DomainSession(domain: domain, vin: vin, key: key, challenge: uuid,
                                           response: reply, now: now()))
        }
    }

    private func commandAttempt(domain: UniversalMessage_Domain, payload: Data,
                                until deadline: ContinuousClock.Instant) async throws -> Attempt<Void> {
        let uuid = Self.randomBytes(16)
        var message = request(to: domain, payload: payload, uuid: uuid)
        let requestHash = try sessions[domain]!.encrypt(&message, now: now())
        try await send(message)
        while true {
            var reply = try await nextReply(from: domain, uuid: uuid, until: deadline)
            let fault = reply.signedMessageStatus.signedMessageFault
            if Self.staleSessionFaults.contains(fault), case .sessionInfo? = reply.payload {
                return .stale(reply, domain: domain, challenge: uuid)
            }
            if Self.isBusy(reply) { return .busy }
            guard fault == .rrorNone else { throw VehicleError.from(fault: fault) }
            try sessions[domain]!.decryptResponse(&reply, requestHash: requestHash)

            if domain == .vehicleSecurity {
                switch try VCSECReply.classify(Self.vcsecMessage(in: reply)) {
                case .done: return .done(())
                case .pending: continue
                case .busy: return .busy
                }
            }
            let response: CarServer_Response
            do {
                response = try CarServer_Response(serializedBytes: reply.protobufMessageAsBytes)
            } catch {
                throw VehicleError.protocolFault(.rrorDecoding)
            }
            if response.actionStatus.result == .rror {
                let reason = response.actionStatus.resultReason.plainText
                throw VehicleError.rejected(reason.isEmpty ? "unspecified error" : reason)
            }
            return .done(())
        }
    }

    /// Status requests are unsigned (Go's `AuthMethodNone`), and the first reply is terminal.
    private func statusAttempt(payload: Data,
                               until deadline: ContinuousClock.Instant) async throws -> Attempt<VehicleSnapshot> {
        let uuid = Self.randomBytes(16)
        try await send(request(to: .vehicleSecurity, payload: payload, uuid: uuid))
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

    private static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    // MARK: One request at a time

    /// VCSEC cannot handle concurrent requests, so each request waits for the previous one.
    private func exclusively<Value>(_ body: () async throws -> Value) async throws -> Value {
        if requestInFlight {
            await withCheckedContinuation { queuedRequests.append($0) }
        } else {
            requestInFlight = true
        }
        defer {
            if queuedRequests.isEmpty {
                requestInFlight = false
            } else {
                queuedRequests.removeFirst().resume()
            }
        }
        return try await body()
    }

    // MARK: Transport

    private func send(_ message: UniversalMessage_RoutableMessage) async throws {
        try await send(try message.serializedData())
    }

    private func send(_ bytes: Data) async throws {
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
        guard let message = try? UniversalMessage_RoutableMessage(serializedBytes: bytes),
              message.toDestination.routingAddress == routingAddress else { return }
        if let waiter {
            self.waiter = nil
            waiter.continuation.resume(returning: message)
        } else {
            mailbox.append(message)
        }
    }

    private func transportDidClose() {
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
