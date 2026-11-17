import SwiftUI
import TeslaKit

/// Charging in progress: level and time to the limit, what the charger is doing, the limit, and stop.
/// Or plugged in to a charger that isn't supplying power: why, the limit and the current.
struct ChargingView: View {
    let model: HomeModel

    @Environment(\.dismiss) private var dismiss

    private var charge: ChargeReading? { model.charge }
    private var isFast: Bool { charge?.isFastCharger == true }
    private var isNoPower: Bool { charge?.phase == .noPower }

    private var limit: Int? { model.value(of: .limit) }
    private var canChange: Bool { model.working == nil && model.reach == .nearby }
    /// − and + stay live while a value is on its way, so the owner can keep tapping; the newest
    /// value is sent once the car is free.
    private var canStep: Bool { model.reach == .nearby }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero.padding(.top, 32)
                if isNoPower {
                    noPowerCard.padding(.top, 24)
                    VStack(spacing: 0) {
                        ChargeSettingRow(model: model, setting: .limit, minHeight: 72)
                        ChargeSettingRow(model: model, setting: .amps, minHeight: 72)
                    }
                    .overlay(alignment: .top) { Paper.rule.frame(height: 1) }
                    .padding(.top, 20)
                } else {
                    ChargeGrid(charge: charge).padding(.top, 28)
                    ChargeSettingRow(model: model, setting: .limit, minHeight: 76)
                }
                if isFast && !isNoPower {
                    Text("Idle fees may apply once charging finishes.")
                        .font(.geist(13))
                        .foregroundStyle(Paper.secondary)
                        .lineSpacing(5)
                        .padding(.top, 14)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .refreshable { await model.refresh() }
        .safeAreaInset(edge: .bottom) { footer }
        .background(Paper.background)
        .foregroundStyle(Paper.ink)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(title).font(.geist(17, .semibold))
            }
        }
        .toolbarBackground(Paper.background, for: .navigationBar)
        // Once the cable's out or charging stops, the home screen says what the car is doing now.
        .onChange(of: charge?.phase) { _, phase in
            if phase != .charging && phase != .noPower { dismiss() }
        }
    }

    private var title: String { isFast ? "Supercharging" : "Charging" }

    private var hero: some View {
        BatteryHero(level: charge?.batteryLevel,
                    figure: isNoPower ? ChargeText.power(0)
                        : ChargeText.timeToLimit(charge, limit: limit),
                    figureTint: isNoPower ? Paper.warning : nil,
                    caption: isNoPower ? "not charging" : limit.map { "to \($0)%" } ?? "to limit",
                    bar: ChargeBar(level: charge?.batteryLevel ?? 0, limit: limit, charging: !isNoPower,
                                   setLimit: canStep ? { model.set(.limit, to: $0) } : nil)) {
            HStack {
                Text(charge.map { "\(Int($0.rangeMiles.rounded())) mi range" } ?? "")
                Spacer()
                if let limit { Text(ChargeText.limit(limit)) }
            }
        }
    }

    /// Why nothing is charging. A smart charger often holds power back on purpose, so it's a note, not an error.
    private var noPowerCard: some View {
        HStack(alignment: .top, spacing: 12) {
            PaperIcon(kind: .chargePort).drawn(size: 20, lineWidth: 1.8)
                .foregroundStyle(Paper.warning)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("Charger isn't supplying power")
                    .font(.geist(15, .medium))
                Text("The cable is connected, but no power is coming through. Check the charger is switched on, or look at its own app or timer.")
                    .font(.geist(13))
                    .foregroundStyle(Paper.warningSecondary)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Paper.warningCard, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Paper.warningBorder, lineWidth: 1) }
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if isNoPower {
                // Nothing to stop; the cable can still be released.
                Button {
                    Task { await model.send(.openChargePort, for: .chargePort) }
                } label: {
                    Text(model.working == .chargePort ? "Sending…" : "Unlock cable")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PaperButtonStyle(height: 56, fontSize: 16))
            } else {
                Button {
                    Task { await model.send(.stopCharging, for: .chargePort) }
                } label: {
                    HStack(spacing: 10) {
                        if model.working == .chargePort {
                            ProgressView().tint(Paper.background)
                            Text("Sending…")
                        } else {
                            Text("Stop charging")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PaperButtonStyle(filled: true, height: 56, fontSize: 16))
                // A Supercharger releases its own cable once charging stops.
                if !isFast {
                    Button("Unlock cable") {
                        Task { await model.send(.openChargePort, for: .chargePort) }
                    }
                    .font(.geist(15, .medium))
                    .foregroundStyle(canChange ? Paper.ink : Paper.disabledInk)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .contentShape(Rectangle())
                    .buttonStyle(.plain)
                }
            }
        }
        .disabled(!canChange)
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(Paper.background)
    }
}

/// Power, rate, energy added and the charger, two by two.
struct ChargeGrid: View {
    let charge: ChargeReading?

    var body: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                cell("Power", charge?.chargerPowerKW.map(ChargeText.power), leading: true)
                cell("Adding", charge?.chargeRateMph.map(ChargeText.rate), leading: false)
            }
            GridRow {
                cell("Added", charge.flatMap(ChargeText.added), leading: true)
                cell("Charger", charge.flatMap(ChargeText.charger), leading: false)
            }
        }
        .overlay(alignment: .top) { Paper.rule.frame(height: 1) }
    }

    /// One reading. The left column has a rule on its right; the right column is inset.
    private func cell(_ label: String, _ value: String?, leading: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.geist(13))
                .foregroundStyle(Paper.secondary)
            Text(value ?? "–")
                .font(.geist(20, .medium))
                .tracking(-0.2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.vertical, 14)
        .padding(.leading, leading ? 0 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Paper.rule.frame(height: 1) }
        .overlay(alignment: .trailing) {
            if leading { Paper.rule.frame(width: 1) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The charge limit or charging current, with − and +. − and + stay live while a value is on
/// its way, so the owner can keep tapping; the newest value is sent once the car is free.
struct ChargeSettingRow: View {
    let model: HomeModel
    let setting: HomeModel.ChargeSetting
    var minHeight: CGFloat = 72

    private var isLimit: Bool { setting == .limit }
    private var value: Int? { model.value(of: setting) }

    private var subtitle: String? {
        if isLimit { return model.charge?.isFastCharger == true ? "Trip" : "Daily" }
        return model.charge?.currentRequestMax.map { "Up to \(ChargeText.amps($0))" }
    }

    private func text(_ value: Int) -> String { isLimit ? "\(value)%" : ChargeText.amps(value) }
    private func spoken(_ value: Int) -> String { isLimit ? "\(value) percent" : "\(value) amps" }

    var body: some View {
        let range = model.range(of: setting)
        let canLower = value.flatMap { value in range.map { value > $0.lowerBound } } ?? false
        let canRaise = value.flatMap { value in range.map { value < $0.upperBound } } ?? false
        return StepRow(title: isLimit ? "Charge limit" : "Charging current", subtitle: subtitle,
                       value: value.map(text), spokenValue: value.map(spoken),
                       lowerLabel: isLimit ? "Lower limit" : "Lower current",
                       raiseLabel: isLimit ? "Raise limit" : "Raise current",
                       canLower: canLower, canRaise: canRaise, minHeight: minHeight) { delta in
            model.step(setting, by: delta)
        }
        .disabled(model.reach != .nearby)
    }
}

/// A setting with − and + either side of its value, as the design draws the charge limit.
private struct StepRow: View {
    let title: String
    let subtitle: String?
    let value: String?
    let spokenValue: String?
    let lowerLabel: String
    let raiseLabel: String
    let canLower: Bool
    let canRaise: Bool
    let minHeight: CGFloat
    let adjust: (Int) -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.geist(16, .medium))
                if let subtitle {
                    Text(subtitle)
                        .font(.geist(13))
                        .foregroundStyle(Paper.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 14) {
                stepButton(label: lowerLabel, symbol: "minus", by: -1)
                    .disabled(!canLower)
                Text(value ?? "–")
                    .font(.geist(20, .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: 52)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: value)
                stepButton(label: raiseLabel, symbol: "plus", by: 1)
                    .disabled(!canRaise)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(spokenValue ?? "Not read yet")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: if canRaise { adjust(1) }
                case .decrement: if canLower { adjust(-1) }
                @unknown default: break
                }
            }
        }
        .frame(minHeight: minHeight)
        .overlay(alignment: .bottom) { Paper.rule.frame(height: 1) }
    }

    private func stepButton(label: String, symbol: String, by delta: Int) -> some View {
        Button { adjust(delta) } label: {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .regular))
                .frame(width: 44, height: 44)
                .overlay { Circle().strokeBorder(Paper.outline, lineWidth: 1) }
                .contentShape(Circle())
        }
        .buttonStyle(StepButtonStyle())
        .accessibilityLabel(label)
    }
}

/// An outlined round button that greys out when disabled.
private struct StepButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Paper.ink : Paper.disabledInk)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// The battery level large, a figure to its right, then the bar and a line underneath.
struct BatteryHero<Line: View>: View {
    let level: Int?
    let figure: String
    /// Colours the figure, e.g. amber for a charger without power.
    var figureTint: Color?
    let caption: String
    /// Readings from when the car was last in range, shown greyed.
    var isStale = false
    let bar: ChargeBar
    @ViewBuilder let line: Line

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom) {
                levelText
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(figure)
                        .font(.geist(28, .medium))
                        .tracking(-0.56)
                        .foregroundStyle(figureTint ?? (isStale ? Paper.stale : Paper.ink))
                    Text(caption)
                        .font(.geist(13))
                        .foregroundStyle(Paper.secondary)
                }
                .padding(.bottom, 6)
                .accessibilityElement(children: .combine)
            }
            .foregroundStyle(isStale ? Paper.stale : Paper.ink)

            bar.padding(.top, 22)

            line
                .font(.geist(13))
                .foregroundStyle(Paper.secondary)
                .padding(.top, 10)
        }
    }

    private var levelText: some View {
        Group {
            if let level {
                // Tight between the digits; lighter after the last, where full tracking pulls the % into a round digit like 8.
                let digits = String(level)
                Text(digits.dropLast())
                    .font(.geist(132, .medium, relativeTo: nil))
                    .tracking(-7.9)
                + Text(digits.suffix(1))
                    .font(.geist(132, .medium, relativeTo: nil))
                    .tracking(-3)
                + Text("%")
                    .font(.geist(40, relativeTo: nil))
                    .tracking(-0.8)
            } else {
                Text("–").font(.geist(132, .medium, relativeTo: nil))
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        // The design sets the number tight to its line, so the bar sits close underneath.
        .padding(.vertical, -14)
        .accessibilityLabel(level.map { "Battery \($0) percent" } ?? "Battery not read yet")
    }
}
