import Foundation
import Testing
@testable import NotAKey
@testable import TeslaKit

struct MockVehicleServiceTests {
    private func car(frunkShutsAfter: Duration = .seconds(30)) -> MockVehicleService {
        MockVehicleService(commandDelay: .zero, readDelay: .zero, frunkShutsAfter: frunkShutsAfter)
    }

    @Test func startsAsADemoModelYLockedAndPluggedInAt72Percent() async throws {
        let status = try await car().status(before: nil)
        #expect(status.body.isLocked)
        #expect(status.body.rearTrunk == .closed && status.body.frontTrunk == .closed)
        #expect(status.charge.batteryLevel == 72)
        #expect(status.charge.rangeMiles == 237.6)
        #expect(status.charge.chargingState == .stopped)
        #expect(status.charge.chargeLimit == 80)
        #expect(status.climate?.isOn == false)
        #expect(status.sentry?.state == .armed)
        #expect(status.drive?.gear == .park)
    }

    @Test func locksAndUnlocks() async throws {
        let car = car()
        let unlocked = try await car.send(.unlock, before: nil)
        #expect(unlocked.before.isLocked)
        #expect(!unlocked.after.isLocked)
        let locked = try await car.send(.lock, before: nil)
        #expect(locked.after.isLocked)
    }

    @Test func bootOpensThenClosesAndIsSeenMoving() async throws {
        let car = car()
        #expect(try await car.send(.moveTrunk, before: nil).after.rearTrunk == .opening)
        #expect(try await car.snapshot().rearTrunk == .open)
        #expect(try await car.send(.moveTrunk, before: nil).after.rearTrunk == .closing)
        #expect(try await car.snapshot().rearTrunk == .closed)
    }

    @Test func toggleBootSaysWhatItIsAboutToDo() async throws {
        let car = car()
        #expect(try await car.toggleBoot(before: nil) == .opening)
        #expect(try await car.toggleBoot(before: nil) == .closing)
        #expect(await car.state.body.rearTrunk == .closing)
    }

    @Test func frunkOpensAndIsShutByHandLater() async throws {
        let car = car(frunkShutsAfter: .milliseconds(50))
        #expect(try await car.send(.openFrunk, before: nil).after.frontTrunk == .opening)
        #expect(try await car.snapshot().frontTrunk == .open)
        try await Task.sleep(for: .milliseconds(80))
        #expect(try await car.snapshot().frontTrunk == .closed)
    }

    @Test func chargingStartsAndStops() async throws {
        let car = car()
        let started = try #require(try await car.send(.startCharging, before: nil).charge)
        #expect(started.isCharging)
        #expect(started.chargingState == .charging)
        #expect(started.chargerAmps == 16 && started.chargerVolts == 230)
        #expect(started.chargerPowerKW == 4)
        #expect(started.minutesToLimit == 98)

        let stopped = try #require(try await car.send(.stopCharging, before: nil).charge)
        #expect(!stopped.isCharging)
        #expect(stopped.chargingState == .stopped)
    }

    @Test func eachReadWhileChargingAddsAPercentUntilTheLimit() async throws {
        let car = car()
        _ = try await car.send(.setChargeLimit(percent: 74), before: nil)
        _ = try await car.send(.startCharging, before: nil)
        let first = try await car.status(before: nil).charge
        #expect(first.batteryLevel == 73)
        #expect(first.isCharging)
        #expect(first.energyAddedKWh == 0.8)
        let second = try await car.status(before: nil).charge
        #expect(second.batteryLevel == 74)
        #expect(second.chargingState == .complete)
        #expect(!second.isCharging)
        #expect(try await car.status(before: nil).charge.batteryLevel == 74)
    }

    @Test func chargeLimitAndAmpsChangeAndStayInRange() async throws {
        let car = car()
        #expect(try await car.send(.setChargeLimit(percent: 90), before: nil).charge?.chargeLimit == 90)
        #expect(try await car.send(.setChargeLimit(percent: 30), before: nil).charge?.chargeLimit == 50)
        #expect(try await car.send(.setChargingAmps(32), before: nil).charge?.currentRequest == 32)
        #expect(try await car.send(.setChargingAmps(48), before: nil).charge?.currentRequest == 32)
        _ = try await car.send(.setChargeLimit(percent: 90), before: nil)
        let charging = try #require(try await car.send(.startCharging, before: nil).charge)
        #expect(charging.chargerPowerKW == 7)
    }

    @Test func startingChargeAtOrAboveTheLimitCompletes() async throws {
        let car = car()
        _ = try await car.send(.setChargeLimit(percent: 50), before: nil)
        let charge = try #require(try await car.send(.startCharging, before: nil).charge)
        #expect(!charge.isCharging)
        #expect(charge.chargingState == .complete)
    }

    @Test func climateTurnsOnAndWarmsTheCabinTowardsTheSetTemperature() async throws {
        let car = car()
        _ = try await car.send(.setTemperature(celsius: 22), before: nil)
        _ = try await car.send(.climateOn, before: nil)
        let climate = try #require(try await car.status(before: nil).climate)
        #expect(climate.isOn)
        #expect(climate.setCelsius == 22)
        #expect(climate.insideCelsius == 15.5)

        _ = try await car.send(.climateKeeper(.dog), before: nil)
        #expect(await car.state.climate.keeperMode == .dog)
        _ = try await car.send(.climateOff, before: nil)
        let off = await car.state.climate
        #expect(!off.isOn)
        #expect(off.keeperMode == .off)
    }

    @Test func defrostTurnsClimateOn() async throws {
        let car = car()
        _ = try await car.send(.setDefrost(true), before: nil)
        let climate = await car.state.climate
        #expect(climate.isDefrosting && climate.isOn)
    }

    @Test func sentryTurnsOffAndOn() async throws {
        let car = car()
        #expect(try await car.send(.setSentryMode(false), before: nil).sentry?.state == .off)
        #expect(try await car.send(.setSentryMode(true), before: nil).sentry?.state == .armed)
        #expect(try await car.send(.lock, before: nil).sentry == nil)
    }

    @Test func chargePortOpensAndCloses() async throws {
        let car = car()
        #expect(try await car.send(.closeChargePort, before: nil).charge?.isPortOpen == false)
        #expect(try await car.send(.openChargePort, before: nil).charge?.isPortOpen == true)
    }

    @Test func resetPutsTheCarBackAsItStarts() async throws {
        let car = car()
        _ = try await car.send(.unlock, before: nil)
        _ = try await car.send(.climateOn, before: nil)
        await car.reset()
        #expect(await car.state == .initial)
    }

    @Test func waitForDriveKeepsReadingAParkedCarUntilCancelled() async throws {
        let car = car()
        let reads = AsyncStream<VehicleSnapshot>.makeStream()
        let waiting = Task { try await car.waitForDrive(every: .milliseconds(5)) { reads.continuation.yield($0) } }
        var count = 0
        for await _ in reads.stream {
            count += 1
            if count == 3 { break }
        }
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
    }

    @MainActor @Test func homeModelDrivesTheDemoCarThroughItsUsualPaths() async throws {
        let defaults = UserDefaults(suiteName: "MockVehicleServiceTests.home")!
        defaults.removePersistentDomain(forName: "MockVehicleServiceTests.home")
        let car = car()
        let model = HomeModel(store: ChargeStore(defaults: defaults)) { _ in car }
        await model.refresh()
        #expect(model.reach == .nearby)
        #expect(model.charge?.batteryLevel == 72)
        #expect(model.command(for: .doors) == .unlock)

        await model.perform(.doors)
        #expect(model.body?.isLocked == false)
        #expect(model.banner?.isError == false)

        await model.perform(.chargePort)
        #expect(model.charge?.phase == .charging)
        await model.perform(.climate)
        #expect(model.climate?.isOn == true)
        model.stop()
    }
}
