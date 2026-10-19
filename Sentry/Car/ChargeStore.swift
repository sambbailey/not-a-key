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

/// The last charge reading, remembered across launches so it can be shown while out of range.
/// `UserDefaults` is documented as thread-safe, though not marked `Sendable`.
struct ChargeStore: @unchecked Sendable {
    nonisolated static let readingKey = "sentry.charge"

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
}
