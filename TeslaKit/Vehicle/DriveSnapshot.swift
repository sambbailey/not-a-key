import Foundation

/// Gear, speed, power and the active nav route, as infotainment reports them.
public struct DriveSnapshot: Codable, Sendable, Equatable {
    public enum Gear: String, Codable, Sendable {
        case park, reverse, neutral, drive, unknown
    }

    /// The route set on the car's own navigation.
    public struct Route: Codable, Sendable, Equatable {
        public var destination: String
        public var minutesToArrival: Double?
        public var milesToArrival: Double?
        public var trafficDelayMinutes: Double?
        /// The battery percentage the car expects to arrive with.
        public var batteryAtArrival: Double?

        public init(destination: String, minutesToArrival: Double? = nil, milesToArrival: Double? = nil,
                    trafficDelayMinutes: Double? = nil, batteryAtArrival: Double? = nil) {
            self.destination = destination
            self.minutesToArrival = minutesToArrival
            self.milesToArrival = milesToArrival
            self.trafficDelayMinutes = trafficDelayMinutes
            self.batteryAtArrival = batteryAtArrival
        }
    }

    public var gear: Gear
    public var speedMph: Double?
    /// Power from the battery in kW: positive while driving, negative while regenerating.
    public var powerKW: Int?
    public var odometerMiles: Double?
    public var route: Route?

    public init(gear: Gear, speedMph: Double? = nil, powerKW: Int? = nil, odometerMiles: Double? = nil,
                route: Route? = nil) {
        self.gear = gear
        self.speedMph = speedMph
        self.powerKW = powerKW
        self.odometerMiles = odometerMiles
        self.route = route
    }

    /// In Drive or Reverse, when the doors, boot, frunk and charge port are left alone.
    public var isDriving: Bool { gear == .drive || gear == .reverse }
}

extension DriveSnapshot {
    init(_ state: CarServer_DriveState) {
        gear = switch state.shiftState.type {
        case .p?: .park
        case .r?: .reverse
        case .n?: .neutral
        case .d?: .drive
        default: .unknown
        }
        if case .speedFloat(let speed)? = state.optionalSpeedFloat {
            speedMph = Double(speed)
        } else if case .speed(let speed)? = state.optionalSpeed {
            speedMph = Double(speed)
        }
        if case .power(let power)? = state.optionalPower { powerKW = Int(power) }
        if case .odometerInHundredthsOfAMile(let odometer)? = state.optionalOdometerInHundredthsOfAMile {
            odometerMiles = Double(odometer) / 100
        }
        if case .activeRouteDestination(let destination)? = state.optionalActiveRouteDestination, !destination.isEmpty {
            var route = Route(destination: destination)
            if case .activeRouteMinutesToArrival(let minutes)? = state.optionalActiveRouteMinutesToArrival {
                route.minutesToArrival = Double(minutes)
            }
            if case .activeRouteMilesToArrival(let miles)? = state.optionalActiveRouteMilesToArrival {
                route.milesToArrival = Double(miles)
            }
            if case .activeRouteTrafficMinutesDelay(let delay)? = state.optionalActiveRouteTrafficMinutesDelay {
                route.trafficDelayMinutes = Double(delay)
            }
            if case .activeRouteEnergyAtArrival(let energy)? = state.optionalActiveRouteEnergyAtArrival {
                route.batteryAtArrival = Double(energy)
            }
            self.route = route
        }
    }
}
