import SwiftUI
import TeslaKit

/// Cabin climate: the temperatures, the set point, defrost and keep-on, and start or stop.
struct ClimateView: View {
    let model: HomeModel

    /// The set point while the owner is tapping − and +; sent once they pause.
    @State private var target: Double?

    private static let range = 15.0...28.0
    private static let step = 0.5
    private static let fallback = 21.0

    private var climate: ClimateSnapshot? { model.climate }
    private var isAway: Bool { model.reach == .notInRange }
    private var isOn: Bool { climate?.isOn == true }
    private var setPoint: Double { target ?? climate?.setCelsius ?? Self.fallback }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                temperatures.padding(.top, 40)
                setter.padding(.top, 56)
                toggles.padding(.top, 56)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) { footer }
        .background(Paper.background)
        .foregroundStyle(Paper.ink)
        .navigationTitle("Climate")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Paper.background, for: .navigationBar)
        .task(id: target) { await sendTarget() }
    }

    private var temperatures: some View {
        HStack(spacing: 0) {
            reading("Inside", climate?.insideCelsius)
            Paper.rule.frame(width: 1)
            reading("Outside", climate?.outsideCelsius)
                .padding(.leading, 16)
        }
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .top) { Paper.rule.frame(height: 1) }
        .overlay(alignment: .bottom) { Paper.rule.frame(height: 1) }
    }

    private func reading(_ label: String, _ celsius: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.geist(13))
                .foregroundStyle(Paper.secondary)
            Text(celsius.map { ClimateText.degrees($0.rounded()) } ?? "–")
                .font(.geist(24, .medium))
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var setter: some View {
        VStack(spacing: 8) {
            Text("Set to")
                .font(.geist(13))
                .foregroundStyle(Paper.secondary)
            HStack(spacing: 28) {
                stepButton("minus", label: "Cooler", by: -Self.step)
                    .disabled(setPoint <= Self.range.lowerBound)
                HStack(alignment: .top, spacing: 0) {
                    Text(number)
                        .font(.geist(120, .medium, relativeTo: nil))
                        .tracking(-7.2)
                    Text("°")
                        .font(.geist(40, relativeTo: nil))
                        .padding(.top, 14)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(width: 150)
                .contentTransition(.numericText(value: setPoint))
                .animation(.snappy, value: setPoint)
                stepButton("plus", label: "Warmer", by: Self.step)
                    .disabled(setPoint >= Self.range.upperBound)
            }
            .disabled(!canChange)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Set to")
        .accessibilityValue(ClimateText.degrees(setPoint))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjust(by: Self.step)
            case .decrement: adjust(by: -Self.step)
            @unknown default: break
            }
        }
    }

    /// The set point without its degree sign, so the sign can sit smaller beside it.
    private var number: String {
        String(ClimateText.degrees(setPoint).dropLast())
    }

    private func stepButton(_ symbol: String, label: String, by delta: Double) -> some View {
        Button { adjust(by: delta) } label: {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .regular))
                .frame(width: 56, height: 56)
                .overlay { Circle().strokeBorder(Paper.outline, lineWidth: 1) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var toggles: some View {
        VStack(spacing: 0) {
            Toggle(isOn: binding(\.isDefrosting, send: VehicleCommand.setDefrost)) {
                Text("Defrost")
                    .font(.geist(16, .medium))
            }
            .frame(minHeight: 68)
            .overlay(alignment: .bottom) { Paper.rule.frame(height: 1) }

            Toggle(isOn: binding(\.keepsOn, send: VehicleCommand.keepClimate)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep on while parked")
                        .font(.geist(16, .medium))
                    Text("Stops below 20%")
                        .font(.geist(13))
                        .foregroundStyle(Paper.secondary)
                }
            }
            .frame(minHeight: 68)
            .overlay(alignment: .bottom) { Paper.rule.frame(height: 1) }
        }
        .tint(Paper.ink)
        .disabled(!canChange)
        .overlay(alignment: .top) { Paper.rule.frame(height: 1) }
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Button {
                Task { await model.send(isOn ? .climateOff : .climateOn, for: .climate) }
            } label: {
                HStack(spacing: 10) {
                    if model.working == .climate {
                        ProgressView().tint(isOn ? Paper.ink : Paper.background)
                        Text("Sending…")
                    } else {
                        Text(isOn ? "Stop climate" : "Start climate")
                    }
                }
                .font(.geist(16, .medium))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PaperButtonStyle(filled: !isOn, height: 56))
            .disabled(!canChange)
            Text(isAway ? "Car not in range" : "Wakes the car once over Bluetooth")
                .font(.geist(12))
                .foregroundStyle(Paper.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(Paper.background)
    }

    private var canChange: Bool { model.working == nil && !isAway }

    private func adjust(by delta: Double) {
        target = min(max(setPoint + delta, Self.range.lowerBound), Self.range.upperBound)
    }

    /// Sends the set point a moment after the last tap, waiting out any command already running.
    private func sendTarget() async {
        guard let target else { return }
        do {
            try await Task.sleep(for: .seconds(1))
            while model.working != nil { try await Task.sleep(for: .milliseconds(200)) }
        } catch {
            return  // Another tap; its own task sends the newer value.
        }
        if target != climate?.setCelsius {
            await model.send(.setTemperature(celsius: target), for: .climate)
        }
        if self.target == target { self.target = nil }
    }

    /// A toggle that shows the car's setting and sends `send` when flipped.
    private func binding(_ keyPath: KeyPath<ClimateSnapshot, Bool>,
                         send: @escaping (Bool) -> VehicleCommand) -> Binding<Bool> {
        Binding {
            climate?[keyPath: keyPath] ?? false
        } set: { on in
            Task { await model.send(send(on), for: .climate) }
        }
    }
}
