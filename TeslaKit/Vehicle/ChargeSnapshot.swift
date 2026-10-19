import Foundation

/// Battery level, range and whether the car is charging, as infotainment reports them.
public struct ChargeSnapshot: Sendable, Equatable {
    public var batteryLevel: Int
    public var rangeMiles: Double
    public var isCharging: Bool

    public init(batteryLevel: Int, rangeMiles: Double, isCharging: Bool) {
        self.batteryLevel = batteryLevel
        self.rangeMiles = rangeMiles
        self.isCharging = isCharging
    }
}

extension ChargeSnapshot {
    /// Throws `.protocolFault(.rrorDecoding)` if the level or range is missing.
    init(_ state: CarServer_ChargeState) throws {
        guard case .batteryLevel(let level)? = state.optionalBatteryLevel,
              case .batteryRange(let range)? = state.optionalBatteryRange else {
            throw VehicleError.protocolFault(.rrorDecoding)
        }
        batteryLevel = Int(level)
        // The car sends a Float; rounding to hundredths drops its binary noise (245.4, not 245.39999).
        rangeMiles = (Double(range) * 100).rounded() / 100
        if case .charging? = state.chargingState.type {
            isCharging = true
        } else {
            isCharging = false
        }
    }
}
