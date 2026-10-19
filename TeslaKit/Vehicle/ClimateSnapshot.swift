import Foundation

/// Cabin climate as infotainment reports it. Temperatures are in Celsius; nil when not reported.
public struct ClimateSnapshot: Sendable, Equatable {
    public var isOn: Bool
    public var insideCelsius: Double?
    public var outsideCelsius: Double?
    /// The temperature the driver's side is set to.
    public var setCelsius: Double?
    public var isDefrosting: Bool
    /// Whether "Keep" climate mode holds the cabin while parked.
    public var keepsOn: Bool

    public init(isOn: Bool, insideCelsius: Double? = nil, outsideCelsius: Double? = nil, setCelsius: Double? = nil,
                isDefrosting: Bool = false, keepsOn: Bool = false) {
        self.isOn = isOn
        self.insideCelsius = insideCelsius
        self.outsideCelsius = outsideCelsius
        self.setCelsius = setCelsius
        self.isDefrosting = isDefrosting
        self.keepsOn = keepsOn
    }
}

extension ClimateSnapshot {
    init(_ state: CarServer_ClimateState) {
        isOn = state.isClimateOn
        insideCelsius = state.optionalInsideTempCelsius.map { _ in Self.tenths(state.insideTempCelsius) }
        outsideCelsius = state.optionalOutsideTempCelsius.map { _ in Self.tenths(state.outsideTempCelsius) }
        setCelsius = state.optionalDriverTempSetting.map { _ in Self.tenths(state.driverTempSetting) }
        if state.hasDefrostMode {
            switch state.defrostMode.type {
            case .normal?, .max?: isDefrosting = true
            default: isDefrosting = false
            }
        } else {
            isDefrosting = state.isFrontDefrosterOn
        }
        if case .on? = state.climateKeeperMode.type {
            keepsOn = true
        } else {
            keepsOn = false
        }
    }

    /// The car sends Floats; rounding to tenths drops their binary noise (21.5, not 21.499999).
    private static func tenths(_ value: Float) -> Double {
        (Double(value) * 10).rounded() / 10
    }
}
