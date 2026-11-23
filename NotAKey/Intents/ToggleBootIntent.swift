import AppIntents
import Foundation
import os
import TeslaKit

private let log = Logger(subsystem: "com.nevelen.notakey", category: "intent")

/// Opens or closes the boot without opening the app. Meant for the Action Button, so it runs
/// while the phone is locked and always answers with a banner rather than an error.
struct ToggleBootIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Boot"
    static let description = IntentDescription("Opens the boot if it's closed, or closes it if it's open.")
    static let openAppWhenRun = false
    static let authenticationPolicy = IntentAuthenticationPolicy.alwaysAllowed

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: await Self.message()))
    }

    /// The banner text for one toggle. Never takes longer than `deadline`, even if the car or
    /// the Bluetooth stack stops responding.
    static func message(defaults: UserDefaults = .standard, keyStore: KeyStore = KeyStore(),
                        deadline: Duration = .seconds(15),
                        demoCar: MockVehicleService? = CarStore.isDemoOn ? .shared : nil,
                        connect: @escaping @Sendable (String) async throws -> VehicleTransport = {
                            try await BLETransport.connect(vin: $0)
                        }) async -> String {
        // In demo mode the simulated car takes the place of the real one.
        if let demoCar {
            return await toggle(demoCar, within: deadline)
        }
        let stored: KeyAgreementKey?
        do {
            stored = try keyStore.load()
        } catch {
            log.error("Toggle boot: key unreadable: \(String(describing: error), privacy: .public)")
            return IntentMessages.failure(error)
        }
        guard let vin = defaults.string(forKey: CarStore.vinKey),
              defaults.bool(forKey: CarStore.pairedKey),
              let key = stored
        else {
            log.error("Toggle boot: not set up")
            return IntentMessages.setUpFirst
        }
        return await toggle(VehicleService(vin: vin, key: key, connect: connect), within: deadline)
    }

    private static func toggle(_ service: any VehicleServing, within deadline: Duration) async -> String {
        let until = ContinuousClock.now + deadline
        do {
            let outcome = try await run(within: deadline) { try await service.toggleBoot(before: until) }
            log.info("Toggle boot succeeded: \(String(describing: outcome), privacy: .private)")
            return IntentMessages.success(outcome)
        } catch {
            log.error("Toggle boot failed: \(String(describing: error), privacy: .public)")
            return IntentMessages.failure(error)
        }
    }

    /// Runs `work`, but returns `VehicleError.timeout` once `limit` passes. The work is
    /// cancelled then, and this returns without waiting for it to notice.
    private static func run<T: Sendable>(within limit: Duration,
                                         _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let pending = OSAllocatedUnfairLock<CheckedContinuation<T, any Error>?>(initialState: nil)
        return try await withCheckedThrowingContinuation { continuation in
            pending.withLock { $0 = continuation }
            @Sendable func finish(_ result: Result<T, any Error>) {
                let waiting = pending.withLock { pending in
                    defer { pending = nil }
                    return pending
                }
                waiting?.resume(with: result)
            }
            let task = Task {
                do { finish(.success(try await work())) } catch { finish(.failure(error)) }
            }
            let timer = Task {
                guard (try? await Task.sleep(for: limit)) != nil else { return }
                task.cancel()
                finish(.failure(VehicleError.timeout))
            }
            Task {
                await task.value
                timer.cancel()
            }
        }
    }
}
