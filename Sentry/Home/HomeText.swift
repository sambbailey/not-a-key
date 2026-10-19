import Foundation
import TeslaKit

/// The words on the home screen for the car's state.
enum HomeText {
    /// How long ago `date` was, shortly: "just now", "2 min ago", "3 h ago", "2 d ago".
    static func age(of date: Date, now: Date = .now) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60)) min ago"
        case ..<86_400: return "\(Int(seconds / 3600)) h ago"
        default: return "\(Int(seconds / 86_400)) d ago"
        }
    }

    static func state(of closure: BodyReading.Closure) -> String {
        switch closure {
        case .closed: "Closed"
        case .open: "Open"
        case .ajar: "Not fully closed"
        case .opening: "Opening…"
        case .closing: "Closing…"
        case .unknown: "Unknown"
        }
    }

    /// The label on the boot's button for what a tap will do.
    static func bootAction(_ boot: BodyReading.Closure?) -> String {
        switch boot {
        case .closed: "Open"
        case .open, .ajar: "Close"
        case .opening, .closing: "Stop"
        case .unknown, nil: "Move"
        }
    }

    /// The line under the battery bar, e.g. "Charging · Locked · Updated 2 min ago".
    static func statusLine(charge: ChargeReading?, body: BodyReading?, isReading: Bool, now: Date = .now) -> String {
        var parts: [String] = []
        if charge?.isCharging == true { parts.append("Charging") }
        if let body { parts.append(body.isLocked ? "Locked" : "Unlocked") }
        if let readAt = [charge?.readAt, body?.readAt].compactMap({ $0 }).max() {
            parts.append("Updated \(age(of: readAt, now: now))")
        } else if isReading {
            parts.append("Reading the car…")
        }
        return parts.joined(separator: " · ")
    }

    /// The line under the battery bar while the car is out of range, e.g. "Last seen 3 h ago · Locked".
    static func awayLine(charge: ChargeReading?, body: BodyReading?, now: Date = .now) -> String {
        var parts: [String] = []
        if let readAt = [charge?.readAt, body?.readAt].compactMap({ $0 }).max() {
            parts.append("Last seen \(age(of: readAt, now: now))")
        }
        if let body { parts.append(body.isLocked ? "Locked" : "Unlocked") }
        return parts.isEmpty ? "Not read yet" : parts.joined(separator: " · ")
    }
}

/// The words for cabin climate. Temperatures are shown in Celsius, as the car reports them.
enum ClimateText {
    /// "21°", or "21.5°" for a half degree.
    static func degrees(_ celsius: Double) -> String {
        let tenths = (celsius * 10).rounded() / 10
        return tenths == tenths.rounded()
            ? "\(Int(tenths))°"
            : "\(tenths.formatted(.number.precision(.fractionLength(1))))°"
    }

    /// The name of a parked-climate mode, e.g. "Dog mode"; nil for off.
    static func name(of mode: ClimateKeeperMode) -> String? {
        switch mode {
        case .off: nil
        case .keep: "Keep on"
        case .dog: "Dog mode"
        case .camp: "Camp mode"
        }
    }

    /// What the selected parked-climate mode does, for the line under the choice.
    static func hint(for mode: ClimateKeeperMode) -> String {
        switch mode {
        case .off: "Climate turns off when you leave the car."
        case .keep: "Holds the cabin temperature after you leave. Stops below 20%."
        case .dog: "The car's screen shows the cabin temperature so passers-by know your pet is fine. Stops below 20%."
        case .camp: "Keeps climate, power and the screen on while you stay in the car. Stops below 20%."
        }
    }

    /// The climate row's state, e.g. "Off · Inside 18°", or "Dog mode · 21°" while a mode runs.
    static func summary(_ climate: ClimateSnapshot) -> String {
        if let mode = name(of: climate.keeperMode), climate.isOn {
            let celsius = climate.setCelsius ?? climate.insideCelsius
            return ([mode] + [celsius.map { degrees($0) }].compactMap { $0 }).joined(separator: " · ")
        }
        var parts = [climate.isOn ? "On" : "Off"]
        if let inside = climate.insideCelsius {
            parts.append("Inside \(degrees(inside.rounded()))")
        }
        return parts.joined(separator: " · ")
    }
}

/// The words for the charge port row.
enum ChargePortText {
    /// "Charging · 7 kW", "Open" or "Closed"; nil before the first reading.
    static func state(_ charge: ChargeReading?) -> String? {
        guard let charge else { return nil }
        if charge.isCharging {
            return charge.chargerPowerKW.map { "Charging · \($0) kW" } ?? "Charging"
        }
        return switch charge.isPortOpen {
        case true?: "Open"
        case false?: "Closed"
        case nil: nil
        }
    }

    static func action(_ charge: ChargeReading?) -> String {
        if charge?.isCharging == true { return "Stop" }
        return charge?.isPortOpen == true ? "Close" : "Open"
    }
}

/// The words for the driving screen.
enum DriveText {
    /// "+18 kW" while drawing power, "−12 kW" while regenerating.
    static func power(_ kW: Int) -> String {
        kW < 0 ? "\u{2212}\(-kW) kW" : "+\(kW) kW"
    }

    /// "12,481 mi".
    static func miles(_ miles: Double, fractionDigits: Int = 0) -> String {
        "\(miles.formatted(.number.precision(.fractionLength(fractionDigits)))) mi"
    }

    /// "18 min", or "1 h 5 min".
    static func minutes(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        return total < 60 ? "\(total) min" : "\(total / 60) h \(total % 60) min"
    }
}
