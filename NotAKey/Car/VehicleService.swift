import Foundation
import TeslaKit

/// What pressing "toggle boot" is about to do, judged from the boot's state just before.
enum BootToggleOutcome: Equatable {
    case opening, closing, moving

    init(bootBefore state: VehicleSnapshot.ClosureState) {
        self = switch state {
        case .closed: .opening
        case .open, .ajar: .closing
        case .opening, .closing, .unknown: .moving
        }
    }
}

extension VehicleCommand {
    /// Whether the command changes the charge port or charging, so charge is worth reading after.
    var changesCharge: Bool {
        switch self {
        case .openChargePort, .closeChargePort, .startCharging, .stopCharging, .setChargeLimit, .setChargingAmps: true
        default: false
        }
    }
}

/// What the app asks of a car. `VehicleService` talks to the real one over Bluetooth;
/// `MockVehicleService` stands in for it in demo mode.
protocol VehicleServing: Sendable {
    /// Opens a closed boot or closes an open one.
    func toggleBoot(before deadline: ContinuousClock.Instant?) async throws -> BootToggleOutcome
    /// Reads lock and closures, then charge, climate, drive state and Sentry.
    func status(before deadline: ContinuousClock.Instant?) async throws -> VehicleService.Status
    /// Sends `command` and reads lock and closures again, plus charge or Sentry when the command changes them.
    func send(_ command: VehicleCommand, before deadline: ContinuousClock.Instant?) async throws
        -> VehicleService.SendResult
    /// Reads lock and closures.
    func snapshot() async throws -> VehicleSnapshot
    /// Reads drive state about every `interval` until the car is out of Drive and Reverse.
    func watchDrive(every interval: Duration, statusEvery: Int,
                    update: @Sendable (VehicleService.DriveUpdate) async -> Void) async throws
    /// Reads a parked car about every `interval`, and returns its drive state once it's in gear.
    func waitForDrive(every interval: Duration,
                      body: @Sendable (VehicleSnapshot) async -> Void) async throws -> DriveSnapshot
}

extension VehicleServing {
    /// Reads battery level and range, waking the car first if it is asleep. Gives up
    /// at `deadline`, or after 20 seconds without one.
    func charge(before deadline: ContinuousClock.Instant? = nil) async throws -> ChargeSnapshot {
        try await status(before: deadline).charge
    }

    /// Reads charge and saves it to `store`; on failure the store keeps its last reading.
    func refreshCharge(into store: ChargeStore, now: @Sendable () -> Date = Date.init,
                       before deadline: ContinuousClock.Instant? = nil) async throws -> ChargeReading {
        let reading = ChargeReading(try await charge(before: deadline), readAt: now())
        store.save(reading)
        return reading
    }

    /// Reads lock, closures and charge, and saves both to `store`; on failure the store keeps
    /// its last readings.
    func refreshStatus(into store: ChargeStore, now: @Sendable () -> Date = Date.init,
                       before deadline: ContinuousClock.Instant? = nil) async throws
        -> (body: BodyReading, charge: ChargeReading, climate: ClimateSnapshot?, drive: DriveSnapshot?,
            sentry: SentrySnapshot?) {
        let status = try await status(before: deadline)
        let readAt = now()
        let body = BodyReading(status.body, readAt: readAt)
        let charge = ChargeReading(status.charge, readAt: readAt)
        store.save(body)
        store.save(charge)
        return (body, charge, status.climate, status.drive, status.sentry)
    }
}

/// Runs one piece of work against the car: connect, use a fresh client, disconnect.
struct VehicleService: VehicleServing {
    let vin: String
    let key: KeyAgreementKey
    private let connect: @Sendable (String) async throws -> VehicleTransport

    init(vin: String, key: KeyAgreementKey,
         connect: @escaping @Sendable (String) async throws -> VehicleTransport = {
             try await BLETransport.connect(vin: $0)
         }) {
        self.vin = vin
        self.key = key
        self.connect = connect
    }

    /// Connects, runs `body`, and always closes the connection afterwards.
    func withClient<T: Sendable>(_ body: @Sendable (VehicleClient) async throws -> T) async throws -> T {
        let transport = try await connect(vin)
        defer { transport.close() }
        return try await body(VehicleClient(vin: vin, key: key, transport: transport))
    }

    /// Opens a closed boot or closes an open one. A boot that is moving or in an unknown
    /// state is still sent the move command; the outcome then just says it is moving.
    /// With a `deadline`, no request is sent to the car after it passes.
    func toggleBoot(before deadline: ContinuousClock.Instant? = nil) async throws -> BootToggleOutcome {
        try await withClient { client in
            let state = try await client.bodyControllerState(deadline: Self.limit(.seconds(5), to: deadline))
            let outcome = BootToggleOutcome(bootBefore: state.rearTrunk)
            try await client.execute(.moveTrunk, deadline: Self.limit(.seconds(8), to: deadline))
            return outcome
        }
    }

    /// Reads lock and closures, then charge, climate, drive state and Sentry, over one connection,
    /// waking the car first if it is asleep. Gives up at `deadline`, or after 20 seconds without one.
    /// Climate, drive state and Sentry are nil if only they couldn't be read.
    func status(before deadline: ContinuousClock.Instant? = nil) async throws -> Status {
        let deadline = deadline ?? .now + .seconds(20)
        return try await withClient { client in
            let body = try await client.bodyControllerState(deadline: Self.limit(.seconds(5), to: deadline))
            if body.isAsleep {
                try await Self.wake(client, before: deadline)
            }
            let charge = try await client.chargeState(deadline: Self.limit(.seconds(8), to: deadline))
            let climate = try? await client.climateState(deadline: Self.limit(.seconds(5), to: deadline))
            let drive = try? await client.driveState(deadline: Self.limit(.seconds(5), to: deadline))
            let sentry = try? await client.sentryState(deadline: Self.limit(.seconds(5), to: deadline))
            return Status(body: body, charge: charge, climate: climate, drive: drive, sentry: sentry)
        }
    }

    /// What `status` reads.
    struct Status: Sendable {
        var body: VehicleSnapshot
        var charge: ChargeSnapshot
        var climate: ClimateSnapshot?
        var drive: DriveSnapshot?
        var sentry: SentrySnapshot?
    }

    /// Sends `command` and reads lock and closures again, so the caller can show what changed.
    /// After a charging command, charge is read again too, and Sentry after a Sentry command;
    /// they're nil if only that read failed.
    /// Climate and charging commands wake a sleeping car first, since only an awake car can take them.
    func send(_ command: VehicleCommand, before deadline: ContinuousClock.Instant? = nil) async throws
        -> SendResult {
        let deadline = deadline ?? .now + .seconds(25)
        return try await withClient { client in
            let before = try await client.bodyControllerState(deadline: Self.limit(.seconds(5), to: deadline))
            if before.isAsleep, command.domain == .infotainment {
                try await Self.wake(client, before: deadline)
            }
            try await client.execute(command, deadline: Self.limit(.seconds(8), to: deadline))
            let after = try await client.bodyControllerState(deadline: Self.limit(.seconds(5), to: deadline))
            let charge = command.changesCharge
                ? try? await client.chargeState(deadline: Self.limit(.seconds(5), to: deadline))
                : nil
            let sentry = if case .setSentryMode = command {
                try? await client.sentryState(deadline: Self.limit(.seconds(5), to: deadline))
            } else {
                SentrySnapshot?.none
            }
            return (before, after, charge, sentry)
        }
    }

    /// What `send` reads after the command.
    typealias SendResult = (before: VehicleSnapshot, after: VehicleSnapshot, charge: ChargeSnapshot?,
                            sentry: SentrySnapshot?)

    /// One live read while driving. Charge and climate are only read on some of them.
    struct DriveUpdate: Sendable {
        var drive: DriveSnapshot
        var charge: ChargeSnapshot?
        var climate: ClimateSnapshot?
    }

    /// Reads drive state about every `interval` over one held connection, adding charge and
    /// climate to every `statusEvery`th read, and passes each read to `update`. Returns after
    /// the first read out of Drive and Reverse; throws if a read fails. Cancel to stop.
    /// The car must already be awake, as it is while driven.
    func watchDrive(every interval: Duration, statusEvery: Int,
                    update: @Sendable (DriveUpdate) async -> Void) async throws {
        try await withClient { client in
            var reads = 0
            while true {
                try Task.checkCancellation()
                let started = ContinuousClock.now
                reads += 1
                var reading = DriveUpdate(drive: try await client.driveState(deadline: .seconds(3)))
                if reads.isMultiple(of: statusEvery) {
                    reading.charge = try await client.chargeState(deadline: .seconds(3))
                    reading.climate = try? await client.climateState(deadline: .seconds(3))
                }
                try Task.checkCancellation()
                await update(reading)
                guard reading.drive.isDriving else { return }
                try await Task.sleep(until: started + interval)
            }
        }
    }

    /// Reads a parked car's lock and closures about every `interval` over one held connection,
    /// passing each to `body`, and returns its drive state once it's in Drive or Reverse. Drive
    /// state is only asked of an awake car, so a sleeping one is left to sleep. Cancel to stop.
    func waitForDrive(every interval: Duration,
                      body: @Sendable (VehicleSnapshot) async -> Void = { _ in }) async throws -> DriveSnapshot {
        try await withClient { client in
            while true {
                try Task.checkCancellation()
                let started = ContinuousClock.now
                let snapshot = try await client.bodyControllerState(deadline: .seconds(3))
                try Task.checkCancellation()
                await body(snapshot)
                if !snapshot.isAsleep, let drive = try? await client.driveState(deadline: .seconds(3)), drive.isDriving {
                    return drive
                }
                try await Task.sleep(until: started + interval)
            }
        }
    }

    private static func wake(_ client: VehicleClient, before deadline: ContinuousClock.Instant) async throws {
        try await client.execute(.wake, deadline: limit(.seconds(8), to: deadline))
        try await client.waitForInfotainment(deadline: limit(.seconds(15), to: deadline))
    }

    func snapshot() async throws -> VehicleSnapshot {
        try await withClient { try await $0.bodyControllerState() }
    }

    /// A request's own `timeout`, shortened so it ends no later than `deadline`.
    private static func limit(_ timeout: Duration, to deadline: ContinuousClock.Instant?) -> Duration {
        guard let deadline else { return timeout }
        return min(timeout, deadline - .now)
    }
}
