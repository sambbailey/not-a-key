import Foundation
import Observation
import os
import TeslaKit

private let log = Logger(subsystem: "com.dodimead.sentry", category: "home")

/// What the home screen shows and does: reads the car when asked, sends one command at a time,
/// and remembers the last readings for when the car is out of range.
@Observable @MainActor
final class HomeModel {
    enum Reach: Equatable {
        case unknown, nearby, notInRange
    }

    enum Control: Hashable, CaseIterable {
        case boot, doors, frunk, climate
    }

    struct Banner: Equatable, Identifiable {
        let id = UUID()
        var message: String
        /// The raw error under the friendly copy, for telling causes apart at the car.
        var detail: String?
        var isError: Bool
        var control: Control?
    }

    /// The phone's car key is missing or can't be read; only re-pairing fixes it.
    struct KeyUnavailable: Error {}

    private(set) var charge: ChargeReading?
    private(set) var body: BodyReading?
    private(set) var reach = Reach.unknown
    /// Cabin climate from the last read, updated as this app changes it.
    private(set) var climate: ClimateSnapshot? {
        didSet { if let climate { store.save(climate) } }
    }
    /// The control whose command is in flight. Only one runs at a time; the car takes one connection.
    private(set) var working: Control?
    private(set) var keyIsMissing = false
    /// Whether "Try again" is looking for the car.
    private(set) var isRetrying = false
    var banner: Banner?

    /// How long a normal read looks for the car, and how long "Try again" does.
    static let scanLimit: Duration = .seconds(10)
    static let retryLimit: Duration = .seconds(5)

    /// The read in flight. It runs alongside the controls; they cancel it before connecting.
    private var readTask: Task<Void, Never>?
    /// Whether `readTask` is a full read, rather than a wait to see a moving boot or frunk settle.
    private var readIsFull = false

    private let store: ChargeStore
    /// Makes a service whose connect gives up looking for the car after the given time.
    private let makeService: (Duration) throws -> VehicleService
    private let now: @Sendable () -> Date

    init(store: ChargeStore = ChargeStore(), now: @escaping @Sendable () -> Date = Date.init,
         makeService: @escaping (_ scanLimit: Duration) throws -> VehicleService) {
        self.store = store
        self.now = now
        self.makeService = makeService
        charge = store.last
        body = store.lastBody
        climate = store.lastClimate
    }

    convenience init(car: CarStore, keyStore: KeyStore = KeyStore()) {
        self.init { scanLimit in
            guard let vin = car.vin, let key = try keyStore.load() else { throw KeyUnavailable() }
            return VehicleService(vin: vin, key: key, connect: {
                try await BLETransport.connect(vin: $0, scanTimeout: scanLimit)
            })
        }
    }

    var isReading: Bool { readTask != nil && readIsFull }

    /// Stops any read in flight, e.g. before the key is removed.
    func stop() {
        readTask?.cancel()
    }

    /// The command a tap on `control` sends now, or nil if it can't do anything from this state.
    func command(for control: Control) -> VehicleCommand? {
        switch control {
        case .boot: .moveTrunk
        case .doors: body.map { $0.isLocked ? .unlock : .lock }
        // Tesla has no frunk-close command; an open frunk is shut by hand.
        case .frunk: body?.frunk == .closed ? .openFrunk : nil
        case .climate: climate?.isOn == true ? .climateOff : .climateOn
        }
    }

    /// Wakes the car if needed and reads lock, closures and charge, or waits for the read in flight.
    /// Skipped while a command runs.
    func refresh() async {
        await refresh(scanLimit: Self.scanLimit)
    }

    /// Looks for the car again for up to `retryLimit`, then reads it if found. Counts as
    /// retrying for at least that long, so a quick failure doesn't flash past.
    func retry() async {
        guard !isRetrying else { return }
        isRetrying = true
        defer { isRetrying = false }
        let started = ContinuousClock.now
        await refresh(scanLimit: Self.retryLimit)
        if reach != .nearby {
            try? await Task.sleep(until: started + Self.retryLimit)
        }
    }

    private func refresh(scanLimit: Duration) async {
        if readTask == nil, working == nil {
            readIsFull = true
            readTask = Task {
                defer { readTask = nil }
                await read(scanLimit: scanLimit)
            }
        }
        await readTask?.value
    }

    func perform(_ control: Control) async {
        guard let command = command(for: control) else { return }
        await send(command, for: control)
    }

    /// Sends `command` on behalf of `control`, then shows what changed. Ignored while another
    /// command runs.
    func send(_ command: VehicleCommand, for control: Control) async {
        // Checked before any suspension, so a double tap can't start two connections.
        guard working == nil else { return }
        working = control
        let interruptedFullRead = await stopRead()
        do {
            let result = try await makeService(Self.scanLimit).send(command)
            reach = .nearby
            keyIsMissing = false
            apply(BodyReading(result.after, readAt: now()))
            applyClimate(after: command)
            let message = command == .moveTrunk
                ? IntentMessages.success(BootToggleOutcome(bootBefore: result.before.rearTrunk))
                : IntentMessages.success(command)
            banner = Banner(message: message, isError: false, control: control)
        } catch {
            report(error)
        }
        working = nil
        // The command took the car's connection mid-read; read again now it's free.
        if interruptedFullRead {
            Task { await refresh() }
        } else {
            watchMovingClosures()
        }
    }

    private func read(scanLimit: Duration) async {
        do {
            let status = try await makeService(scanLimit).refreshStatus(into: store, now: now)
            charge = status.charge
            body = status.body
            if let climate = status.climate { self.climate = climate }
            reach = .nearby
            keyIsMissing = false
        } catch {
            // Cancelled to make way for a command; that command reports its own outcome.
            guard !Task.isCancelled else { return }
            report(error)
        }
    }

    /// Cancels the read in flight and waits for it to let go of the car.
    /// Returns whether a full read was interrupted, so it can be started again afterwards.
    private func stopRead() async -> Bool {
        guard let readTask else { return false }
        let wasFull = readIsFull
        readTask.cancel()
        await readTask.value
        return wasFull
    }

    /// While the boot or frunk is moving, reads them again every few seconds until they stop.
    private func watchMovingClosures(attempt: Int = 0) {
        guard readTask == nil, working == nil, attempt < 5,
              let body, body.boot.isMoving || body.frunk.isMoving else { return }
        readIsFull = false
        readTask = Task {
            try? await Task.sleep(for: .seconds(3))
            let snapshot = Task.isCancelled ? nil : try? await makeService(Self.scanLimit).snapshot()
            readTask = nil
            guard !Task.isCancelled, let snapshot else { return }
            apply(BodyReading(snapshot, readAt: now()))
            watchMovingClosures(attempt: attempt + 1)
        }
    }

    /// Shows the climate a successful `command` leads to, until the next read confirms it.
    private func applyClimate(after command: VehicleCommand) {
        var climate = climate ?? ClimateSnapshot(isOn: false)
        switch command {
        case .climateOn: climate.isOn = true
        case .climateOff: climate.isOn = false
        case .setTemperature(let celsius): climate.setCelsius = celsius
        case .setDefrost(let on):
            climate.isDefrosting = on
            // Defrost runs the climate at full power, so it switches climate on too.
            if on { climate.isOn = true }
        case .keepClimate(let on): climate.keepsOn = on
        default: return
        }
        self.climate = climate
    }

    private func apply(_ reading: BodyReading) {
        body = reading
        store.save(reading)
    }

    private func report(_ error: any Error) {
        log.error("Home: \(String(describing: error), privacy: .public)")
        switch error {
        case VehicleError.notInRange:
            reach = .notInRange
        case is KeyUnavailable:
            keyIsMissing = true
            banner = Banner(message: "This phone's car key is missing or can't be read. Remove it in Settings and pair again.",
                            isError: true)
        default:
            banner = Banner(message: IntentMessages.failure(error), detail: String(describing: error), isError: true)
        }
    }
}
