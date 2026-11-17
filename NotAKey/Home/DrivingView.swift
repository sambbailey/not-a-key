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
            // The route card sits closer to the battery than the bare no-route row does.
            battery.padding(.top, drive.route == nil ? 32 : 24)
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
            HStack(spacing: 14) {
                PinIcon()
                    .stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
                Text("No route set on the car")
                    .font(.geist(14))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Paper.secondary)
            .padding(.vertical, 16)
            .overlay(alignment: .top) { Paper.rule.frame(height: 1) }
            .overlay(alignment: .bottom) { Paper.rule.frame(height: 1) }
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

    private var isRegen: Bool { (kW ?? 0) < 0 }

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                let half = geometry.size.width / 2
                let fraction = min(abs(Double(kW ?? 0)) / Self.fullScale, 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(Paper.rule).frame(height: 6)
                    // Rounded only at the outer end, so it meets the centre line square.
                    UnevenRoundedRectangle(cornerRadii: isRegen
                                           ? .init(topLeading: 3, bottomLeading: 3)
                                           : .init(bottomTrailing: 3, topTrailing: 3))
                        .fill(isRegen ? Paper.nearby : Paper.ink)
                        .frame(width: half * fraction, height: 6)
                        .offset(x: isRegen ? half * (1 - fraction) : half)
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

/// A map pin, drawn on the same 24-point grid as `PaperIcon`.
private struct PinIcon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 12, y: 21))
        path.addCurve(to: CGPoint(x: 5, y: 10), control1: CGPoint(x: 12, y: 21), control2: CGPoint(x: 5, y: 14.8))
        path.addArc(center: CGPoint(x: 12, y: 10), radius: 7, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        path.addCurve(to: CGPoint(x: 12, y: 21), control1: CGPoint(x: 19, y: 14.8), control2: CGPoint(x: 12, y: 21))
        path.closeSubpath()
        path.addEllipse(in: CGRect(x: 9.5, y: 7.5, width: 5, height: 5))
        let scale = min(rect.width, rect.height) / 24
        return path.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: rect.minX / scale, y: rect.minY / scale))
    }
}
