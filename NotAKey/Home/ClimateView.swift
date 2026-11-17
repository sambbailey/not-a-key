import SwiftUI
import TeslaKit

/// Cabin climate: the temperatures, the set point, defrost and the parked mode, and start or stop.
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
                setter.padding(.top, 40)
                toggles.padding(.top, 40)
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
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Climate").font(.geist(17, .semibold))
            }
        }
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
                stepButton(label: "Cooler", by: -Self.step)
                    .disabled(setPoint <= Self.range.lowerBound)
                HStack(alignment: .top, spacing: 0) {
                    // Tight between digits only: tracking after the last digit clips its right edge.
                    (Text(number.dropLast()).tracking(-7.2) + Text(number.suffix(1)))
                        .font(.geist(120, .medium, relativeTo: nil))
                    Text("°")
                        .font(.geist(40, relativeTo: nil))
                        .padding(.top, 14)
                        .padding(.leading, -7.2)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(width: 150)
                .contentTransition(.numericText(value: setPoint))
                .animation(.snappy, value: setPoint)
                stepButton(label: "Warmer", by: Self.step)
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

    private func stepButton(label: String, by delta: Double) -> some View {
        Button { adjust(by: delta) } label: {
            StepIcon(plus: delta > 0)
                .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .frame(width: 20, height: 20)
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
            .toggleStyle(CheckboxStyle())
            .frame(minHeight: 68)
            .overlay(alignment: .bottom) { Paper.rule.frame(height: 1) }

            keeperModes
                .padding(.vertical, 16)
                .overlay(alignment: .bottom) { Paper.rule.frame(height: 1) }
        }
        .tint(Paper.ink)
        .disabled(!canChange)
        .overlay(alignment: .top) { Paper.rule.frame(height: 1) }
    }

    /// Off / Keep / Dog / Camp, with what the selected one does underneath.
    private var keeperModes: some View {
        let selected = climate?.keeperMode ?? .off
        return VStack(alignment: .leading, spacing: 12) {
            Text("Keep climate on")
                .font(.geist(16, .medium))
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 6) {
                ForEach(ClimateKeeperMode.allCases, id: \.self) { mode in
                    Button(Self.label(mode)) {
                        guard mode != selected else { return }
                        Task { await model.send(.climateKeeper(mode), for: .climate) }
                    }
                    .buttonStyle(ModeButtonStyle(isSelected: mode == selected))
                    .accessibilityAddTraits(mode == selected ? .isSelected : [])
                }
            }
            Text(ClimateText.hint(for: selected))
                .font(.geist(13))
                .foregroundStyle(Paper.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func label(_ mode: ClimateKeeperMode) -> String {
        switch mode {
        case .off: "Off"
        case .keep: "Keep"
        case .dog: "Dog"
        case .camp: "Camp"
        }
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

    private var canChange: Bool { model.working == nil && model.reach == .nearby }

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

/// The − and + on the set point's buttons, on the design's 24-point grid.
private struct StepIcon: Shape {
    let plus: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addLines([CGPoint(x: 5, y: 12), CGPoint(x: 19, y: 12)])
        if plus { path.addLines([CGPoint(x: 12, y: 5), CGPoint(x: 12, y: 19)]) }
        let scale = min(rect.width, rect.height) / 24
        return path.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: rect.minX / scale, y: rect.minY / scale))
    }
}

/// A square check box at the end of the row, as the design draws Defrost; the whole row toggles it.
private struct CheckboxStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let ink = isEnabled ? Paper.ink : Paper.disabledInk
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 14) {
                configuration.label
                    .frame(maxWidth: .infinity, alignment: .leading)
                ZStack {
                    if configuration.isOn {
                        RoundedRectangle(cornerRadius: 4).fill(ink)
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Paper.background)
                    } else {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(isEnabled ? Paper.outline : Paper.disabledOutline, lineWidth: 1)
                    }
                }
                .frame(width: 22, height: 22)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

/// One choice in a row of pills: filled when selected, outlined otherwise.
private struct ModeButtonStyle: ButtonStyle {
    let isSelected: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.geist(14, .medium))
            .foregroundStyle(isSelected ? Paper.background : isEnabled ? Paper.ink : Paper.disabledInk)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background {
                if isSelected {
                    Capsule().fill(isEnabled ? Paper.ink : Paper.disabledInk)
                } else {
                    Capsule().strokeBorder(Paper.disabledOutline, lineWidth: 1)
                }
            }
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
