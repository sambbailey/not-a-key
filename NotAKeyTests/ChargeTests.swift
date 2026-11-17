import Foundation
import Testing
@testable import NotAKey
@testable import TeslaKit

struct ChargeTests {
    private let defaults: UserDefaults

    init() {
        let suite = "com.nevelen.notakey.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    private func service(for fake: FakeVehicle) -> VehicleService {
        VehicleService(vin: TestVectors.vin, key: TestVectors.clientKey, connect: { _ in fake })
    }

    private static func chargeState(level: Int32, range: Float) -> CarServer_ChargeState {
        var state = CarServer_ChargeState()
        state.batteryLevel = level
        state.batteryRange = range
        return state
    }

    @Test func readsChargeFromAwakeCarWithoutWaking() async throws {
        let fake = FakeVehicle()
        fake.chargeState = Self.chargeState(level: 78, range: 245.4)

        let snapshot = try await service(for: fake).charge()

        #expect(snapshot == ChargeSnapshot(batteryLevel: 78, rangeMiles: 245.4, isCharging: false))
        #expect(fake.commands.allSatisfy { $0.vcsec == nil })
        #expect(fake.isClosed)
    }

    @Test func wakesSleepingCarBeforeReadingCharge() async throws {
        let fake = FakeVehicle()
        fake.isAsleep = true
        fake.chargeState = Self.chargeState(level: 78, range: 245.4)

        let snapshot = try await service(for: fake).charge()

        #expect(snapshot.batteryLevel == 78)
        #expect(fake.statusRequests == 1)
        // Wake, then charge; climate and drive state are read after it.
        #expect(fake.commands.count >= 2)
        #expect(fake.commands.first?.vcsec?.rkeaction == .rkeActionWakeVehicle)
        #expect(fake.commands.dropFirst().first?.carServer?.vehicleAction.getVehicleData.hasGetChargeState == true)
        #expect(fake.isClosed)
    }

    @Test func chargeStopsAtTheCallersDeadline() async {
        let fake = FakeVehicle()
        fake.isAsleep = true
        let start = ContinuousClock.now

        // A car that stays asleep: the wake goes nowhere, so only the deadline ends the wait.
        fake.ignoresWake = true
        await #expect(throws: VehicleError.timeout) {
            try await service(for: fake).charge(before: start + .milliseconds(300))
        }
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func chargeReadFailsCleanlyOutOfRange() async throws {
        let store = ChargeStore(defaults: defaults)
        let earlier = ChargeReading(batteryLevel: 60, rangeMiles: 190, isCharging: false,
                                    readAt: Date(timeIntervalSince1970: 1_700_000_000))
        store.save(earlier)
        let service = VehicleService(vin: TestVectors.vin, key: TestVectors.clientKey,
                                     connect: { _ in throw VehicleError.notInRange })

        await #expect(throws: VehicleError.notInRange) { try await service.refreshCharge(into: store) }
        #expect(store.last == earlier)
    }

    @Test func refreshChargeSavesTheReading() async throws {
        let store = ChargeStore(defaults: defaults)
        let fake = FakeVehicle()
        fake.chargeState = Self.chargeState(level: 78, range: 245.4)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let reading = try await service(for: fake).refreshCharge(into: store, now: { now })

        #expect(reading == ChargeReading(batteryLevel: 78, rangeMiles: 245.4, isCharging: false, readAt: now))
        #expect(store.last == reading)
    }

    @Test func cachesLastReading() {
        let readAt = Date(timeIntervalSince1970: 1_800_000_123.5)
        let reading = ChargeReading(batteryLevel: 78, rangeMiles: 245.4, isCharging: true, readAt: readAt)
        #expect(ChargeStore(defaults: defaults).last == nil)

        ChargeStore(defaults: defaults).save(reading)

        // A fresh store on the same defaults stands in for a relaunch.
        let reloaded = ChargeStore(defaults: defaults).last
        #expect(reloaded == reading)
        #expect(reloaded?.readAt == readAt)
    }

    @Test("chargeWording", arguments: [
        (78, 245.4, "78%", "245 mi"),
        (100, 310.6, "100%", "311 mi"),
        (0, 0.4, "0%", "0 mi"),
    ])
    func chargeWording(level: Int, range: Double, levelText: String, rangeText: String) {
        let reading = ChargeReading(batteryLevel: level, rangeMiles: range, isCharging: false, readAt: .now)
        #expect(reading.levelText == levelText)
        #expect(reading.rangeText == rangeText)
    }
}
