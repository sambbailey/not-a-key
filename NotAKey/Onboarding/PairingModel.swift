import Foundation
import Observation
import TeslaKit

/// Pairs this phone with the car: sends the add-key request, then waits while the owner
/// approves it on the car with a key card.
@Observable @MainActor
final class PairingModel {
    enum Phase: Equatable {
        case enterVIN, connecting, tapCard, done
        case failed(String)
    }

    private(set) var phase = Phase.enterVIN

    @ObservationIgnored private let store: CarStore
    @ObservationIgnored private let keyStore: KeyStore
    @ObservationIgnored private let connect: @Sendable (String) async throws -> VehicleTransport

    init(store: CarStore, keyStore: KeyStore = KeyStore(),
         connect: @escaping @Sendable (String) async throws -> VehicleTransport = {
             try await BLETransport.connect(vin: $0)
         }) {
        self.store = store
        self.keyStore = keyStore
        self.connect = connect
    }

    /// The attempt `pair` started, so `cancel` can stop it.
    @ObservationIgnored private var attempt: Task<Void, Never>?
    /// Counts attempts, so one that was cancelled can't change the phase once it unwinds.
    @ObservationIgnored private var attemptID = 0

    var isWorking: Bool {
        phase == .connecting || phase == .tapCard
    }

    /// Starts pairing in the background; `cancel` stops it.
    func pair(vin raw: String) {
        guard let (vin, id) = begin(vin: raw) else { return }
        attempt = Task { await run(vin: vin, id: id) }
    }

    /// Stops the attempt in flight and goes straight back to VIN entry, without waiting for the
    /// connection to close. A key the car already approved stays on the car; pairing again enrols the same key.
    func cancel() {
        guard isWorking else { return }
        attemptID += 1
        attempt?.cancel()
        attempt = nil
        phase = .enterVIN
    }

    func start(vin raw: String) async {
        guard let (vin, id) = begin(vin: raw) else { return }
        await run(vin: vin, id: id)
    }

    /// Claims a new attempt for a valid VIN, or returns nil if one is running or the VIN is bad.
    private func begin(vin raw: String) -> (String, Int)? {
        guard !isWorking else { return nil }
        guard let vin = VIN.normalize(raw) else {
            phase = .failed("That isn't a valid VIN")
            return nil
        }
        attemptID += 1
        phase = .connecting
        return (vin, attemptID)
    }

    private func run(vin: String, id: Int) async {
        do {
            let key = try loadOrReplaceKey()
            store.vin = vin
            store.isPaired = false
            try await VehicleService(vin: vin, key: key, connect: connect).withClient { client in
                try await client.sendAddKeyRequest(publicKeyX963: key.publicKeyX963)
                await self.setPhase(.tapCard, for: id)
                try await client.waitForPairing()
            }
            guard id == attemptID else { return }
            store.isPaired = true
            phase = .done
        } catch VehicleError.timeout where phase == .tapCard && id == attemptID {
            phase = .failed("The car didn't confirm the new key")
        } catch {
            setPhase(.failed(IntentMessages.failure(error)), for: id)
        }
    }

    private func setPhase(_ phase: Phase, for id: Int) {
        guard id == attemptID else { return }
        self.phase = phase
    }

    /// The device key to enrol. A stored key whose contents can't be decoded can never sign
    /// anything, and pairing enrols a key anyway, so it is replaced with a new one. Keychain
    /// failures are passed on: the stored key may be fine and already trusted by the car.
    private func loadOrReplaceKey() throws -> KeyAgreementKey {
        do {
            return try keyStore.loadOrCreate()
        } catch KeyStore.Failure.keychain(let status) {
            throw KeyStore.Failure.keychain(status)
        } catch KeyStore.Failure.accessControl {
            throw KeyStore.Failure.accessControl
        } catch {
            try keyStore.delete()
            return try keyStore.loadOrCreate()
        }
    }
}
