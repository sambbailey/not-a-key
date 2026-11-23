import SwiftUI

/// A strip across the top of every screen in demo mode, saying the car is simulated, with a way out.
struct DemoBanner: View {
    let onExit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "play.rectangle")
                .font(.system(size: 14, weight: .medium))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Demo Mode")
                    .font(.geist(14, .semibold))
                Text("Simulated car. Nothing is sent to a real one.")
                    .font(.geist(12))
                    .foregroundStyle(Paper.warningSecondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            Button("Exit", action: onExit)
                .font(.geist(14, .medium))
                .padding(.horizontal, 14)
                .frame(minHeight: 32)
                .overlay { Capsule().strokeBorder(Paper.warningBorder, lineWidth: 1) }
                .contentShape(Capsule())
                .buttonStyle(.plain)
                .accessibilityLabel("Exit demo")
        }
        .foregroundStyle(Paper.ink)
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Paper.warningCard)
        .overlay(alignment: .bottom) { Paper.warningBorder.frame(height: 1) }
    }
}
