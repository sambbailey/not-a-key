import Foundation

/// What climate does once the car is parked. Keep holds the cabin; Dog also shows the cabin
/// temperature on the car's screen; Camp keeps power, climate and the screen on for sleeping in the car.
public enum ClimateKeeperMode: String, Codable, Sendable, CaseIterable {
    case off, keep, dog, camp
}

/// Cabin climate as infotainment reports it. Temperatures are in Celsius; nil when not reported.
public struct ClimateSnapshot: Codable, Sendable, Equatable {
    public var isOn: Bool
    public var insideCelsius: Double?
    public var outsideCelsius: Double?
    /// The temperature the driver's side is set to.
    public var setCelsius: Double?
    public var isDefrosting: Bool
    /// What climate does once the car is parked.
    public var keeperMode: ClimateKeeperMode

    public init(isOn: Bool, insideCelsius: Double? = nil, outsideCelsius: Double? = nil, setCelsius: Double? = nil,
                isDefrosting: Bool = false, keeperMode: ClimateKeeperMode = .off) {
        self.isOn = isOn
        self.insideCelsius = insideCelsius
        self.outsideCelsius = outsideCelsius
        self.setCelsius = setCelsius
        self.isDefrosting = isDefrosting
        self.keeperMode = keeperMode
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
        keeperMode = switch state.climateKeeperMode.type {
        case .on?: .keep
        case .dog?: .dog
        // The car reports Camp mode as "Party".
        case .party?: .camp
        default: .off
        }
    }

    /// The car sends Floats; rounding to tenths drops their binary noise (21.5, not 21.499999).
    private static func tenths(_ value: Float) -> Double {
        (Double(value) * 10).rounded() / 10
    }
}
