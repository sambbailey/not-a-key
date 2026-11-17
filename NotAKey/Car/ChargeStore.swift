import Foundation
import TeslaKit

/// One charge reading from the car and when it was taken.
struct ChargeReading: Codable, Equatable, Sendable {
    /// Which of the home screen's charging layouts the reading calls for.
    enum Phase: Equatable {
        /// Plugged in but not charging: waiting for a scheduled start, or stopped.
        case plugged
        /// Plugged in, but the charger isn't supplying power, often on purpose (a smart charger's timer).
        case noPower
        case charging
        /// Unplugged or finished: the normal home screen.
        case idle
    }

    var batteryLevel: Int
    var rangeMiles: Double
    var isCharging: Bool
    /// The power going into the battery, in kW.
    var chargerPowerKW: Int?
    /// Whether the charge port door is open; nil if the car didn't say.
    var isPortOpen: Bool?
    var chargingState: ChargeSnapshot.ChargingState?
    /// The level charging stops at, in percent.
    var chargeLimit: Int?
    var chargeLimitRange: ClosedRange<Int>?
    /// Whether charging waits for `scheduledStart`.
    var isScheduled: Bool?
    var scheduledStart: Date?
    var minutesToLimit: Int?
    /// The limit the car gave `minutesToLimit` for; it stays put when the limit is changed
    /// here, so the time shows as pending until the car reports again.
    var minutesLimit: Int?
    /// Range added per hour of charging, in miles.
    var chargeRateMph: Int?
    /// Whether a DC fast charger, such as a Supercharger, is connected.
    var isFastCharger: Bool?
    var energyAddedKWh: Double?
    var milesAdded: Double?
    var chargerAmps: Int?
    var chargerVolts: Int?
    /// The current the car asks the charger for, and the most it can ask for, in amps.
    var currentRequest: Int?
    var currentRequestMax: Int?
    var readAt: Date

    init(batteryLevel: Int, rangeMiles: Double, isCharging: Bool, chargerPowerKW: Int? = nil,
         isPortOpen: Bool? = nil, chargingState: ChargeSnapshot.ChargingState? = nil, chargeLimit: Int? = nil,
         chargeLimitRange: ClosedRange<Int>? = nil, isScheduled: Bool? = nil, scheduledStart: Date? = nil,
         minutesToLimit: Int? = nil, chargeRateMph: Int? = nil, isFastCharger: Bool? = nil,
         energyAddedKWh: Double? = nil, milesAdded: Double? = nil, chargerAmps: Int? = nil,
         chargerVolts: Int? = nil, currentRequest: Int? = nil, currentRequestMax: Int? = nil, readAt: Date) {
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
        minutesLimit = chargeLimit
        self.chargeRateMph = chargeRateMph
        self.isFastCharger = isFastCharger
        self.energyAddedKWh = energyAddedKWh
        self.milesAdded = milesAdded
        self.chargerAmps = chargerAmps
        self.chargerVolts = chargerVolts
        self.currentRequest = currentRequest
        self.currentRequestMax = currentRequestMax
        self.readAt = readAt
    }

    init(_ snapshot: ChargeSnapshot, readAt: Date) {
        self.init(batteryLevel: snapshot.batteryLevel, rangeMiles: snapshot.rangeMiles,
                  isCharging: snapshot.isCharging, chargerPowerKW: snapshot.chargerPowerKW,
                  isPortOpen: snapshot.isPortOpen, chargingState: snapshot.chargingState,
                  chargeLimit: snapshot.chargeLimit, chargeLimitRange: snapshot.chargeLimitRange,
                  isScheduled: snapshot.isScheduled, scheduledStart: snapshot.scheduledStart,
                  minutesToLimit: snapshot.minutesToLimit, chargeRateMph: snapshot.chargeRateMph,
                  isFastCharger: snapshot.isFastCharger, energyAddedKWh: snapshot.energyAddedKWh,
                  milesAdded: snapshot.milesAdded, chargerAmps: snapshot.chargerAmps,
                  chargerVolts: snapshot.chargerVolts, currentRequest: snapshot.currentRequest,
                  currentRequestMax: snapshot.currentRequestMax, readAt: readAt)
    }

    var phase: Phase {
        switch chargingState {
        case .starting?, .charging?: .charging
        case .stopped?: .plugged
        case .noPower?: .noPower
        case nil: isCharging ? .charging : .idle
        default: .idle
        }
    }

    /// Shows what a `command` the car accepted leads to, until a read confirms it.
    mutating func apply(_ command: VehicleCommand) {
        switch command {
        case .openChargePort: isPortOpen = true
        case .closeChargePort: isPortOpen = false
        case .startCharging where phase != .charging:
            isCharging = true
            chargingState = .starting
        case .stopCharging where phase == .charging:
            isCharging = false
            chargerPowerKW = nil
            if chargingState != nil { chargingState = .stopped }
        case .setChargeLimit(let percent): chargeLimit = percent
        case .setChargingAmps(let amps): currentRequest = amps
        default: break
        }
    }

    /// Whether the time to `limit` is waiting on the car: the limit has changed since it gave its time.
    func isTimePending(toLimit limit: Int?) -> Bool {
        guard let limit, let basis = minutesLimit else { return false }
        return limit != basis
    }

    /// After the limit changes, the car keeps reporting its time to the old limit for a while.
    /// Until its time moves, keeps the time pending, as `previous` had it.
    mutating func keepTimePending(from previous: ChargeReading?) {
        guard let previous, let basis = previous.minutesLimit, basis != chargeLimit,
              minutesToLimit == previous.minutesToLimit else { return }
        minutesLimit = basis
    }

    /// Whether a charging cable is in, as far as the car said.
    var hasCable: Bool {
        switch chargingState {
        case nil, .disconnected?, .unknown?: isCharging
        default: true
        }
    }

    /// Plugged in and waiting for a scheduled start.
    var isWaitingForSchedule: Bool { phase == .plugged && isScheduled == true }

    var levelText: String { "\(batteryLevel)%" }
    var rangeText: String { "\(Int(rangeMiles.rounded())) mi" }
}

/// Lock and closures as last read from the car, and when.
struct BodyReading: Codable, Equatable, Sendable {
    enum Closure: String, Codable, Sendable {
        case closed, open, ajar, opening, closing, unknown

        init(_ state: VehicleSnapshot.ClosureState) {
            self = switch state {
            case .closed: .closed
            case .open: .open
            case .ajar: .ajar
            case .opening: .opening
            case .closing: .closing
            case .unknown: .unknown
            }
        }

        var isMoving: Bool { self == .opening || self == .closing }
    }

    var isLocked: Bool
    var boot: Closure
    var frunk: Closure
    var readAt: Date

    init(isLocked: Bool, boot: Closure, frunk: Closure, readAt: Date) {
        self.isLocked = isLocked
        self.boot = boot
        self.frunk = frunk
        self.readAt = readAt
    }

    init(_ snapshot: VehicleSnapshot, readAt: Date) {
        self.init(isLocked: snapshot.isLocked, boot: Closure(snapshot.rearTrunk),
                  frunk: Closure(snapshot.frontTrunk), readAt: readAt)
    }
}

/// The last charge, body, climate and Sentry readings, remembered across launches so they can be shown while
/// out of range. `UserDefaults` is documented as thread-safe, though not marked `Sendable`.
struct ChargeStore: @unchecked Sendable {
    nonisolated static let readingKey = "sentry.charge"
    nonisolated static let bodyKey = "sentry.body"
    nonisolated static let climateKey = "sentry.climate"
    nonisolated static let sentryKey = "sentry.sentry"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var last: ChargeReading? {
        defaults.data(forKey: Self.readingKey).flatMap { try? JSONDecoder().decode(ChargeReading.self, from: $0) }
    }

    func save(_ reading: ChargeReading) {
        defaults.set(try? JSONEncoder().encode(reading), forKey: Self.readingKey)
    }

    var lastBody: BodyReading? {
        defaults.data(forKey: Self.bodyKey).flatMap { try? JSONDecoder().decode(BodyReading.self, from: $0) }
    }

    func save(_ reading: BodyReading) {
        defaults.set(try? JSONEncoder().encode(reading), forKey: Self.bodyKey)
    }

    var lastClimate: ClimateSnapshot? {
        defaults.data(forKey: Self.climateKey).flatMap { try? JSONDecoder().decode(ClimateSnapshot.self, from: $0) }
    }

    func save(_ climate: ClimateSnapshot) {
        defaults.set(try? JSONEncoder().encode(climate), forKey: Self.climateKey)
    }

    var lastSentry: SentrySnapshot? {
        defaults.data(forKey: Self.sentryKey).flatMap { try? JSONDecoder().decode(SentrySnapshot.self, from: $0) }
    }

    func save(_ sentry: SentrySnapshot) {
        defaults.set(try? JSONEncoder().encode(sentry), forKey: Self.sentryKey)
    }
}
