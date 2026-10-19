import Foundation
import Synchronization
import Testing
@testable import Sentry
@testable import TeslaKit

@MainActor
struct HomeModelTests {
    private let defaults: UserDefaults

    init() {
        let suite = "com.dodimead.sentry.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    private func model(for fake: FakeVehicle) -> HomeModel {
        HomeModel(store: ChargeStore(defaults: defaults)) { _ in
            VehicleService(vin: TestVectors.vin, key: TestVectors.clientKey, connect: { _ in fake.reconnected() })
        }
    }

    private static func chargeState(level: Int32, range: Float) -> CarServer_ChargeState {
        var state = CarServer_ChargeState()
        state.batteryLevel = level
        state.batteryRange = range
        return state
    }

    @Test func refreshReadsBodyAndChargeOverOneConnectionAndSavesThem() async {
        let fake = FakeVehicle()
        fake.chargeState = Self.chargeState(level: 82, range: 254.2)
        fake.bodyStatus.vehicleLockState = .vehiclelockstateLocked
        fake.bodyStatus.closureStatuses.rearTrunk = .closurestateClosed
        fake.bodyStatus.closureStatuses.frontTrunk = .closurestateClosed
        let model = model(for: fake)

        await model.refresh()

        #expect(model.reach == .nearby)
        #expect(model.charge?.batteryLevel == 82)
        #expect(model.body?.isLocked == true)
        #expect(model.body?.boot == .closed)
        #expect(fake.isClosed)
        // A relaunch shows the same readings before the car is reached.
        let relaunched = HomeModel(store: ChargeStore(defaults: defaults)) { _ in throw HomeModel.KeyUnavailable() }
        #expect(relaunched.charge == model.charge)
        #expect(relaunched.body == model.body)
    }

    @Test func outOfRangeKeepsLastReadingsWithoutABanner() async {
        let store = ChargeStore(defaults: defaults)
        let earlier = ChargeReading(batteryLevel: 79, rangeMiles: 245, isCharging: false, readAt: .now)
        store.save(earlier)
        let model = HomeModel(store: store) { _ in
            VehicleService(vin: TestVectors.vin, key: TestVectors.clientKey,
                           connect: { _ in throw VehicleError.notInRange })
        }

        await model.refresh()

        #expect(model.reach == .notInRange)
        #expect(model.charge == earlier)
        #expect(model.banner == nil)
    }

    @Test func missingKeySaysSoInTheBanner() async {
        let model = HomeModel(store: ChargeStore(defaults: defaults)) { _ in throw HomeModel.KeyUnavailable() }

        await model.refresh()

        #expect(model.keyIsMissing)
        #expect(model.banner?.isError == true)
    }

    @Test func bootTapSendsMoveAndNamesWhatItDid() async {
        let fake = FakeVehicle()
        fake.bodyStatus.closureStatuses.rearTrunk = .closurestateClosed
        let model = model(for: fake)

        await model.perform(.boot)

        #expect(fake.commands.contains { $0.vcsec?.closureMoveRequest.rearTrunk == .closureMoveTypeMove })
        #expect(model.banner?.message == "Opening boot")
        #expect(model.banner?.control == .boot)
        #expect(model.working == nil)
        #expect(fake.isClosed)
    }

    @Test func doorsUnlockWhenLockedAndWaitForAReadingOtherwise() async {
        let fake = FakeVehicle()
        fake.bodyStatus.vehicleLockState = .vehiclelockstateLocked
        // A read without charge fails as a whole, so the fake needs one for the lock state to land.
        fake.chargeState = Self.chargeState(level: 82, range: 254.2)
        let model = model(for: fake)
        #expect(model.command(for: .doors) == nil)

        await model.refresh()
        #expect(model.command(for: .doors) == .unlock)

        await model.perform(.doors)
        #expect(fake.commands.contains { $0.vcsec?.rkeaction == .rkeActionUnlock })
        #expect(model.banner?.message == "Unlocked")
    }

    @Test func openFrunkHasNoCommand() async {
        let fake = FakeVehicle()
        fake.bodyStatus.closureStatuses.frontTrunk = .closurestateOpen
        let model = model(for: fake)

        await model.refresh()

        #expect(model.command(for: .frunk) == nil)
    }

    @Test func climateFlipsBetweenStartAndStop() async {
        let fake = FakeVehicle()
        let model = model(for: fake)
        #expect(model.command(for: .climate) == .climateOn)

        await model.perform(.climate)

        #expect(model.climate?.isOn == true)
        #expect(model.banner?.message == "Climate on")
        #expect(model.command(for: .climate) == .climateOff)
    }

    @Test func failedCommandShowsTheReasonAndRawError() async {
        let model = model(for: FakeVehicle(script: .unknownKey))

        await model.perform(.boot)

        #expect(model.banner?.isError == true)
        #expect(model.banner?.message == "Key not paired")
        #expect(model.banner?.detail != nil)
        #expect(model.working == nil)
    }
}

struct HomeTextTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("age", arguments: [
        (0.0, "just now"), (59, "just now"), (120, "2 min ago"), (10_805, "3 h ago"), (172_800, "2 d ago"),
        (-30, "just now"),
    ] as [(Double, String)])
    func age(secondsAgo: Double, expected: String) {
        #expect(HomeText.age(of: now - secondsAgo, now: now) == expected)
    }

    @Test func statusLine() {
        let charge = ChargeReading(batteryLevel: 82, rangeMiles: 254, isCharging: true, readAt: now - 120)
        let body = BodyReading(isLocked: true, boot: .closed, frunk: .closed, readAt: now - 120)

        #expect(HomeText.statusLine(charge: charge, body: body, isReading: false, now: now)
                == "Charging · Locked · Updated 2 min ago")
        #expect(HomeText.statusLine(charge: nil, body: nil, isReading: true, now: now) == "Reading the car…")
        #expect(HomeText.awayLine(charge: charge, body: body, now: now + 3 * 3600) == "Last seen 3 h ago · Locked")
        #expect(HomeText.awayLine(charge: nil, body: nil, now: now) == "Not read yet")
    }

    @Test("bootAction", arguments: [
        (BodyReading.Closure?.some(.closed), "Open"), (.open, "Close"), (.ajar, "Close"),
        (.opening, "Stop"), (.closing, "Stop"), (.unknown, "Move"), (nil, "Move"),
    ])
    func bootAction(boot: BodyReading.Closure?, expected: String) {
        #expect(HomeText.bootAction(boot) == expected)
    }

    @Test("modelName", arguments: [
        ("7SAYGDEE5TA123456", "Model Y"), ("5YJ3E1EA7KF123456", "Model 3"), ("5YJSA1E26MF123456", "Model S"),
        ("7SAXCDE51PF123456", "Model X"), ("1HGCM82633A004352", nil),
    ] as [(String, String?)])
    func modelName(vin: String, expected: String?) {
        #expect(VIN.modelName(vin) == expected)
    }
}

@MainActor
struct ChargePortClimateDriveTests {
    private let defaults: UserDefaults

    init() {
        let suite = "com.dodimead.sentry.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    private func model(for fake: FakeVehicle) -> HomeModel {
        HomeModel(store: ChargeStore(defaults: defaults)) { _ in
            VehicleService(vin: TestVectors.vin, key: TestVectors.clientKey, connect: { _ in fake.reconnected() })
        }
    }

    private static func fakeCar() -> FakeVehicle {
        let fake = FakeVehicle()
        fake.chargeState.batteryLevel = 68
        fake.chargeState.batteryRange = 210
        return fake
    }

    @Test func chargePortOpensWhenClosedAndStopsWhileCharging() async {
        let fake = Self.fakeCar()
        fake.chargeState.chargePortDoorOpen = false
        let model = model(for: fake)
        await model.refresh()
        #expect(model.command(for: .chargePort) == .openChargePort)
        #expect(ChargePortText.state(model.charge) == "Closed")

        await model.perform(.chargePort)
        #expect(fake.commands.contains { if case .chargePortDoorOpen? = $0.carServer?.vehicleAction.vehicleActionMsg { true } else { false } })
        #expect(model.charge?.isPortOpen == true)
        #expect(model.command(for: .chargePort) == .closeChargePort)

        fake.chargeState.chargingState.charging = CarServer_Void()
        fake.chargeState.chargerPower = 7
        await model.refresh()
        #expect(ChargePortText.state(model.charge) == "Charging · 7 kW")
        #expect(model.command(for: .chargePort) == .stopCharging)
    }

    @Test func dogModeShowsOnTheClimateRow() async {
        let fake = Self.fakeCar()
        let model = model(for: fake)
        await model.refresh()

        await model.send(.climateKeeper(.dog), for: .climate)
        #expect(fake.commands.contains {
            $0.carServer?.vehicleAction.hvacClimateKeeperAction.climateKeeperAction == .climateKeeperActionDog
        })
        #expect(model.climate?.keeperMode == .dog)
        #expect(model.command(for: .climate) == .climateOff)
        var climate = ClimateSnapshot(isOn: true, setCelsius: 21, keeperMode: .dog)
        #expect(ClimateText.summary(climate) == "Dog mode · 21°")
        climate.keeperMode = .off
        #expect(ClimateText.summary(climate) == "On")
    }

    @Test func campModeReadsFromTheCarsPartyMode() {
        var state = CarServer_ClimateState()
        state.climateKeeperMode.party = CarServer_Void()
        #expect(ClimateSnapshot(state).keeperMode == .camp)
    }

    @Test func drivingLocksEverythingButClimate() async {
        let fake = Self.fakeCar()
        fake.driveState.shiftState.d = CarServer_Void()
        fake.driveState.speedFloat = 43
        fake.driveState.power = -12
        fake.driveState.odometerInHundredthsOfAMile = 1_248_100
        let model = model(for: fake)
        await model.refresh()
        model.stop()

        #expect(model.isDriving)
        #expect(model.drive?.speedMph == 43)
        #expect(model.drive?.odometerMiles == 12_481)
        #expect(model.drive?.route == nil)
        for control in [HomeModel.Control.boot, .doors, .frunk, .chargePort] {
            #expect(model.command(for: control) == nil)
        }
        #expect(model.command(for: .climate) != nil)
        #expect(DriveText.power(-12) == "\u{2212}12 kW")
        #expect(DriveText.power(18) == "+18 kW")
    }

    @Test func drivingReadsLiveOverOneConnectionAndStopsOnPark() async throws {
        let fake = Self.fakeCar()
        fake.driveState.shiftState.d = CarServer_Void()
        fake.driveState.speedFloat = 30
        let connections = Mutex(0)
        let model = HomeModel(store: ChargeStore(defaults: defaults), drivingRefresh: .milliseconds(10)) { _ in
            VehicleService(vin: TestVectors.vin, key: TestVectors.clientKey, connect: { _ in
                connections.withLock { $0 += 1 }
                return fake.reconnected()
            })
        }
        await model.refresh()
        #expect(model.isDriving)

        fake.driveState.speedFloat = 52
        try await Self.waitUntil { model.drive?.speedMph == 52 }
        // The first full read, then one held connection for the live reads.
        #expect(connections.withLock { $0 } == 2)

        fake.driveState.shiftState.p = CarServer_Void()
        try await Self.waitUntil { !model.isDriving && !model.isReading }
        #expect(model.command(for: .boot) == .moveTrunk)
        model.stop()
    }

    @Test func climateWhileDrivingPausesTheLiveReadsAndResumesThem() async throws {
        let fake = Self.fakeCar()
        fake.driveState.shiftState.d = CarServer_Void()
        fake.driveState.speedFloat = 30
        let model = HomeModel(store: ChargeStore(defaults: defaults), drivingRefresh: .milliseconds(10)) { _ in
            VehicleService(vin: TestVectors.vin, key: TestVectors.clientKey, connect: { _ in fake.reconnected() })
        }
        await model.refresh()

        await model.perform(.climate)
        #expect(model.banner?.isError == false)
        #expect(fake.overlappingRequests == 0)

        fake.driveState.speedFloat = 41
        try await Self.waitUntil { model.drive?.speedMph == 41 }
        model.stop()
    }

    private static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func parkedIsNotDriving() async {
        let fake = Self.fakeCar()
        fake.driveState.shiftState.p = CarServer_Void()
        let model = model(for: fake)
        await model.refresh()
        #expect(!model.isDriving)
        #expect(model.command(for: .boot) == .moveTrunk)
    }

    @Test func routeIsReadFromTheCarsNav() {
        var state = CarServer_DriveState()
        state.shiftState.d = CarServer_Void()
        state.activeRouteDestination = "Home"
        state.activeRouteMinutesToArrival = 18
        state.activeRouteMilesToArrival = 12.4
        state.activeRouteEnergyAtArrival = 64
        let route = DriveSnapshot(state).route
        #expect(route?.destination == "Home")
        #expect(route?.minutesToArrival == 18)
        #expect(route?.batteryAtArrival == 64)
        #expect(DriveText.minutes(18) == "18 min")
        #expect(DriveText.minutes(65) == "1 h 5 min")
    }
}
