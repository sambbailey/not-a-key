import Foundation
import Testing
import TeslaKit
@testable import NotAKey

struct IntentMessagesTests {
    @Test("successCopy", arguments: [
        (BootToggleOutcome.opening, "Opening boot"),
        (.closing, "Closing boot"),
        (.moving, "Moving boot"),
    ])
    func successCopy(outcome: BootToggleOutcome, expected: String) {
        #expect(IntentMessages.success(outcome) == expected)
    }

    @Test("messageForEveryError", arguments: [
        (VehicleError.bluetoothOff, "Bluetooth is off"),
        (.bluetoothUnauthorized, "Allow Bluetooth for Not a Key in Settings"),
        (.notInRange, "Car not in range"),
        (.notPaired, "Key not paired"),
        (.busy, "Car busy, try again"),
        (.timeout, "Car didn't respond"),
        (.rejected("unknown"), "Car didn't respond"),
        (.protocolFault(.rrorInvalidSignature), "Car didn't respond"),
    ])
    func messageForEveryError(error: VehicleError, expected: String) {
        #expect(IntentMessages.failure(error) == expected)
    }

    @Test func messageForOtherErrors() {
        #expect(IntentMessages.failure(CancellationError()) == "Car didn't respond")
        #expect(IntentMessages.failure(URLError(.unknown)) == "Car didn't respond")
        #expect(IntentMessages.failure(KeyStore.Failure.unreadableItem) == "Set up Not a Key first")
    }

    @Test func keychainErrorsDontAskForSetUp() {
        // The key is locked away until the phone is unlocked once after a restart.
        #expect(IntentMessages.failure(KeyStore.Failure.keychain(errSecInteractionNotAllowed))
            == "Unlock your iPhone once, then try again")
        #expect(IntentMessages.failure(KeyStore.Failure.keychain(errSecNotAvailable))
            == "Couldn't read this phone's car key, try again")
    }
}

struct ToggleBootIntentTests {
    let defaults: UserDefaults
    let keyStore = KeyStore(service: "com.nevelen.notakey.tests.\(UUID().uuidString)")

    init() {
        let suite = "com.nevelen.notakey.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    private func setUp(vin: String? = TestVectors.vin, paired: Bool = true, key: Bool = true) throws {
        defaults.set(vin, forKey: CarStore.vinKey)
        defaults.set(paired, forKey: CarStore.pairedKey)
        if key { _ = try keyStore.loadOrCreate() }
    }

    private func message(deadline: Duration = .seconds(15),
                         connect: @escaping @Sendable (String) async throws -> VehicleTransport)
        async -> String {
        await ToggleBootIntent.message(defaults: defaults, keyStore: keyStore,
                                       deadline: deadline, connect: connect)
    }

    @Test("setUpFirstWhenNotSetUp", arguments: [
        (String?.none, true, true), (TestVectors.vin, false, true), (TestVectors.vin, true, false),
    ])
    func setUpFirstWhenNotSetUp(vin: String?, paired: Bool, key: Bool) async throws {
        defer { try? keyStore.delete() }
        try setUp(vin: vin, paired: paired, key: key)
        let fake = FakeVehicle()

        #expect(await message { _ in fake } == "Set up Not a Key first")
        #expect(fake.requestsReceived == 0)
    }

    @Test func togglesBoot() async throws {
        defer { try? keyStore.delete() }
        try setUp()
        let fake = FakeVehicle()
        fake.bodyStatus.closureStatuses.rearTrunk = .closurestateClosed

        #expect(await message { _ in fake } == "Opening boot")
        #expect(fake.commands.count == 1)
    }

    @Test func reportsVehicleErrors() async throws {
        defer { try? keyStore.delete() }
        try setUp()

        #expect(await message { _ in throw VehicleError.notInRange } == "Car not in range")
    }

    @Test func givesUpAtTheDeadline() async throws {
        defer { try? keyStore.delete() }
        try setUp()
        let clock = ContinuousClock()
        let start = clock.now

        // A connect that ignores cancellation, so only the deadline can end the wait.
        let result = await message(deadline: .milliseconds(100)) { _ in
            await Task.detached { try? await Task.sleep(for: .seconds(3)) }.value
            throw VehicleError.notInRange
        }

        #expect(result == "Car didn't respond")
        #expect(clock.now - start < .seconds(2))
    }
}
