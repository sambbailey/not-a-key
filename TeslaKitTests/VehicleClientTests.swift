import Foundation
import Testing
@testable import TeslaKit

/// Intervals scaled down from the production defaults (1 s busy retry, 3 s / 1 s deadlines)
/// so the suite never sleeps for real seconds; the ratios between them are kept.
private let retryInterval = Duration.milliseconds(50)

private func makeClient(_ car: FakeVehicle) -> VehicleClient {
    VehicleClient(vin: TestVectors.vin, key: TestVectors.clientKey, transport: car,
                  busyRetryInterval: retryInterval)
}

@Suite struct VehicleClientTests {
    @Test func executesMoveTrunk() async throws {
        let car = FakeVehicle()
        try await makeClient(car).execute(.moveTrunk)

        #expect(car.sessionInfoRequests == [.vehicleSecurity])
        #expect(car.commands.count == 1)
        #expect(car.commands.first?.vcsec?.closureMoveRequest.rearTrunk == .closureMoveTypeMove)
    }

    @Test func executesInfotainmentCommand() async throws {
        let car = FakeVehicle()
        try await makeClient(car).execute(.climateOn)

        #expect(car.sessionInfoRequests == [.infotainment])
        #expect(car.commands.first?.carServer?.vehicleAction.hvacAutoAction.powerOn == true)
    }

    @Test func reusesSessionAcrossCommands() async throws {
        let car = FakeVehicle()
        let client = makeClient(car)
        try await client.execute(.lock)
        try await client.execute(.unlock)

        #expect(car.sessionInfoRequests == [.vehicleSecurity])
        #expect(car.commands.map(\.counter) == [1, 2])
    }

    @Test func readsBodyControllerStateWithoutHandshake() async throws {
        let car = FakeVehicle()
        var status = VCSEC_VehicleStatus()
        status.vehicleLockState = .vehiclelockstateLocked
        status.closureStatuses.rearTrunk = .closurestateOpen
        status.closureStatuses.frontTrunk = .closurestateClosed
        status.vehicleSleepStatus = .vehicleSleepStatusAwake
        car.bodyStatus = status

        let snapshot = try await makeClient(car).bodyControllerState()

        #expect(car.sessionInfoRequests.isEmpty)
        #expect(car.statusRequests == 1)
        #expect(snapshot == VehicleSnapshot(status))
        #expect(snapshot == VehicleSnapshot(isLocked: true, rearTrunk: .open, frontTrunk: .closed, isAsleep: false))
    }

    @Test func retriesWhileBusy() async throws {
        let car = FakeVehicle(script: .busy(times: 2))
        try await makeClient(car).execute(.moveTrunk)

        let counters = car.commands.map(\.counter)
        #expect(counters.count == 3)
        #expect(zip(counters, counters.dropFirst()).allSatisfy { $0 < $1 })
        #expect(car.sessionInfoRequests == [.vehicleSecurity])
    }

    @Test func busyPastDeadlineThrowsBusy() async throws {
        let car = FakeVehicle(script: .busy(times: 100))
        let client = makeClient(car)
        let started = ContinuousClock.now

        await #expect(throws: VehicleError.busy) {
            try await client.execute(.moveTrunk, deadline: retryInterval * 3)
        }
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(car.busyRepliesSent >= 2)
        #expect(car.busyRepliesSent <= 3)
    }

    @Test func resyncsOnceOnStaleSession() async throws {
        let car = FakeVehicle(script: .staleSessionOnce)
        try await makeClient(car).execute(.moveTrunk)

        #expect(car.staleFaultsSent == 1)
        #expect(car.commands.count == 1)
        #expect(car.sessionInfoRequests == [.vehicleSecurity])
    }

    @Test func unknownKeyThrowsNotPaired() async throws {
        let car = FakeVehicle(script: .unknownKey)
        await #expect(throws: VehicleError.notPaired) {
            try await makeClient(car).execute(.moveTrunk)
        }
        #expect(car.commands.isEmpty)
    }

    @Test func nominalErrorThrowsRejected() async throws {
        let car = FakeVehicle(script: .nominalError)
        await #expect {
            try await makeClient(car).execute(.moveTrunk)
        } throws: { error in
            if case VehicleError.rejected = error { return true }
            return false
        }
        #expect(car.commands.count == 1)
    }

    @Test func silentCarTimesOut() async throws {
        let deadline = Duration.milliseconds(200)
        var started = ContinuousClock.now
        await #expect(throws: VehicleError.timeout) {
            try await makeClient(FakeVehicle(script: .silent)).execute(.moveTrunk, deadline: deadline)
        }
        #expect(ContinuousClock.now - started >= deadline)

        started = ContinuousClock.now
        await #expect(throws: VehicleError.timeout) {
            try await makeClient(FakeVehicle(script: .silent)).bodyControllerState(deadline: deadline)
        }
        #expect(ContinuousClock.now - started >= deadline)
    }

    @Test func ignoresForeignRoutingAddress() async throws {
        let car = FakeVehicle()
        var status = VCSEC_VehicleStatus()
        status.vehicleLockState = .vehiclelockstateLocked
        status.closureStatuses.rearTrunk = .closurestateClosed
        car.bodyStatus = status
        car.injectForeignReplyBeforeNext()

        let snapshot = try await makeClient(car).bodyControllerState()

        #expect(snapshot == VehicleSnapshot(status))
    }

    @Test func oneRequestInFlightAtATime() async throws {
        let car = FakeVehicle(replyDelay: .milliseconds(20))
        let client = makeClient(car)
        async let lock: Void = client.execute(.lock)
        async let state = client.bodyControllerState()
        async let unlock: Void = client.execute(.unlock)
        _ = try await (lock, state, unlock)

        #expect(car.overlappingRequests == 0)
        #expect(car.commands.count == 2)
    }

    @Test func sendAddKeyRequestSendsRawEnvelope() async throws {
        let car = FakeVehicle(script: .silent)
        let newKey = TestVectors.clientKey.publicKeyX963
        try await makeClient(car).sendAddKeyRequest(publicKeyX963: newKey)

        #expect(car.addKeyRequests.count == 1)
        let operation = try VCSEC_UnsignedMessage(
            serializedBytes: car.addKeyRequests[0].signedMessage.protobufMessageAsBytes).whitelistOperation
        #expect(operation.addKeyToWhitelistAndAddPermissions.key.publicKeyRaw == newKey)
    }

    @Test func waitForPairingSucceedsAfterApproval() async throws {
        let car = FakeVehicle(script: .pairAfter(polls: 3))
        let client = makeClient(car)
        try await client.waitForPairing(timeout: .seconds(5), pollEvery: .milliseconds(10))

        #expect(car.sessionInfoRequests == Array(repeating: .infotainment, count: 4))
        // The handshake that proved pairing is reused for the next infotainment command.
        try await client.execute(.climateOff)
        #expect(car.sessionInfoRequests.count == 4)
    }

    @Test func waitForPairingTimesOut() async throws {
        let car = FakeVehicle(script: .pairAfter(polls: 1_000))
        await #expect(throws: VehicleError.timeout) {
            try await makeClient(car).waitForPairing(timeout: .milliseconds(100), pollEvery: .milliseconds(10))
        }
    }
}
