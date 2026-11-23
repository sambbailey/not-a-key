import Foundation
import Observation

/// The car this phone is set up for, remembered across launches.
@Observable @MainActor
final class CarStore {
    // Read directly by the Toggle Boot intent, which runs off the main actor.
    nonisolated static let vinKey = "sentry.vin"
    nonisolated static let pairedKey = "sentry.paired"
    static let faceIDForUnlockKey = "sentry.faceIDForUnlock"

    @ObservationIgnored private let defaults: UserDefaults

    /// In demo mode, the simulated car every read and command goes to; nil for a real car.
    @ObservationIgnored let demoCar: MockVehicleService?

    var vin: String? {
        didSet { defaults.set(vin, forKey: Self.vinKey) }
    }

    /// Whether the car has accepted this phone's key.
    var isPaired: Bool {
        didSet { defaults.set(isPaired, forKey: Self.pairedKey) }
    }

    /// Whether unlocking the doors asks for Face ID first.
    var faceIDForUnlock: Bool {
        didSet { defaults.set(faceIDForUnlock, forKey: Self.faceIDForUnlockKey) }
    }

    init(defaults: UserDefaults = .standard, demoCar: MockVehicleService? = nil) {
        self.defaults = defaults
        self.demoCar = demoCar
        vin = defaults.string(forKey: Self.vinKey)
        isPaired = defaults.bool(forKey: Self.pairedKey)
        faceIDForUnlock = defaults.bool(forKey: Self.faceIDForUnlockKey)
    }

    /// The car's name for headings, e.g. "Model Y"; nil if the VIN doesn't say.
    var carName: String? {
        demoCar != nil ? Self.demoCarName : vin.flatMap(VIN.modelName)
    }

    /// Where the readings this store's car is shown with are remembered.
    var chargeStore: ChargeStore { ChargeStore(defaults: defaults) }

    /// Deletes this phone's car key and goes back to setup. In demo mode there's no key, so this
    /// only leaves the demo.
    func removeKey(keyStore: KeyStore = KeyStore()) throws {
        if demoCar == nil { try keyStore.delete() }
        isPaired = false
    }
}

// MARK: - Demo mode

extension CarStore {
    /// Demo mode keeps its settings and readings here, apart from the real car's.
    nonisolated static let demoSuite = "com.nevelen.notakey.demo-mode"
    static let demoCarName = "Demo Model Y"
    /// A made-up Model Y VIN, shown in Settings.
    static let demoVIN = "7SAYGDEE0PA000001"

    /// The demo car's store. It counts as paired while demo mode is on, which lasts across launches
    /// until the owner leaves it.
    static func demo() -> CarStore {
        CarStore(defaults: UserDefaults(suiteName: demoSuite)!, demoCar: .shared)
    }

    /// Whether demo mode is on; read by the Toggle Boot intent, which runs off the main actor.
    nonisolated static var isDemoOn: Bool {
        UserDefaults(suiteName: demoSuite)?.bool(forKey: pairedKey) == true
    }

    /// Starts a fresh demo: the simulated car as it starts, and no readings from an earlier one.
    func startDemo() async {
        guard let demoCar else { return }
        await demoCar.reset()
        defaults.removePersistentDomain(forName: Self.demoSuite)
        vin = Self.demoVIN
        faceIDForUnlock = false
        isPaired = true
    }

    /// Leaves demo mode, back to setup.
    func endDemo() {
        guard demoCar != nil else { return }
        isPaired = false
    }
}
