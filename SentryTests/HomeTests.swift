import Foundation
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
            VehicleService(vin: TestVectors.vin, key: TestVectors.clientKey, connect: { _ in fake })
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
