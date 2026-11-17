import Foundation
import Synchronization
import Testing
@testable import NotAKey
@testable import TeslaKit

@MainActor
struct HomeModelTests {
    private let defaults: UserDefaults

    init() {
        let suite = "com.nevelen.notakey.tests.\(UUID().uuidString)"
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
        // The watch for the car going into gear holds the connection until stopped.
        model.stop()
        for _ in 0..<100 where !fake.isClosed { try? await Task.sleep(for: .milliseconds(10)) }
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

    @Test func keyLockedBeforeFirstUnlockDoesNotAskToRepair() async {
        let model = HomeModel(store: ChargeStore(defaults: defaults)) { _ in
            throw KeyStore.Failure.keychain(errSecInteractionNotAllowed)
        }

        await model.refresh()

        #expect(!model.keyIsMissing)
        #expect(model.banner?.message == "Unlock your iPhone once, then try again")
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

    @Test func unlockWaitsForTheOwnerAndStaysLockedIfTheyDontConfirm() async {
        let fake = FakeVehicle()
        fake.bodyStatus.vehicleLockState = .vehiclelockstateLocked
        fake.chargeState = Self.chargeState(level: 82, range: 254.2)
        let asked = Mutex(0)
        let confirms = Mutex(false)
        let model = HomeModel(store: ChargeStore(defaults: defaults), confirmUnlock: {
            asked.withLock { $0 += 1 }
            return confirms.withLock { $0 }
        }) { _ in
            VehicleService(vin: TestVectors.vin, key: TestVectors.clientKey, connect: { _ in fake.reconnected() })
        }
        await model.refresh()

        await model.perform(.doors)
        #expect(asked.withLock { $0 } == 1)
        #expect(!fake.commands.contains { $0.vcsec?.rkeaction == .rkeActionUnlock })
        #expect(model.banner == nil)

        confirms.withLock { $0 = true }
        await model.perform(.doors)
        #expect(asked.withLock { $0 } == 2)
        #expect(fake.commands.contains { $0.vcsec?.rkeaction == .rkeActionUnlock })

        // Locking never asks.
        fake.bodyStatus.vehicleLockState = .vehiclelockstateUnlocked
        await model.refresh()
        #expect(model.command(for: .doors) == .lock)
        await model.perform(.doors)
        #expect(asked.withLock { $0 } == 2)
        #expect(fake.commands.contains { $0.vcsec?.rkeaction == .rkeActionLock })
    }

    @Test func faceIDForUnlockIsOffUntilTurnedOnAndRemembered() {
        let car = CarStore(defaults: defaults)
        #expect(!car.faceIDForUnlock)
        car.faceIDForUnlock = true
        #expect(CarStore(defaults: defaults).faceIDForUnlock)
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
                == "Charging · Updated 2 min ago")
        #expect(HomeText.statusLine(charge: nil, body: body, isReading: false, now: now) == "Parked · Updated 2 min ago")
        #expect(HomeText.statusLine(charge: nil, body: nil, isReading: true, now: now) == "Reading the car…")
        #expect(HomeText.awayLine(charge: charge, body: body, now: now + 3 * 3600) == "Last seen 3 h ago · Locked")
        #expect(HomeText.awayLine(charge: nil, body: nil, now: now) == "Not read yet")
        #expect(HomeText.awayLine(charge: charge, body: body, sentry: SentrySnapshot(state: .quiet), now: now + 3 * 3600)
                == "Last seen 3 h ago · Locked · Sentry armed")
        #expect(HomeText.shortAge(of: now - 120, now: now) == "2 min")
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
        let suite = "com.nevelen.notakey.tests.\(UUID().uuidString)"
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

        // The car reports the port open when it's read after the command.
        fake.chargeState.chargePortDoorOpen = true
        await model.perform(.chargePort)
        #expect(fake.commands.contains { if case .chargePortDoorOpen? = $0.carServer?.vehicleAction.vehicleActionMsg { true } else { false } })
        #expect(model.charge?.isPortOpen == true)
        #expect(model.command(for: .chargePort) == .closeChargePort)

        fake.chargeState.chargingState.charging = CarServer_Void()
        fake.chargeState.chargerPower = 7
        await model.refresh()
        #expect(ChargePortText.state(model.charge) == "Plugged in · 7 kW")
        #expect(ChargePortText.action(model.charge) == "Details")
        #expect(model.command(for: .chargePort) == .stopCharging)
    }

    @Test func pluggedInChargeNowStartsAndReadsChargeAgain() async {
        let fake = Self.fakeCar()
        fake.chargeState.chargingState.stopped = CarServer_Void()
        fake.chargeState.chargeLimitSoc = 90
        let model = model(for: fake)
        await model.refresh()
        #expect(model.charge?.phase == .plugged)
        #expect(ChargePortText.state(model.charge) == "Plugged in · Not charging")
        #expect(ChargePortText.action(model.charge) == "Charge now")
        #expect(model.command(for: .chargePort) == .startCharging)

        // The car has started by the time it's read after the command.
        fake.chargeState.chargingState.charging = CarServer_Void()
        fake.chargeState.chargerPower = 7
        await model.perform(.chargePort)

        #expect(fake.commands.contains {
            if case .start? = $0.carServer?.vehicleAction.chargingStartStopAction.chargingAction { true } else { false }
        })
        #expect(model.charge?.phase == .charging)
        #expect(model.charge?.chargerPowerKW == 7)
        #expect(model.banner?.message == "Charging started")
    }

    @Test func chargeLimitAndStopAreSentAndReadBack() async {
        let fake = Self.fakeCar()
        fake.chargeState.chargingState.charging = CarServer_Void()
        fake.chargeState.chargeLimitSoc = 80
        let model = model(for: fake)
        await model.refresh()

        // The car still reports the old limit straight after taking the new one.
        await model.send(.setChargeLimit(percent: 85), for: .chargePort)
        #expect(fake.commands.contains { $0.carServer?.vehicleAction.chargingSetLimitAction.percent == 85 })
        #expect(model.charge?.chargeLimit == 85)

        fake.chargeState.chargingState.stopped = CarServer_Void()
        await model.send(.stopCharging, for: .chargePort)
        #expect(model.charge?.phase == .plugged)
        #expect(model.banner?.message == "Charging stopped")
    }

    @Test func steppingTheLimitShowsEachStepAndSendsOnlyTheLastOnceSettled() async throws {
        let fake = Self.fakeCar()
        fake.chargeState.chargingState.charging = CarServer_Void()
        fake.chargeState.chargeLimitSoc = 80
        fake.chargeState.chargeLimitSocMin = 50
        fake.chargeState.chargeLimitSocMax = 100
        let model = HomeModel(store: ChargeStore(defaults: defaults), settingSettle: .milliseconds(300)) { _ in
            VehicleService(vin: TestVectors.vin, key: TestVectors.clientKey, connect: { _ in fake.reconnected() })
        }
        await model.refresh()
        let sent = { fake.commands.compactMap { command -> Int32? in
            guard case .chargingSetLimitAction(let action)? = command.carServer?.vehicleAction.vehicleActionMsg else { return nil }
            return action.percent
        } }

        model.step(.limit, by: 1)
        model.step(.limit, by: 1)
        model.step(.limit, by: 1)
        #expect(model.value(of: .limit) == 83)
        #expect(sent().isEmpty)

        for _ in 0..<300 where model.pending[.limit] != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(sent() == [83])
        #expect(model.value(of: .limit) == 83)

        // Dragging the bar sets the value directly, kept within the car's range.
        model.set(.limit, to: 120)
        #expect(model.value(of: .limit) == 100)

        // Stepping back down past the car's value never goes below its lowest limit.
        for _ in 0..<60 { model.step(.limit, by: -1) }
        #expect(model.value(of: .limit) == 50)
        model.stop()
    }

    @Test func unlockingTheCableOpensThePortAndSaysSo() async {
        let fake = Self.fakeCar()
        fake.chargeState.chargingState.charging = CarServer_Void()
        let model = model(for: fake)
        await model.refresh()

        await model.send(.openChargePort, for: .chargePort)
        #expect(fake.commands.contains { if case .chargePortDoorOpen? = $0.carServer?.vehicleAction.vehicleActionMsg { true } else { false } })
        #expect(model.banner?.message == "Cable unlocked")
    }

    @Test func sentryRowTurnsOffWhenArmedAndReadsBack() async {
        let fake = Self.fakeCar()
        fake.closuresState.sentryModeState.type = .armed(CarServer_Void())
        fake.closuresState.sentryModeAvailable = true
        let model = model(for: fake)
        await model.refresh()
        #expect(model.hasSentry)
        #expect(model.command(for: .sentry) == .setSentryMode(false))
        #expect(HomeText.sentryState(.armed) == "Armed")

        fake.closuresState.sentryModeState.type = .off(CarServer_Void())
        await model.perform(.sentry)
        #expect(fake.commands.contains { if case .vehicleControlSetSentryModeAction? = $0.carServer?.vehicleAction.vehicleActionMsg { true } else { false } })
        #expect(model.sentry?.state == .off)
        #expect(model.command(for: .sentry) == .setSentryMode(true))
        #expect(model.banner?.message == "Sentry off")
    }

    @Test func sentryAlarmIsTimedFromTheFirstReadShowingIt() async {
        let fake = Self.fakeCar()
        fake.closuresState.sentryModeState.type = .panic(CarServer_Void())
        let model = model(for: fake)
        await model.refresh()
        #expect(model.isAlarmed)
        #expect(model.alarmSince != nil)
        #expect(HomeText.sentryState(.aware) == "Alarm triggered")
        #expect(model.command(for: .sentry) == .setSentryMode(false))
    }

    @Test func carWithoutSentryHasNoRow() async {
        let fake = Self.fakeCar()
        fake.closuresState.sentryModeAvailable = false
        let model = model(for: fake)
        await model.refresh()
        #expect(!model.hasSentry)
    }

    @Test func noPowerIsAStatusWithItsOwnWords() async {
        let fake = Self.fakeCar()
        fake.chargeState.chargingState.noPower = CarServer_Void()
        fake.chargeState.chargeCurrentRequest = 16
        fake.chargeState.chargeCurrentRequestMax = 32
        let model = model(for: fake)
        await model.refresh()
        #expect(model.charge?.phase == .noPower)
        #expect(model.charge?.currentRequestMax == 32)
        #expect(ChargePortText.state(model.charge) == "Charger isn't supplying power")
        #expect(ChargePortText.action(model.charge) == "Details")
        #expect(model.command(for: .chargePort) == nil)
        #expect(model.banner == nil)

        fake.chargeState.chargeCurrentRequest = 20
        await model.send(.setChargingAmps(20), for: .chargePort)
        #expect(fake.commands.contains { $0.carServer?.vehicleAction.setChargingAmpsAction.chargingAmps == 20 })
        #expect(model.charge?.currentRequest == 20)
    }

    @Test func timeToANewLimitIsPendingUntilTheCarSaysAgain() {
        var charge = ChargeReading(batteryLevel: 60, rangeMiles: 180, isCharging: true, chargingState: .charging,
                                   chargeLimit: 80, minutesToLimit: 100, readAt: .now)
        #expect(ChargeText.timeToLimit(charge, limit: 80) == "1 h 40")
        #expect(ChargeText.timeToLimit(charge, limit: 90) == "…")
        charge.apply(.setChargeLimit(percent: 90))
        #expect(ChargeText.timeToLimit(charge, limit: charge.chargeLimit) == "…")
        // The car takes the new limit but still reports its old time: still pending.
        var stale = ChargeReading(batteryLevel: 60, rangeMiles: 180, isCharging: true, chargingState: .charging,
                                  chargeLimit: 90, minutesToLimit: 100, readAt: .now)
        stale.keepTimePending(from: charge)
        #expect(ChargeText.timeToLimit(stale, limit: 90) == "…")
        // Once its time moves, the car's own figure shows.
        var fresh = ChargeReading(batteryLevel: 60, rangeMiles: 180, isCharging: true, chargingState: .charging,
                                  chargeLimit: 90, minutesToLimit: 140, readAt: .now)
        fresh.keepTimePending(from: stale)
        #expect(ChargeText.timeToLimit(fresh, limit: 90) == "2 h 20")
    }

    @Test("phase", arguments: [
        (ChargeSnapshot.ChargingState.disconnected, ChargeReading.Phase.idle),
        (.complete, .idle), (.noPower, .noPower), (.stopped, .plugged), (.starting, .charging), (.charging, .charging),
    ])
    func phase(state: ChargeSnapshot.ChargingState, expected: ChargeReading.Phase) {
        let reading = ChargeReading(batteryLevel: 50, rangeMiles: 150, isCharging: state == .charging,
                                    chargingState: state, readAt: .now)
        #expect(reading.phase == expected)
    }

    @Test func chargingWords() {
        let london = TimeZone(identifier: "Europe/London")!
        let uk = Locale(identifier: "en_GB")
        let start = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: london,
                                   year: 2026, month: 10, day: 21, hour: 0, minute: 30).date!
        let waiting = ChargeReading(batteryLevel: 82, rangeMiles: 254, isCharging: false, chargingState: .stopped,
                                    isScheduled: true, scheduledStart: start, readAt: .now)
        #expect(ChargePortText.state(waiting, locale: uk, timeZone: london) == "Plugged in · Starts at 00:30")
        #expect(ChargeText.duration(minutes: 40) == "40 min")
        #expect(ChargeText.duration(minutes: 80) == "1 h 20")
        #expect(ChargeText.duration(minutes: 120) == "2 h")

        var home = ChargeReading(batteryLevel: 62, rangeMiles: 191, isCharging: true, chargingState: .charging,
                                 isFastCharger: false, energyAddedKWh: 14.2, milesAdded: 52,
                                 chargerAmps: 32, chargerVolts: 230, readAt: .now)
        #expect(ChargeText.added(home) == "14.2 kWh")
        #expect(ChargeText.charger(home) == "32 A · 230 V")
        home.isFastCharger = true
        #expect(ChargeText.added(home) == "+52 mi")
        #expect(ChargeText.charger(home) == "Supercharger")
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

    @Test func shiftingIntoDriveWhileOpenShowsDriving() async throws {
        let fake = Self.fakeCar()
        fake.driveState.shiftState.p = CarServer_Void()
        let model = HomeModel(store: ChargeStore(defaults: defaults), drivingRefresh: .milliseconds(10),
                              parkedRefresh: .milliseconds(10)) { _ in
            VehicleService(vin: TestVectors.vin, key: TestVectors.clientKey, connect: { _ in fake.reconnected() })
        }
        await model.refresh()
        #expect(!model.isDriving)

        fake.driveState.shiftState.d = CarServer_Void()
        fake.driveState.speedFloat = 12
        try await Self.waitUntil { model.isDriving && model.drive?.speedMph == 12 }

        fake.driveState.speedFloat = 20
        try await Self.waitUntil { model.drive?.speedMph == 20 }
        model.stop()
    }

    @Test func pullToRefreshWhileParkedReadsTheCarAgain() async throws {
        let fake = Self.fakeCar()
        fake.driveState.shiftState.p = CarServer_Void()
        let model = HomeModel(store: ChargeStore(defaults: defaults), parkedRefresh: .milliseconds(10)) { _ in
            VehicleService(vin: TestVectors.vin, key: TestVectors.clientKey, connect: { _ in fake.reconnected() })
        }
        await model.refresh()
        fake.chargeState.batteryLevel = 55
        await model.refresh()
        #expect(model.charge?.batteryLevel == 55)
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
