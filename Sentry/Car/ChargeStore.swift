import Foundation
import TeslaKit

/// One charge reading from the car and when it was taken.
struct ChargeReading: Codable, Equatable, Sendable {
    var batteryLevel: Int
    var rangeMiles: Double
    var isCharging: Bool
    var readAt: Date

    init(batteryLevel: Int, rangeMiles: Double, isCharging: Bool, readAt: Date) {
        self.batteryLevel = batteryLevel
        self.rangeMiles = rangeMiles
        self.isCharging = isCharging
        self.readAt = readAt
    }

    init(_ snapshot: ChargeSnapshot, readAt: Date) {
        self.init(batteryLevel: snapshot.batteryLevel, rangeMiles: snapshot.rangeMiles,
                  isCharging: snapshot.isCharging, readAt: readAt)
    }

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

/// The last charge and body readings, remembered across launches so they can be shown while
/// out of range. `UserDefaults` is documented as thread-safe, though not marked `Sendable`.
struct ChargeStore: @unchecked Sendable {
    nonisolated static let readingKey = "sentry.charge"
    nonisolated static let bodyKey = "sentry.body"

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
}
