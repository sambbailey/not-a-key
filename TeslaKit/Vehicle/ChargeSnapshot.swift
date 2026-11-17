import Foundation

/// Battery level, range and whether the car is charging, as infotainment reports them.
public struct ChargeSnapshot: Sendable, Equatable {
    /// What the charger is doing, as the car's `charging_state` says.
    public enum ChargingState: String, Codable, Sendable {
        case unknown, disconnected, noPower, starting, charging, complete, stopped, calibrating
    }

    /// The usable level in percent, as Tesla's app shows it.
    public var batteryLevel: Int
    public var rangeMiles: Double
    public var isCharging: Bool
    /// The power going into the battery, in kW; nil when not reported.
    public var chargerPowerKW: Int?
    /// Whether the charge port door is open; nil when not reported.
    public var isPortOpen: Bool?
    /// Nil when not reported.
    public var chargingState: ChargingState?
    /// The level charging stops at, in percent.
    public var chargeLimit: Int?
    /// The lowest and highest limit the car accepts.
    public var chargeLimitRange: ClosedRange<Int>?
    /// Whether charging waits for a scheduled start.
    public var isScheduled: Bool?
    public var scheduledStart: Date?
    public var minutesToLimit: Int?
    /// Range added per hour of charging, in miles.
    public var chargeRateMph: Int?
    /// Whether a DC fast charger, such as a Supercharger, is connected.
    public var isFastCharger: Bool?
    public var energyAddedKWh: Double?
    public var milesAdded: Double?
    public var chargerAmps: Int?
    public var chargerVolts: Int?
    /// The current the car asks the charger for, and the most it can ask for, in amps.
    public var currentRequest: Int?
    public var currentRequestMax: Int?

    public init(batteryLevel: Int, rangeMiles: Double, isCharging: Bool,
                chargerPowerKW: Int? = nil, isPortOpen: Bool? = nil, chargingState: ChargingState? = nil,
                chargeLimit: Int? = nil, chargeLimitRange: ClosedRange<Int>? = nil,
                isScheduled: Bool? = nil, scheduledStart: Date? = nil, minutesToLimit: Int? = nil,
                chargeRateMph: Int? = nil, isFastCharger: Bool? = nil, energyAddedKWh: Double? = nil,
                milesAdded: Double? = nil, chargerAmps: Int? = nil, chargerVolts: Int? = nil,
                currentRequest: Int? = nil, currentRequestMax: Int? = nil) {
        self.batteryLevel = batteryLevel
        self.rangeMiles = rangeMiles
        self.isCharging = isCharging
        self.chargerPowerKW = chargerPowerKW
        self.isPortOpen = isPortOpen
        self.chargingState = chargingState
        self.chargeLimit = chargeLimit
        self.chargeLimitRange = chargeLimitRange
        self.isScheduled = isScheduled
        self.scheduledStart = scheduledStart
        self.minutesToLimit = minutesToLimit
        self.chargeRateMph = chargeRateMph
        self.isFastCharger = isFastCharger
        self.energyAddedKWh = energyAddedKWh
        self.milesAdded = milesAdded
        self.chargerAmps = chargerAmps
        self.chargerVolts = chargerVolts
        self.currentRequest = currentRequest
        self.currentRequestMax = currentRequestMax
    }
}

extension ChargeSnapshot {
    /// Throws `.protocolFault(.rrorDecoding)` if the level or range is missing.
    init(_ state: CarServer_ChargeState) throws {
        guard case .batteryLevel(let level)? = state.optionalBatteryLevel,
              case .batteryRange(let range)? = state.optionalBatteryRange else {
            throw VehicleError.protocolFault(.rrorDecoding)
        }
        // The usable level, as Tesla's app shows it; the raw level includes charge held back in
        // the cold and reads a percent or so higher.
        if case .usableBatteryLevel(let usable)? = state.optionalUsableBatteryLevel {
            batteryLevel = Int(usable)
        } else {
            batteryLevel = Int(level)
        }
        // The car sends a Float; rounding to hundredths drops its binary noise (245.4, not 245.39999).
        rangeMiles = Self.rounded(range, to: 100)
        if case .charging? = state.chargingState.type {
            isCharging = true
        } else {
            isCharging = false
        }
        chargingState = switch state.chargingState.type {
        case .unknown?: .unknown
        case .disconnected?: .disconnected
        case .noPower?: .noPower
        case .starting?: .starting
        case .charging?: .charging
        case .complete?: .complete
        case .stopped?: .stopped
        case .calibrating?: .calibrating
        case nil: nil
        }
        if case .chargerPower(let power)? = state.optionalChargerPower { chargerPowerKW = Int(power) }
        if case .chargePortDoorOpen(let open)? = state.optionalChargePortDoorOpen { isPortOpen = open }
        if case .chargeLimitSoc(let limit)? = state.optionalChargeLimitSoc { chargeLimit = Int(limit) }
        if case .chargeLimitSocMin(let low)? = state.optionalChargeLimitSocMin,
           case .chargeLimitSocMax(let high)? = state.optionalChargeLimitSocMax, low <= high {
            chargeLimitRange = Int(low)...Int(high)
        }
        if case .scheduledChargingPending(let pending)? = state.optionalScheduledChargingPending {
            isScheduled = pending
        }
        // Milliseconds since 1970, despite the proto's "seconds"; zero when nothing is scheduled.
        if case .scheduledChargingStartTime(let milliseconds)? = state.optionalScheduledChargingStartTime,
           milliseconds > 0 {
            scheduledStart = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
        }
        if case .minutesToChargeLimit(let minutes)? = state.optionalMinutesToChargeLimit {
            minutesToLimit = Int(minutes)
        }
        if case .chargeRateMph(let rate)? = state.optionalChargeRateMph { chargeRateMph = Int(rate) }
        if case .fastChargerPresent(let present)? = state.optionalFastChargerPresent { isFastCharger = present }
        if case .chargeEnergyAdded(let energy)? = state.optionalChargeEnergyAdded {
            energyAddedKWh = Self.rounded(energy, to: 10)
        }
        if case .chargeMilesAddedRated(let miles)? = state.optionalChargeMilesAddedRated {
            milesAdded = Self.rounded(miles, to: 10)
        }
        if case .chargerActualCurrent(let amps)? = state.optionalChargerActualCurrent { chargerAmps = Int(amps) }
        if case .chargerVoltage(let volts)? = state.optionalChargerVoltage { chargerVolts = Int(volts) }
        if case .chargeCurrentRequest(let amps)? = state.optionalChargeCurrentRequest { currentRequest = Int(amps) }
        if case .chargeCurrentRequestMax(let amps)? = state.optionalChargeCurrentRequestMax {
            currentRequestMax = Int(amps)
        }
    }

    private static func rounded(_ value: Float, to scale: Double) -> Double {
        (Double(value) * scale).rounded() / scale
    }
}
