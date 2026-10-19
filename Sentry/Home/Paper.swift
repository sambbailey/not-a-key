import SwiftUI
import UIKit

/// The "Paper" look: warm off-white in light mode, near-black in dark, ink in one weight.
enum Paper {
    static let background = Color(light: 0xF3F3F1, dark: 0x121211)
    static let ink = Color(light: 0x111111, dark: 0xEDEDEA)
    static let secondary = Color(light: 0x55554F, dark: 0xA3A39C)
    static let rule = Color(light: 0xDCDCD7, dark: 0x2A2A27)
    static let nearby = Color(light: 0x15803D, dark: 0x4ADE80)
    static let outline = Color(light: 0x111111, dark: 0x5A5A55)
    static let card = Color(light: 0xE8E8E4, dark: 0x1E1E1C)
    static let disabledOutline = Color(light: 0xC9C9C3, dark: 0x3A3A36)
    static let disabledInk = Color(light: 0x7A7A74, dark: 0x6E6E68)
    /// Numbers read while the car was last in range.
    static let stale = Color(light: 0x6B6B66, dark: 0x8A8A84)
    static let staleBar = Color(light: 0x8A8A84, dark: 0x6B6B66)
    static let bannerSecondary = Color(light: 0xB9B9B3, dark: 0x55554F)
    static let danger = Color(light: 0xB42318, dark: 0xF97066)
}

extension Font {
    /// Geist, the design's typeface, scaling with Dynamic Type like `style`.
    /// Pass a nil `style` for text that must keep its size, like the battery figure.
    static func geist(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: TextStyle? = .body) -> Font {
        let name = switch weight {
        case .medium: "Geist-Medium"
        case .semibold, .bold, .heavy, .black: "Geist-SemiBold"
        default: "Geist-Regular"
        }
        guard let style else { return .custom(name, fixedSize: size) }
        return .custom(name, size: size, relativeTo: style)
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255,
                           alpha: 1)
        })
    }
}

/// A pill-shaped command button: filled for the screen's main action, outlined for the rest.
struct PaperButtonStyle: ButtonStyle {
    var filled = false
    var height: CGFloat = 44

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.geist(height > 44 ? 15 : 14, .medium))
            .padding(.horizontal, 20)
            .frame(minHeight: height)
            .foregroundStyle(foreground)
            .background(filled && isEnabled ? Paper.ink : .clear, in: Capsule())
            .overlay {
                if !filled || !isEnabled {
                    Capsule().strokeBorder(isEnabled ? Paper.outline : Paper.disabledOutline, lineWidth: 1)
                }
            }
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }

    private var foreground: Color {
        guard isEnabled else { return Paper.disabledInk }
        return filled ? Paper.background : Paper.ink
    }
}

/// The design's line icons, drawn on a 24-point grid.
struct PaperIcon: Shape {
    enum Kind {
        case boot, lock, frunk, chargePort, climate, bluetooth, warning
    }

    var kind: Kind

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch kind {
        case .boot:
            path.addLines([CGPoint(x: 3, y: 11), CGPoint(x: 21, y: 11), CGPoint(x: 21, y: 19), CGPoint(x: 3, y: 19)])
            path.closeSubpath()
            path.addLines([CGPoint(x: 5, y: 11), CGPoint(x: 8, y: 5), CGPoint(x: 19, y: 5)])
        case .lock:
            path.addRoundedRect(in: CGRect(x: 5, y: 11, width: 14, height: 10), cornerSize: CGSize(width: 2, height: 2))
            path.move(to: CGPoint(x: 8, y: 11))
            path.addLine(to: CGPoint(x: 8, y: 8))
            path.addArc(center: CGPoint(x: 12, y: 8), radius: 4, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            path.addLine(to: CGPoint(x: 16, y: 11))
        case .frunk:
            path.addLines([CGPoint(x: 4, y: 19), CGPoint(x: 4, y: 14), CGPoint(x: 6, y: 10),
                           CGPoint(x: 18, y: 10), CGPoint(x: 20, y: 14), CGPoint(x: 20, y: 19)])
            path.closeSubpath()
            path.addLines([CGPoint(x: 12, y: 3), CGPoint(x: 12, y: 8)])
            path.addLines([CGPoint(x: 9.5, y: 5.5), CGPoint(x: 12, y: 3), CGPoint(x: 14.5, y: 5.5)])
        case .chargePort:
            path.addLines([CGPoint(x: 9, y: 2), CGPoint(x: 9, y: 7)])
            path.addLines([CGPoint(x: 15, y: 2), CGPoint(x: 15, y: 7)])
            // The plug: square shoulders, then a round bottom down to the cable.
            path.move(to: CGPoint(x: 6, y: 7))
            path.addLine(to: CGPoint(x: 18, y: 7))
            path.addLine(to: CGPoint(x: 18, y: 11))
            path.addArc(center: CGPoint(x: 12, y: 11), radius: 6, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
            path.closeSubpath()
            path.addLines([CGPoint(x: 12, y: 17), CGPoint(x: 12, y: 22)])
        case .climate:
            path.addEllipse(in: CGRect(x: 10, y: 10, width: 4, height: 4))
            // Four fan blades, each a pair of curves out from the hub and back.
            let blades: [(CGPoint, CGPoint, CGPoint, CGPoint, CGPoint, CGPoint, CGPoint)] = [
                (CGPoint(x: 12, y: 10), CGPoint(x: 12, y: 6), CGPoint(x: 13, y: 3), CGPoint(x: 16, y: 3), CGPoint(x: 19, y: 3), CGPoint(x: 18, y: 8), CGPoint(x: 12, y: 10)),
                (CGPoint(x: 14, y: 12), CGPoint(x: 18, y: 12), CGPoint(x: 21, y: 13), CGPoint(x: 21, y: 16), CGPoint(x: 21, y: 19), CGPoint(x: 16, y: 18), CGPoint(x: 14, y: 12)),
                (CGPoint(x: 12, y: 14), CGPoint(x: 12, y: 18), CGPoint(x: 11, y: 21), CGPoint(x: 8, y: 21), CGPoint(x: 5, y: 21), CGPoint(x: 6, y: 16), CGPoint(x: 12, y: 14)),
                (CGPoint(x: 10, y: 12), CGPoint(x: 6, y: 12), CGPoint(x: 3, y: 11), CGPoint(x: 3, y: 8), CGPoint(x: 3, y: 5), CGPoint(x: 8, y: 6), CGPoint(x: 10, y: 12)),
            ]
            for (start, c1, c2, tip, c3, c4, end) in blades {
                path.move(to: start)
                path.addCurve(to: tip, control1: c1, control2: c2)
                path.addCurve(to: end, control1: c3, control2: c4)
                path.closeSubpath()
            }
        case .bluetooth:
            path.addLines([CGPoint(x: 7, y: 7), CGPoint(x: 17, y: 17), CGPoint(x: 12, y: 22), CGPoint(x: 12, y: 2),
                           CGPoint(x: 17, y: 7), CGPoint(x: 7, y: 17)])
        case .warning:
            path.addEllipse(in: CGRect(x: 3, y: 3, width: 18, height: 18))
            path.addLines([CGPoint(x: 12, y: 8), CGPoint(x: 12, y: 13)])
            path.addLines([CGPoint(x: 12, y: 16.5), CGPoint(x: 12, y: 16.6)])
        }
        let scale = min(rect.width, rect.height) / 24
        return path.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: rect.minX / scale, y: rect.minY / scale))
    }
}

extension PaperIcon {
    /// The icon stroked as in the design: round caps and joins, a little under 2 points wide.
    func drawn(size: CGFloat = 22, lineWidth: CGFloat = 1.6) -> some View {
        stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
