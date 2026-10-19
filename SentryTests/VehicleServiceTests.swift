import Foundation
import Testing
@testable import Sentry
@testable import TeslaKit

struct VehicleServiceTests {
    private func service(for fake: FakeVehicle) -> VehicleService {
        VehicleService(vin: TestVectors.vin, key: TestVectors.clientKey, connect: { _ in fake })
    }

    @Test("toggleBootWording", arguments: [
        (VCSEC_ClosureState_E.closurestateClosed, BootToggleOutcome.opening),
        (.closurestateOpen, .closing), (.closurestateAjar, .closing),
        (.closurestateOpening, .moving), (.closurestateUnknown, .moving),
    ])
    func toggleBootWording(state: VCSEC_ClosureState_E, expected: BootToggleOutcome) async throws {
        let fake = FakeVehicle()
        fake.bodyStatus.closureStatuses.rearTrunk = state

        #expect(try await service(for: fake).toggleBoot() == expected)
        #expect(fake.commands.count == 1)
        #expect(fake.commands.first?.vcsec?.closureMoveRequest.rearTrunk == .closureMoveTypeMove)
        #expect(fake.isClosed)
    }

    @Test func toggleBootReportsNotInRange() async {
        let service = VehicleService(vin: TestVectors.vin, key: TestVectors.clientKey,
                                     connect: { _ in throw VehicleError.notInRange })
        await #expect(throws: VehicleError.notInRange) { try await service.toggleBoot() }
    }

    @Test func withClientClosesTransportOnError() async {
        let fake = FakeVehicle(script: .unknownKey)
        await #expect(throws: VehicleError.notPaired) {
            try await service(for: fake).withClient { try await $0.execute(.moveTrunk) }
        }
        #expect(fake.isClosed)
    }

    @Test func snapshotReadsBodyStatus() async throws {
        let fake = FakeVehicle()
        fake.bodyStatus.vehicleLockState = .vehiclelockstateLocked
        fake.bodyStatus.closureStatuses.rearTrunk = .closurestateOpen

        let snapshot = try await service(for: fake).snapshot()
        #expect(snapshot.isLocked)
        #expect(snapshot.rearTrunk == .open)
        #expect(fake.isClosed)
    }
}

@MainActor
struct PairingModelTests {
    private let defaults = UserDefaults(suiteName: "sentry.tests.\(UUID().uuidString)")!
    private let keyStore = KeyStore(service: "com.dodimead.sentry.tests.\(UUID().uuidString)")

    @Test func pairsAndRemembersCar() async throws {
        defer { try? keyStore.delete() }
        let store = CarStore(defaults: defaults)
        let fake = FakeVehicle(script: .pairAfter(polls: 0))
        let model = PairingModel(store: store, keyStore: keyStore, connect: { _ in fake })

        await model.start(vin: " \(TestVectors.vin.lowercased()) ")

        #expect(model.phase == .done)
        #expect(store.vin == TestVectors.vin)
        #expect(store.isPaired)
        #expect(fake.addKeyRequests.count == 1)
        #expect(fake.isClosed)
        // Both survive a relaunch.
        let reloaded = CarStore(defaults: defaults)
        #expect(reloaded.vin == TestVectors.vin)
        #expect(reloaded.isPaired)
    }

    @Test func rejectsInvalidVINWithoutConnecting() async {
        defer { try? keyStore.delete() }
        let store = CarStore(defaults: defaults)
        let model = PairingModel(store: store, keyStore: keyStore, connect: { _ in
            Issue.record("connected with an invalid VIN")
            throw VehicleError.notInRange
        })

        await model.start(vin: "7SAYGDEE5TA12345O")

        guard case .failed = model.phase else {
            Issue.record("expected .failed, got \(model.phase)")
            return
        }
        #expect(store.vin == nil)
        #expect(!store.isPaired)
    }

    @Test func reportsCarNotInRange() async {
        defer { try? keyStore.delete() }
        let store = CarStore(defaults: defaults)
        let model = PairingModel(store: store, keyStore: keyStore, connect: { _ in throw VehicleError.notInRange })

        await model.start(vin: TestVectors.vin)

        #expect(model.phase == .failed("Car not in range"))
        #expect(!store.isPaired)
    }
}
