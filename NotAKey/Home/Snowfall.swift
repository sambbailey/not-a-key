import SwiftUI

/// Sparse, slow snow behind the home screen while the festive theme is on.
struct Snowfall: View {
    struct Flake {
        /// Horizontal start, 0 to 1 across the width.
        let x: Double
        /// Diameter in points.
        let size: Double
        /// Seconds to fall the full height.
        let period: Double
        /// Where in its fall the flake starts, 0 to 1.
        let phase: Double
        /// How far it sways either side, in points.
        let drift: Double
    }

    /// Thirty flakes from a fixed seed, so the snow looks the same each launch.
    static let flakes: [Flake] = {
        var generator = SeededGenerator(seed: 25_12)
        return (0..<30).map { _ in
            Flake(x: .random(in: 0...1, using: &generator),
                  size: .random(in: 2...4, using: &generator),
                  period: .random(in: 8...14, using: &generator),
                  phase: .random(in: 0...1, using: &generator),
                  drift: .random(in: -12...12, using: &generator))
        }
    }()

    static func position(of flake: Flake, at time: TimeInterval, in size: CGSize) -> CGPoint {
        let progress = (time / flake.period + flake.phase).truncatingRemainder(dividingBy: 1)
        let y = -flake.size + progress * (size.height + 2 * flake.size)
        let x = flake.x * size.width + sin(progress * 2 * .pi) * flake.drift
        return CGPoint(x: min(max(x, 0), size.width), y: y)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if Festive.shared.isActive, !reduceMotion, scenePhase == .active {
            TimelineView(.animation) { timeline in
                Canvas { context, size in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    let shading = GraphicsContext.Shading.color(Paper.ink.opacity(colorScheme == .dark ? 0.25 : 0.12))
                    for flake in Self.flakes {
                        let point = Self.position(of: flake, at: time, in: size)
                        let rect = CGRect(x: point.x - flake.size / 2, y: point.y - flake.size / 2,
                                          width: flake.size, height: flake.size)
                        context.fill(Path(ellipseIn: rect), with: shading)
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// SplitMix64: a tiny deterministic generator for the flake layout.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
