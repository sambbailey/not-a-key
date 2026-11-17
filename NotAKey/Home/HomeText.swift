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

    /// How long ago `date` was, shortest: "Now", "2 min", "3 h", "2 d".
    static func shortAge(of date: Date, now: Date = .now) -> String {
        let age = age(of: date, now: now)
        return age == "just now" ? "Now" : String(age.dropLast(" ago".count))
    }

    /// The Sentry row's state: "Armed", "Off" or "Alarm triggered".
    static func sentryState(_ sentry: SentrySnapshot.State) -> String {
        if sentry.isAlarm { return "Alarm triggered" }
        return sentry.isArmed ? "Armed" : "Off"
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

    /// The line under the battery bar, e.g. "Charging · Updated 2 min ago". The lock state is
    /// left to the Doors row.
    static func statusLine(charge: ChargeReading?, body: BodyReading?, isReading: Bool, now: Date = .now) -> String {
        var parts: [String] = []
        if charge?.isCharging == true {
            parts.append("Charging")
        } else if charge != nil || body != nil {
            parts.append("Parked")
        }
        if let readAt = [charge?.readAt, body?.readAt].compactMap({ $0 }).max() {
            parts.append("Updated \(age(of: readAt, now: now))")
        } else if isReading {
            parts.append("Reading the car…")
        }
        return parts.joined(separator: " · ")
    }

    /// The line under the battery bar while the car is out of range, e.g. "Last seen 3 h ago · Locked".
    static func awayLine(charge: ChargeReading?, body: BodyReading?, sentry: SentrySnapshot? = nil,
                         now: Date = .now) -> String {
        var parts: [String] = []
        if let readAt = [charge?.readAt, body?.readAt].compactMap({ $0 }).max() {
            parts.append("Last seen \(age(of: readAt, now: now))")
        }
        if let body { parts.append(body.isLocked ? "Locked" : "Unlocked") }
        if sentry?.state?.isArmed == true, sentry?.isAvailable != false { parts.append("Sentry armed") }
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
    /// "Plugged in · 7 kW", "Plugged in · Starts at 00:30", "Open" or "Closed"; nil before the
    /// first reading.
    static func state(_ charge: ChargeReading?, locale: Locale = .current, timeZone: TimeZone = .current) -> String? {
        guard let charge else { return nil }
        switch charge.phase {
        case .charging:
            return (["Plugged in"] + [charge.chargerPowerKW.map(ChargeText.power)].compactMap { $0 })
                .joined(separator: " · ")
        case .noPower:
            return "Charger isn't supplying power"
        case .plugged:
            if charge.isWaitingForSchedule, let start = charge.scheduledStart {
                return "Plugged in · Starts at \(ChargeText.time(start, locale: locale, timeZone: timeZone))"
            }
            return "Plugged in · Not charging"
        case .idle:
            return switch charge.isPortOpen {
            case true?: "Open"
            case false?: "Closed"
            case nil: nil
            }
        }
    }

    static func action(_ charge: ChargeReading?) -> String {
        switch charge?.phase {
        case .charging?, .noPower?: "Details"
        case .plugged?: "Charge now"
        case .idle?, nil: charge?.isPortOpen == true ? "Close" : "Open"
        }
    }
}

/// The words for charging, on the home screen and the charging screen.
enum ChargeText {
    /// "40 min", or "1 h 20" and "2 h" from an hour on.
    static func duration(minutes: Int) -> String {
        guard minutes >= 60 else { return "\(max(0, minutes)) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60)"
    }

    /// "00:30", or "12:30 AM" where the clock is 12-hour.
    static func time(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        date.formatted(Date.FormatStyle(locale: locale, timeZone: timeZone)
            .hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits))
    }

    static func power(_ kW: Int) -> String { "\(kW) kW" }

    /// "28 mi/h".
    static func rate(_ mph: Int) -> String { "\(mph) mi/h" }

    /// What this session has added: "+62 mi" at a Supercharger, "14.2 kWh" elsewhere, falling
    /// back to whichever the car reported.
    static func added(_ charge: ChargeReading) -> String? {
        let energy = charge.energyAddedKWh.map { "\($0.formatted(.number.precision(.fractionLength(1)))) kWh" }
        let miles = charge.milesAdded.map { "+\(Int($0.rounded())) mi" }
        return charge.isFastCharger == true ? miles ?? energy : energy ?? miles
    }

    /// "32 A · 230 V", or "Supercharger" on a fast charger.
    static func charger(_ charge: ChargeReading) -> String? {
        if charge.isFastCharger == true { return "Supercharger" }
        let parts = [charge.chargerAmps.map { "\($0) A" }, charge.chargerVolts.map { "\($0) V" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "40 min" to `limit`, "…" while the car works out its time to a changed limit, or "–".
    static func timeToLimit(_ charge: ChargeReading?, limit: Int?) -> String {
        guard let charge else { return "–" }
        if charge.isTimePending(toLimit: limit) { return "…" }
        return charge.minutesToLimit.map { duration(minutes: $0) } ?? "–"
    }

    /// "16 A".
    static func amps(_ amps: Int) -> String { "\(amps) A" }

    /// "Limit 90%".
    static func limit(_ percent: Int) -> String { "Limit \(percent)%" }
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
