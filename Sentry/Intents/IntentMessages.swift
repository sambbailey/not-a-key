import Foundation
import TeslaKit

/// The words Sentry shows for the result of a car command, in the intent banner and in the app.
enum IntentMessages {
    static let setUpFirst = "Set up Sentry first"

    static func success(_ outcome: BootToggleOutcome) -> String {
        switch outcome {
        case .opening: "Opening boot"
        case .closing: "Closing boot"
        case .moving: "Moving boot"
        }
    }

    /// Anything the owner can't act on, including a cancelled or timed-out request, reads as
    /// the car not responding.
    static func failure(_ error: any Error) -> String {
        switch error {
        case VehicleError.bluetoothOff: "Bluetooth is off"
        case VehicleError.bluetoothUnauthorized: "Allow Bluetooth for Sentry in Settings"
        case VehicleError.notInRange: "Car not in range"
        case VehicleError.notPaired: "Key not paired"
        case VehicleError.busy: "Car busy, try again"
        case is KeyStore.Failure: setUpFirst
        default: "Car didn't respond"
        }
    }
}
