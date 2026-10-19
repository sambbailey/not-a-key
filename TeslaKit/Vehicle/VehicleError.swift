import Foundation

public enum VehicleError: Error, Equatable, Sendable {
    case bluetoothOff, bluetoothUnauthorized, notInRange, notPaired, busy, timeout
    case rejected(String)
    case protocolFault(UniversalMessage_MessageFault_E)

    /// Maps a signed-message fault reported by the vehicle to the error users act on.
    public static func from(fault: UniversalMessage_MessageFault_E) -> VehicleError {
        switch fault {
        case .rrorUnknownKeyID, .rrorInactiveKey: .notPaired
        case .rrorBusy: .busy
        default: .protocolFault(fault)
        }
    }
}
