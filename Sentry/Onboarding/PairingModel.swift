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

    var isWorking: Bool {
        phase == .connecting || phase == .tapCard
    }

    func start(vin raw: String) async {
        guard !isWorking else { return }
        guard let vin = VIN.normalize(raw) else {
            phase = .failed("That isn't a valid VIN")
            return
        }
        phase = .connecting
        do {
            let key = try loadOrReplaceKey()
            store.vin = vin
            store.isPaired = false
            try await VehicleService(vin: vin, key: key, connect: connect).withClient { client in
                try await client.sendAddKeyRequest(publicKeyX963: key.publicKeyX963)
                await self.setPhase(.tapCard)
                try await client.waitForPairing()
            }
            store.isPaired = true
            phase = .done
        } catch VehicleError.timeout where phase == .tapCard {
            phase = .failed("The car didn't confirm the new key")
        } catch {
            phase = .failed(IntentMessages.failure(error))
        }
    }

    private func setPhase(_ phase: Phase) {
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
