import SwiftUI

/// The battery bar: a capsule track filled to the level. Plugged in, a gap cuts the track at the
/// limit; while charging, the fill is green, a faint green runs on to the limit, and the limit
/// is labelled above the gap.
struct ChargeBar: View {
    var level: Int
    /// The charge limit, while plugged in; nil when parked.
    var limit: Int?
    var charging: Bool
    /// Readings from when the car was last in range: the fill is grey.
    var isStale = false
    /// Called with the percent under the finger as the bar is dragged or tapped; nil leaves it fixed.
    var setLimit: ((Int) -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    private static let height: CGFloat = 10
    private static let labelHeight: CGFloat = 14
    private static let labelSpacing: CGFloat = 6
    private static let gapWidth: CGFloat = 2

    private var fill: Color {
        if isStale { return Paper.secondary }
        return charging ? Paper.nearby : Paper.ink
    }

    /// The limit drawn on the bar: none when parked, or at 100%, where there's nothing to cut.
    private var gapLimit: Int? {
        guard let limit, limit < 100, !isStale else { return nil }
        return limit
    }

    var body: some View {
        VStack(spacing: Self.labelSpacing) {
            if charging, let limit, !isStale {
                label(limit)
            }
            track
        }
        .overlay {
            if let setLimit {
                // A finger-sized strip over the bar; it doesn't move the layout.
                GeometryReader { geometry in
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                            setLimit(Int((drag.location.x / geometry.size.width * 100).rounded()))
                        })
                }
                .frame(height: 44)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .offset(y: (44 - Self.height) / 2)
            }
        }
        .sensoryFeedback(.selection, trigger: limit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var track: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Paper.rule
                if charging, let limit, !isStale {
                    Paper.nearby
                        .opacity(colorScheme == .dark ? 0.25 : 0.22)
                        .frame(width: width * Self.fraction(limit))
                }
                UnevenRoundedRectangle(bottomTrailingRadius: Self.height / 2, topTrailingRadius: Self.height / 2)
                    .fill(fill)
                    .frame(width: width * Self.fraction(level))
                if let gapLimit {
                    Paper.background
                        .frame(width: Self.gapWidth)
                        .offset(x: width * Self.fraction(gapLimit))
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: Self.height)
    }

    /// The limit, centred over the gap, or ending at it from 95% up so it stays on screen.
    private func label(_ limit: Int) -> some View {
        GeometryReader { geometry in
            let x = geometry.size.width * Self.fraction(limit)
            Text("\(limit)%")
                .font(.geist(11, .medium, relativeTo: nil))
                .foregroundStyle(Paper.nearby)
                .fixedSize()
                .alignmentGuide(.leading) { text in
                    limit >= 95 ? text.width - x : text.width / 2 - x
                }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: Self.labelHeight)
    }

    private var accessibilityText: String {
        let charged = "\(level)% charged"
        guard let limit, !isStale else { return charged }
        return charging ? "\(charged), charging to \(limit)%" : "\(charged), limit \(limit)%"
    }

    private static func fraction(_ percent: Int) -> CGFloat {
        CGFloat(min(max(percent, 0), 100)) / 100
    }
}

#Preview("Charge bar") {
    VStack(alignment: .leading, spacing: 28) {
        Text("Parked").font(.geist(13))
        ChargeBar(level: 82, limit: nil, charging: false)
        Text("Plugged in").font(.geist(13))
        ChargeBar(level: 82, limit: 90, charging: false)
        Text("Charging").font(.geist(13))
        ChargeBar(level: 82, limit: 90, charging: true)
        Text("Charging, limit 96%").font(.geist(13))
        ChargeBar(level: 60, limit: 96, charging: true)
        Text("Out of range").font(.geist(13))
        ChargeBar(level: 82, limit: nil, charging: false, isStale: true)
    }
    .foregroundStyle(Paper.secondary)
    .padding(24)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(Paper.background)
}
