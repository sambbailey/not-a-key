import SwiftUI
import TeslaKit

/// The top of the home screen while the car is in Drive or Reverse: speed and gear, power,
/// the nav route and the battery.
struct DrivingPanel: View {
    let drive: DriveSnapshot
    let charge: ChargeReading?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            speedAndGear.padding(.top, 32)
            PowerMeter(kW: drive.powerKW).padding(.top, 28)
            route.padding(.top, 28)
            battery.padding(.top, 24)
        }
    }

    private var speedAndGear: some View {
        HStack(alignment: .bottom) {
            (Text(drive.speedMph.map { "\(Int($0.rounded()))" } ?? "–")
                .font(.geist(132, .medium, relativeTo: nil))
                .tracking(-7.9)
             + Text(" mph")
                .font(.geist(32, relativeTo: nil))
                .tracking(-0.3))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.vertical, -14)
                // Live reads land a few times a second; roll the digits rather than jump.
                .contentTransition(.numericText(value: drive.speedMph ?? 0))
                .animation(.snappy, value: drive.speedMph)
                .accessibilityLabel(drive.speedMph.map { "\(Int($0.rounded())) miles per hour" } ?? "Speed not read")
            Spacer()
            GearStrip(gear: drive.gear).padding(.bottom, 4)
        }
    }

    @ViewBuilder
    private var route: some View {
        if let route = drive.route {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Heading to")
                            .font(.geist(13))
                            .foregroundStyle(Paper.secondary)
                        Text(route.destination)
                            .font(.geist(18, .medium))
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(route.minutesToArrival.map(DriveText.minutes) ?? "–")
                            .font(.geist(22, .medium))
                            .tracking(-0.44)
                        if let delay = route.trafficDelayMinutes, delay >= 1 {
                            Text("+\(DriveText.minutes(delay)) traffic")
                                .font(.geist(13))
                                .foregroundStyle(Paper.secondary)
                        }
                    }
                }
                HStack(alignment: .top) {
                    fact("Distance left", route.milesToArrival.map { DriveText.miles($0, fractionDigits: 1) })
                    fact("Battery on arrival", route.batteryAtArrival.map { "\(Int($0.rounded()))%" })
                }
                .padding(.top, 12)
                .overlay(alignment: .top) { Paper.rule.frame(height: 1) }
            }
            .padding(18)
            .background(Paper.card, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .combine)
        } else {
            Text("No route set on the car")
                .font(.geist(13))
                .foregroundStyle(Paper.secondary)
        }
    }

    private func fact(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.geist(13))
                .foregroundStyle(Paper.secondary)
            Text(value ?? "–")
                .font(.geist(16, .medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var battery: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(charge?.levelText ?? "–")
                    .font(.geist(16, .medium))
                Spacer()
                Text(charge.map { "\(Int($0.rangeMiles.rounded())) miles range" } ?? "")
                    .font(.geist(13))
                    .foregroundStyle(Paper.secondary)
            }
            GeometryReader { geometry in
                Capsule().fill(Paper.rule)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Paper.ink)
                            .frame(width: geometry.size.width * CGFloat(charge?.batteryLevel ?? 0) / 100)
                    }
                    .clipShape(Capsule())
            }
            .frame(height: 4)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// P R N D, with the current gear filled in.
private struct GearStrip: View {
    let gear: DriveSnapshot.Gear

    private static let gears: [(String, DriveSnapshot.Gear, String)] = [
        ("P", .park, "Park"), ("R", .reverse, "Reverse"), ("N", .neutral, "Neutral"), ("D", .drive, "Drive"),
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.gears, id: \.0) { letter, value, _ in
                let isCurrent = value == gear
                Text(letter)
                    .font(.geist(15, isCurrent ? .semibold : .medium))
                    .foregroundStyle(isCurrent ? Paper.background : Paper.stale)
                    .frame(width: 26, height: 32)
                    .background(isCurrent ? Paper.ink : .clear, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Gear: \(Self.gears.first { $0.1 == gear }?.2 ?? "Unknown")")
    }
}

/// A bar from the middle: right for power drawn, left for regen.
private struct PowerMeter: View {
    let kW: Int?

    /// The power that fills one half of the bar.
    private static let fullScale = 100.0

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                let half = geometry.size.width / 2
                let fraction = min(abs(Double(kW ?? 0)) / Self.fullScale, 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(Paper.rule).frame(height: 6)
                    Rectangle().fill(Paper.ink)
                        .frame(width: half * fraction, height: 6)
                        .offset(x: (kW ?? 0) < 0 ? half * (1 - fraction) : half)
                    Rectangle().fill(Paper.ink)
                        .frame(width: 2, height: 14)
                        .offset(x: half - 1)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 14)
            HStack {
                Text("Regen")
                Spacer()
                Text(kW.map(DriveText.power) ?? "–")
                    .foregroundStyle(Paper.ink)
                    .fontWeight(.medium)
                    .contentTransition(.numericText(value: Double(kW ?? 0)))
                Spacer()
                Text("Power")
            }
            .font(.geist(13))
            .foregroundStyle(Paper.secondary)
        }
        .animation(.snappy, value: kW)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kW.map { $0 < 0 ? "Regenerating \(-$0) kilowatts" : "Using \($0) kilowatts" } ?? "Power not read")
    }
}
