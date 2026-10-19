import Foundation
import TeslaKit

/// The words Sentry shows for the result of a car command, in the intent banner and in the app.
enum IntentMessages {
    static let setUpFirst = "Set up Not a Key first"

    static func success(_ outcome: BootToggleOutcome) -> String {
        switch outcome {
        case .opening: "Opening boot"
        case .closing: "Closing boot"
        case .moving: "Moving boot"
        }
    }

    /// The banner text for a command the car accepted.
    static func success(_ command: VehicleCommand) -> String {
        switch command {
        case .moveTrunk: "Moving boot"
        case .openFrunk: "Opening frunk"
        case .lock: "Locked"
        case .unlock: "Unlocked"
        case .wake: "Car awake"
        case .climateOn: "Climate on"
        case .climateOff: "Climate off"
        case .setTemperature(let celsius): "Set to \(ClimateText.degrees(celsius))"
        case .setDefrost(let on): on ? "Defrosting" : "Defrost off"
        case .climateKeeper(let mode): switch mode {
            case .off: "Climate won't stay on"
            case .keep: "Climate stays on while parked"
            case .dog: "Dog mode on"
            case .camp: "Camp mode on"
            }
        case .openChargePort: "Opening charge port"
        case .closeChargePort: "Closing charge port"
        case .stopCharging: "Charging stopped"
        }
    }

    /// Anything the owner can't act on, including a cancelled or timed-out request, reads as
    /// the car not responding.
    static func failure(_ error: any Error) -> String {
        switch error {
        case VehicleError.bluetoothOff: "Bluetooth is off"
        case VehicleError.bluetoothUnauthorized: "Allow Bluetooth for Not a Key in Settings"
        case VehicleError.notInRange: "Car not in range"
        case VehicleError.notPaired: "Key not paired"
        case VehicleError.busy: "Car busy, try again"
        case is KeyStore.Failure: setUpFirst
        default: "Car didn't respond"
        }
    }
}
