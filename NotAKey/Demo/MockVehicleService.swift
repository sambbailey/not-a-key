import Foundation
import TeslaKit

/// A simulated Model Y for demo mode, standing in for `VehicleService`. Every read and command
/// answers after a short delay from state held here, so the whole app works without a car.
/// It never touches Bluetooth, the keychain or the network.
actor MockVehicleService: VehicleServing {
    /// The one demo car, shared by the app and the Toggle Boot intent so both see the same state.
    static let shared = MockVehicleService()

    /// Everything the simulated car reports.
    struct State: Sendable, Equatable {
        var body: VehicleSnapshot
        var charge: ChargeSnapshot
        var climate: ClimateSnapshot
        var sentry: SentrySnapshot
        var drive: DriveSnapshot

        /// Locked and parked at home, plugged in at 72% with charging paused.
        static let initial = State(
            body: VehicleSnapshot(isLocked: true, rearTrunk: .closed, frontTrunk: .closed, isAsleep: false),
            charge: ChargeSnapshot(batteryLevel: 72, rangeMiles: MockVehicleService.range(at: 72), isCharging: false,
                                   isPortOpen: true, chargingState: .stopped, chargeLimit: 80,
                                   chargeLimitRange: 50...100, isScheduled: false, isFastCharger: false,
                                   currentRequest: 16, currentRequestMax: 32),
            climate: ClimateSnapshot(isOn: false, insideCelsius: 14, outsideCelsius: 9, setCelsius: 21),
            sentry: SentrySnapshot(state: .armed),
            drive: DriveSnapshot(gear: .park, speedMph: 0, powerKW: 0, odometerMiles: 8_214))
    }

    private(set) var state = State.initial
    /// When the frunk was opened. Tesla has no frunk-close command, so the demo shuts it
    /// "by hand" after `frunkShutsAfter`, freeing the control again.
    private var frunkOpenedAt: ContinuousClock.Instant?

    private let commandDelay: Duration
    private let readDelay: Duration
    private let frunkShutsAfter: Duration

    /// Model Y Long Range: about 330 miles from full, a 75 kWh battery and a 230 V home charger.
    static let fullRangeMiles = 330.0
    static let batteryKWh = 75.0
    static let homeVolts = 230

    init(commandDelay: Duration = .milliseconds(700), readDelay: Duration = .milliseconds(400),
         frunkShutsAfter: Duration = .seconds(30)) {
        self.commandDelay = commandDelay
        self.readDelay = readDelay
        self.frunkShutsAfter = frunkShutsAfter
    }

    /// Puts the car back as it starts, for a fresh demo.
    func reset() {
        state = .initial
        frunkOpenedAt = nil
    }

    // MARK: - VehicleServing

    func toggleBoot(before deadline: ContinuousClock.Instant?) async throws -> BootToggleOutcome {
        try await Task.sleep(for: commandDelay)
        settle()
        let outcome = BootToggleOutcome(bootBefore: state.body.rearTrunk)
        apply(.moveTrunk)
        return outcome
    }

    func status(before deadline: ContinuousClock.Instant?) async throws -> VehicleService.Status {
        try await Task.sleep(for: readDelay)
        settle()
        progressCharging()
        progressClimate()
        return VehicleService.Status(body: state.body, charge: state.charge, climate: state.climate,
                                     drive: state.drive, sentry: state.sentry)
    }

    func send(_ command: VehicleCommand, before deadline: ContinuousClock.Instant?) async throws
        -> VehicleService.SendResult {
        try await Task.sleep(for: commandDelay)
        settle()
        let before = state.body
        apply(command)
        let sentry: SentrySnapshot? = if case .setSentryMode = command { state.sentry } else { nil }
        return (before, state.body, command.changesCharge ? state.charge : nil, sentry)
    }

    func snapshot() async throws -> VehicleSnapshot {
        try await Task.sleep(for: readDelay)
        settle()
        return state.body
    }

    /// The demo car stays parked, so this reads once and returns.
    func watchDrive(every interval: Duration, statusEvery: Int,
                    update: @Sendable (VehicleService.DriveUpdate) async -> Void) async throws {
        try await Task.sleep(for: readDelay)
        await update(VehicleService.DriveUpdate(drive: state.drive, charge: state.charge, climate: state.climate))
    }

    /// The demo car is never put in gear, so this keeps passing lock and closures to `body`
    /// until cancelled, as the real one does for a parked car.
    func waitForDrive(every interval: Duration,
                      body: @Sendable (VehicleSnapshot) async -> Void) async throws -> DriveSnapshot {
        while true {
            try Task.checkCancellation()
            settle()
            await body(state.body)
            try await Task.sleep(for: interval)
        }
    }

    // MARK: - Simulation

    /// Changes state as the real car would on accepting `command`.
    private func apply(_ command: VehicleCommand) {
        switch command {
        case .wake: break
        case .lock: state.body.isLocked = true
        case .unlock: state.body.isLocked = false
        case .moveTrunk:
            // The boot takes a few seconds to move; the next read finds it there.
            state.body.rearTrunk = switch state.body.rearTrunk {
            case .closed, .closing, .unknown: .opening
            case .open, .ajar, .opening: .closing
            }
        case .openFrunk:
            guard state.body.frontTrunk == .closed else { return }
            state.body.frontTrunk = .opening
            frunkOpenedAt = .now
        case .climateOn: state.climate.isOn = true
        case .climateOff:
            state.climate.isOn = false
            state.climate.isDefrosting = false
            state.climate.keeperMode = .off
        case .setTemperature(let celsius): state.climate.setCelsius = min(max(celsius, 15), 28)
        case .setDefrost(let on):
            state.climate.isDefrosting = on
            if on { state.climate.isOn = true }
        case .climateKeeper(let mode):
            state.climate.keeperMode = mode
            if mode != .off { state.climate.isOn = true }
        case .openChargePort: state.charge.isPortOpen = true
        case .closeChargePort: state.charge.isPortOpen = false
        case .startCharging:
            guard state.charge.chargingState == .stopped || state.charge.chargingState == .complete else { return }
            if state.charge.batteryLevel >= state.charge.chargeLimit ?? 100 {
                state.charge.chargingState = .complete
            } else {
                startCharging()
            }
        case .stopCharging:
            guard state.charge.isCharging else { return }
            state.charge.isCharging = false
            state.charge.chargingState = .stopped
            state.charge.chargerPowerKW = 0
            state.charge.chargerAmps = 0
            state.charge.chargeRateMph = 0
            state.charge.minutesToLimit = nil
        case .setChargeLimit(let percent):
            let range = state.charge.chargeLimitRange ?? 50...100
            state.charge.chargeLimit = min(max(percent, range.lowerBound), range.upperBound)
            updateChargingFigures()
        case .setChargingAmps(let amps):
            state.charge.currentRequest = min(max(amps, 1), state.charge.currentRequestMax ?? 32)
            updateChargingFigures()
        case .setSentryMode(let on): state.sentry.state = on ? .armed : .off
        }
    }

    /// Lets moving closures finish, and shuts an open frunk once it has been open a while.
    private func settle() {
        if state.body.rearTrunk == .opening { state.body.rearTrunk = .open }
        if state.body.rearTrunk == .closing { state.body.rearTrunk = .closed }
        if state.body.frontTrunk == .opening { state.body.frontTrunk = .open }
        if state.body.frontTrunk == .open, let opened = frunkOpenedAt, .now - opened >= frunkShutsAfter {
            state.body.frontTrunk = .closed
            frunkOpenedAt = nil
        }
    }

    private func startCharging() {
        state.charge.isCharging = true
        state.charge.chargingState = .charging
        state.charge.energyAddedKWh = state.charge.energyAddedKWh ?? 0
        state.charge.milesAdded = state.charge.milesAdded ?? 0
        updateChargingFigures()
    }

    /// Power, rate and time to the limit for the current request, while charging.
    private func updateChargingFigures() {
        guard state.charge.isCharging else { return }
        let amps = state.charge.currentRequest ?? 16
        let kW = Double(amps * Self.homeVolts) / 1000
        state.charge.chargerAmps = amps
        state.charge.chargerVolts = Self.homeVolts
        state.charge.chargerPowerKW = Int(kW.rounded())
        state.charge.chargeRateMph = Int((kW / Self.batteryKWh * Self.fullRangeMiles).rounded())
        let remaining = Double(max(0, (state.charge.chargeLimit ?? 100) - state.charge.batteryLevel))
        state.charge.minutesToLimit = Int((remaining / 100 * Self.batteryKWh / kW * 60).rounded())
        if remaining == 0 { finishCharging() }
    }

    /// Each read while charging finds the battery a percent fuller, until it reaches the limit.
    private func progressCharging() {
        guard state.charge.isCharging else { return }
        state.charge.batteryLevel += 1
        state.charge.rangeMiles = Self.range(at: state.charge.batteryLevel)
        state.charge.energyAddedKWh = Self.tenths((state.charge.energyAddedKWh ?? 0) + Self.batteryKWh / 100)
        state.charge.milesAdded = Self.tenths((state.charge.milesAdded ?? 0) + Self.fullRangeMiles / 100)
        updateChargingFigures()
    }

    private func finishCharging() {
        state.charge.isCharging = false
        state.charge.chargingState = .complete
        state.charge.chargerPowerKW = 0
        state.charge.chargerAmps = 0
        state.charge.chargeRateMph = 0
        state.charge.minutesToLimit = 0
    }

    /// Each read with climate on finds the cabin 1.5 °C nearer the set temperature.
    private func progressClimate() {
        guard state.climate.isOn, let inside = state.climate.insideCelsius,
              let target = state.climate.isDefrosting ? 28 : state.climate.setCelsius else { return }
        let step = min(1.5, abs(target - inside))
        state.climate.insideCelsius = Self.tenths(inside + (target > inside ? step : -step))
    }

    static func range(at level: Int) -> Double {
        tenths(Double(level) / 100 * fullRangeMiles)
    }

    private static func tenths(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }
}
