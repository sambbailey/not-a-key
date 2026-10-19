import Foundation
import Testing
@testable import TeslaKit

/// Scaled down from the production 1 s poll, as in `VehicleClientTests`.
private let pollInterval = Duration.milliseconds(50)

private func makeClient(_ car: FakeVehicle) -> VehicleClient {
    VehicleClient(vin: TestVectors.vin, key: TestVectors.clientKey, transport: car,
                  busyRetryInterval: pollInterval)
}

private func chargeState(level: Int32, range: Float, charging: Bool = false) -> CarServer_ChargeState {
    var state = CarServer_ChargeState()
    state.batteryLevel = level
    state.batteryRange = range
    state.chargingState.type = charging ? .charging(CarServer_Void()) : .disconnected(CarServer_Void())
    return state
}

@Suite struct ChargeStateTests {
    @Test func readsChargeStateFromEncryptedReply() async throws {
        let car = FakeVehicle()
        car.chargeState = chargeState(level: 78, range: 245.4)

        let snapshot = try await makeClient(car).chargeState()

        #expect(snapshot == ChargeSnapshot(batteryLevel: 78, rangeMiles: 245.4, isCharging: false))
        #expect(car.sessionInfoRequests == [.infotainment])
        #expect(car.commands.first?.carServer?.vehicleAction.getVehicleData.hasGetChargeState == true)
        #expect(car.encryptedRepliesSent == 1)
    }

    @Test func reportsCharging() async throws {
        let car = FakeVehicle()
        car.chargeState = chargeState(level: 50, range: 150, charging: true)

        #expect(try await makeClient(car).chargeState().isCharging)
    }

    @Test func rejectsNonOKActionStatus() async {
        let car = FakeVehicle(script: .rejectsAction(reason: "vehicle_asleep"))

        await #expect(throws: VehicleError.rejected("vehicle_asleep")) {
            try await makeClient(car).chargeState()
        }
    }

    @Test func missingBatteryLevelIsADecodingFault() async {
        let car = FakeVehicle()
        car.chargeState.batteryRange = 100

        await #expect(throws: VehicleError.protocolFault(.rrorDecoding)) {
            try await makeClient(car).chargeState()
        }
    }

    @Test func resyncsOnceOnStaleSession() async throws {
        let car = FakeVehicle(script: .staleSessionOnce)
        car.chargeState = chargeState(level: 78, range: 245.4)

        let snapshot = try await makeClient(car).chargeState()

        #expect(snapshot.batteryLevel == 78)
        #expect(car.staleFaultsSent == 1)
        #expect(car.sessionInfoRequests == [.infotainment])
    }

    @Test func dropsReplyThatFailsToDecrypt() async throws {
        let car = FakeVehicle()
        car.chargeState = chargeState(level: 78, range: 245.4)
        car.injectCorruptReplyBeforeNextCommand()

        #expect(try await makeClient(car).chargeState().batteryLevel == 78)
    }

    @Test func silentCarTimesOut() async {
        let car = FakeVehicle(script: .silent)

        await #expect(throws: VehicleError.timeout) {
            try await makeClient(car).chargeState(deadline: .milliseconds(100))
        }
    }

    // MARK: Waiting for infotainment

    @Test func asleepCarIgnoresInfotainmentHandshake() async {
        let car = FakeVehicle()
        car.isAsleep = true

        await #expect(throws: VehicleError.timeout) {
            try await makeClient(car).chargeState(deadline: .milliseconds(100))
        }
        #expect(car.unansweredWhileAsleep == 1)
    }

    @Test func waitForInfotainmentPollsUntilDeadline() async {
        let car = FakeVehicle()
        car.isAsleep = true
        let started = ContinuousClock.now

        await #expect(throws: VehicleError.timeout) {
            try await makeClient(car).waitForInfotainment(deadline: pollInterval * 6, pollEvery: pollInterval)
        }
        let elapsed = ContinuousClock.now - started
        #expect(elapsed >= pollInterval * 5)
        #expect(elapsed < .seconds(1))
        // About one handshake per poll interval: polling, not a busy loop.
        #expect((4...7).contains(car.unansweredWhileAsleep))
    }

    @Test func waitForInfotainmentReturnsOnceAwake() async throws {
        let car = FakeVehicle()
        car.isAsleep = true
        car.chargeState = chargeState(level: 78, range: 245.4)
        let client = makeClient(car)
        Task {
            try? await Task.sleep(for: pollInterval * 3)
            car.isAsleep = false
        }

        try await client.waitForInfotainment(deadline: .seconds(2), pollEvery: pollInterval)

        #expect(car.unansweredWhileAsleep >= 2)
        #expect(car.sessionInfoRequests == [.infotainment])
        // The session from the wait is reused for the read.
        #expect(try await client.chargeState().batteryLevel == 78)
        #expect(car.sessionInfoRequests == [.infotainment])
    }

    @Test func waitForInfotainmentReturnsAtOnceWithASession() async throws {
        let car = FakeVehicle()
        let client = makeClient(car)
        try await client.execute(.climateOn)
        car.isAsleep = true

        try await client.waitForInfotainment(deadline: .seconds(1), pollEvery: pollInterval)
        #expect(car.unansweredWhileAsleep == 0)
    }

    @Test func waitForInfotainmentReportsNotPaired() async {
        let car = FakeVehicle(script: .unknownKey)

        await #expect(throws: VehicleError.notPaired) {
            try await makeClient(car).waitForInfotainment(deadline: .seconds(1), pollEvery: pollInterval)
        }
    }
}
