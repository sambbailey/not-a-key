import Foundation
import Synchronization
import Testing
@testable import NotAKey
@testable import TeslaKit

struct VehicleServiceTests {
    private func service(for fake: FakeVehicle) -> VehicleService {
        VehicleService(vin: TestVectors.vin, key: TestVectors.clientKey, connect: { _ in fake })
    }

    @Test("toggleBootWording", arguments: [
        (VCSEC_ClosureState_E.closurestateClosed, BootToggleOutcome.opening),
        (.closurestateOpen, .closing), (.closurestateAjar, .closing),
        (.closurestateOpening, .moving), (.closurestateClosing, .moving), (.closurestateUnknown, .moving),
    ])
    func toggleBootWording(state: VCSEC_ClosureState_E, expected: BootToggleOutcome) async throws {
        let fake = FakeVehicle()
        fake.bodyStatus.closureStatuses.rearTrunk = state

        #expect(try await service(for: fake).toggleBoot() == expected)
        #expect(fake.commands.count == 1)
        #expect(fake.commands.first?.vcsec?.closureMoveRequest.rearTrunk == .closureMoveTypeMove)
        #expect(fake.isClosed)
    }

    @Test func watchDriveReadsOverOneConnectionUntilTheCarIsOutOfGear() async throws {
        let fake = FakeVehicle()
        fake.driveState.shiftState.d = CarServer_Void()
        fake.driveState.speedFloat = 30
        fake.chargeState.batteryLevel = 68
        fake.chargeState.batteryRange = 210
        let connections = Mutex(0)
        let service = VehicleService(vin: TestVectors.vin, key: TestVectors.clientKey, connect: { _ in
            connections.withLock { $0 += 1 }
            return fake.reconnected()
        })
        let updates = Mutex<[VehicleService.DriveUpdate]>([])

        try await service.watchDrive(every: .zero, statusEvery: 2) { update in
            let count = updates.withLock { $0.append(update); return $0.count }
            if count == 3 { fake.driveState.speedFloat = 31 }
            if count == 4 { fake.driveState.shiftState.p = CarServer_Void() }
        }

        let seen = updates.withLock { $0 }
        #expect(seen.map(\.drive.speedMph) == [30, 30, 30, 31, 31])
        #expect(seen.last?.drive.gear == .park)
        #expect(seen.map { $0.charge != nil } == [false, true, false, true, false])
        #expect(connections.withLock { $0 } == 1)
        #expect(fake.isClosed)
    }

    @Test func waitForDriveReadsParkedCarUntilItGoesIntoGear() async throws {
        let fake = FakeVehicle()
        fake.driveState.shiftState.p = CarServer_Void()
        fake.isAsleep = true
        let connections = Mutex(0)
        let service = VehicleService(vin: TestVectors.vin, key: TestVectors.clientKey, connect: { _ in
            connections.withLock { $0 += 1 }
            return fake.reconnected()
        })
        let waiting = Task { try await service.waitForDrive(every: .milliseconds(10)) }

        // Asleep, only the body controller is asked, so the car is left to sleep.
        try await Task.sleep(for: .milliseconds(50))
        #expect(fake.unansweredWhileAsleep == 0)
        fake.isAsleep = false
        try await Task.sleep(for: .milliseconds(50))
        fake.driveState.shiftState.d = CarServer_Void()
        fake.driveState.speedFloat = 3

        let drive = try await waiting.value
        #expect(drive.isDriving)
        #expect(drive.speedMph == 3)
        #expect(connections.withLock { $0 } == 1)
        #expect(fake.isClosed)
    }

    @Test func toggleBootStopsAtTheCallersDeadline() async {
        let fake = FakeVehicle(script: .silent)
        let start = ContinuousClock.now

        await #expect(throws: VehicleError.timeout) {
            try await service(for: fake).toggleBoot(before: start + .milliseconds(200))
        }
        #expect(ContinuousClock.now - start < .seconds(2))
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
    private let keyStore = KeyStore(service: "com.nevelen.notakey.tests.\(UUID().uuidString)")

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

    @Test func cancelWhileWaitingForTheCardGoesBackToVINEntry() async throws {
        defer { try? keyStore.delete() }
        let store = CarStore(defaults: defaults)
        let fake = FakeVehicle(script: .pairAfter(polls: 1_000))
        let model = PairingModel(store: store, keyStore: keyStore, connect: { _ in fake })

        model.pair(vin: TestVectors.vin)
        try await until { model.phase == .tapCard }
        model.cancel()

        // Back at once, so Pair works again without waiting for the connection to close.
        #expect(model.phase == .enterVIN)
        #expect(!model.isWorking)
        try await until { fake.isClosed }
        #expect(model.phase == .enterVIN)
        #expect(!store.isPaired)
    }

    @Test func aCancelledAttemptDoesNotOverwriteTheNextOne() async throws {
        defer { try? keyStore.delete() }
        let store = CarStore(defaults: defaults)
        let slow = FakeVehicle(script: .pairAfter(polls: 1_000))
        let quick = FakeVehicle(script: .pairAfter(polls: 0))
        let fakes = Mutex([slow, quick])
        let model = PairingModel(store: store, keyStore: keyStore, connect: { _ in
            fakes.withLock { $0.removeFirst() }
        })

        model.pair(vin: TestVectors.vin)
        try await until { model.phase == .tapCard }
        model.cancel()
        model.pair(vin: TestVectors.vin)
        try await until { model.phase == .done && slow.isClosed }

        #expect(model.phase == .done)
        #expect(store.isPaired)
    }

    /// Waits up to five seconds for `condition`, failing the test if it never holds.
    private func until(_ condition: () -> Bool) async throws {
        let giveUp = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < giveUp else {
                Issue.record("condition never held")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
