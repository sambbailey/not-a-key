import Foundation
import Observation

/// The car this phone is set up for, remembered across launches.
@Observable @MainActor
final class CarStore {
    // Read directly by the Toggle Boot intent, which runs off the main actor.
    nonisolated static let vinKey = "sentry.vin"
    nonisolated static let pairedKey = "sentry.paired"

    @ObservationIgnored private let defaults: UserDefaults

    var vin: String? {
        didSet { defaults.set(vin, forKey: Self.vinKey) }
    }

    /// Whether the car has accepted this phone's key.
    var isPaired: Bool {
        didSet { defaults.set(isPaired, forKey: Self.pairedKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        vin = defaults.string(forKey: Self.vinKey)
        isPaired = defaults.bool(forKey: Self.pairedKey)
    }
}
