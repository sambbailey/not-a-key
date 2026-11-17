import LocalAuthentication
import os

private let log = Logger(subsystem: "com.nevelen.notakey", category: "auth")

/// Asks whoever holds the phone to prove they're its owner, with Face ID or else the passcode.
enum OwnerCheck {
    /// Whether the owner confirmed. False if they cancelled, or the phone has no passcode set.
    @MainActor
    static func confirm(_ reason: String) async -> Bool {
        do {
            return try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            log.info("Owner check not passed: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
