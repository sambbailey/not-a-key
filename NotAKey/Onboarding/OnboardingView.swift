import SwiftUI

/// First-run setup: a welcome, then the owner enters their VIN, approves this phone on the car,
/// and learns how to put Toggle Boot on the Action Button.
struct OnboardingView: View {
    @State private var model: PairingModel
    @State private var vinText: String
    @State private var waitingSince: Date?
    /// Past the welcome screen.
    @State private var started = false
    @FocusState private var vinIsFocused: Bool
    @Environment(\.openURL) private var openURL
    private let onDone: () -> Void

    /// `onDone` runs when the owner leaves the final screen; the car is already paired by then.
    init(store: CarStore, onDone: @escaping () -> Void = {}) {
        _model = State(initialValue: PairingModel(store: store))
        _vinText = State(initialValue: store.vin ?? "")
        self.onDone = onDone
    }

    enum Screen {
        case welcome, vin, pairing, done
    }

    #if DEBUG
    /// Shows `screen` whatever the pairing state; for App Store screenshots.
    private var demoScreen: Screen?

    init(store: CarStore, demo screen: Screen) {
        self.init(store: store)
        demoScreen = screen
    }
    #endif

    private var screen: Screen {
        #if DEBUG
        if let demoScreen { return demoScreen }
        #endif
        return switch phase {
        case .enterVIN, .failed: started ? .vin : .welcome
        case .connecting, .tapCard: .pairing
        case .done: .done
        }
    }

    private var vinIsValid: Bool { VIN.normalize(vinText) != nil }

    private var phase: PairingModel.Phase { model.phase }

    var body: some View {
        Group {
            switch screen {
            case .welcome: page(welcome, top: 28) { welcomeFooter }
            case .vin: page(vinEntry, top: 0) { vinFooter }
            case .pairing: page(pairing, top: 12) { pairingFooter }
            case .done: page(done, top: 12) { doneFooter }
            }
        }
        .background(Paper.background)
        .foregroundStyle(Paper.ink)
        .tint(Paper.ink)
        .onChange(of: model.phase) { _, phase in
            waitingSince = phase == .tapCard ? .now : nil
        }
    }

    /// One setup screen: scrolling content with its buttons pinned to the bottom.
    private func page(_ content: some View, top: CGFloat,
                      @ViewBuilder footer: () -> some View) -> some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, top)
                .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0, content: footer)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .background(Paper.background)
        }
    }

    // MARK: Welcome

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            AppMark()
            Text("Make this phone a key for your car")
                .font(.geist(44, .medium))
                .tracking(-1.98)
                .padding(.top, 28)
                .accessibilityAddTraits(.isHeader)
            Text("Not a Key talks to your car over Bluetooth. No Tesla login, no internet needed.")
                .font(.geist(15))
                .foregroundStyle(Paper.secondary)
                .lineSpacing(3)
                .padding(.top, 16)
            Text("You'll need")
                .font(.geist(13))
                .foregroundStyle(Paper.secondary)
                .padding(.top, 40)
            VStack(spacing: 0) {
                NeedRow(symbol: "creditcard", title: "Your key card", detail: "The one that came with the car")
                NeedRow(symbol: "carseat.left", title: "To sit in the driver's seat",
                        detail: "The car confirms the key on its screen")
                // SF Symbols has no Bluetooth logo; radio waves stand in for it.
                NeedRow(symbol: "antenna.radiowaves.left.and.right", title: "Bluetooth on",
                        detail: "You'll be asked to allow it next")
            }
            .overlay(alignment: .top) { Paper.rule.frame(height: 1) }
            .padding(.top, 8)
        }
    }

    @ViewBuilder private var welcomeFooter: some View {
        Button { started = true } label: { Text("Get started").frame(maxWidth: .infinity) }
            .buttonStyle(PaperButtonStyle(filled: true, height: 56, fontSize: 16))
        Text("Takes about two minutes")
            .font(.geist(12))
            .foregroundStyle(Paper.secondary)
            .padding(.top, 12)
    }

    // MARK: VIN

    private var vinEntry: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { started = false } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .padding(.leading, -12)
            .accessibilityLabel("Back")
            stepLabel("Step 1 of 3")
                .padding(.top, 16)
            heading(phase == .enterVIN ? "Enter your car's VIN" : "Pairing didn't finish")
            message(failure.map { "\($0). Check the VIN and try again." }
                ?? "Find it on the car's screen under Controls › Software.")
            SoftwareCard()
                .padding(.top, 24)
            Text("It's also on your V5C logbook.")
                .font(.geist(12))
                .foregroundStyle(Paper.secondary)
                .padding(.top, 8)
            vinField.padding(.top, 28)
        }
    }

    private var failure: String? {
        if case .failed(let reason) = phase { reason } else { nil }
    }

    private var vinField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("VIN")
                .font(.geist(13))
                .foregroundStyle(Paper.secondary)
            Group {
                if model.isWorking {
                    // Read-only while pairing, but in full ink rather than a disabled field's grey.
                    Text(VIN.normalize(vinText) ?? vinText)
                } else {
                    TextField("17 letters and numbers", text: $vinText)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($vinIsFocused)
                        .onSubmit(pair)
                }
            }
            .font(.system(size: 15, design: .monospaced))
            .tracking(0.9)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background(Self.fieldFill, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(vinIsFocused ? Paper.ink : Paper.rule, lineWidth: 1)
            }
            .accessibilityLabel("VIN")
            if !model.isWorking {
                Text("A VIN is 17 letters and numbers, and never contains I, O or Q.")
                    .font(.geist(13))
                    .foregroundStyle(!vinText.isEmpty && !vinIsValid ? Paper.danger : Paper.secondary)
                    .lineSpacing(2)
            }
        }
    }

    /// The input well, a shade lighter than the page.
    static let fieldFill = Color(light: 0xFAFAF8, dark: 0x1A1A18)

    private var vinFooter: some View {
        Button(action: pair) { Text(phase == .enterVIN ? "Pair" : "Try again").frame(maxWidth: .infinity) }
            .buttonStyle(PaperButtonStyle(filled: true, height: 56, fontSize: 16))
            .disabled(!vinIsValid)
    }

    // MARK: Pairing

    private var pairing: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepLabel("Step 2 of 3")
            heading(phase == .connecting ? "Looking for your car" : "Tap your key card on the console")
            message(phase == .connecting
                ? "Stay close to the car with Bluetooth on."
                : "Sit in the car and place the card behind the cup holders. The car will ask you to confirm the new key on its screen.")
            vinField.padding(.top, 32)
            steps.padding(.top, 40)
        }
    }

    private var steps: some View {
        VStack(spacing: 0) {
            StepRow(state: found, label: found == .done ? "Car found nearby" : "Looking for your car")
            StepRow(state: card, label: card == .pending ? "Tap key card" : "Waiting for key card",
                    since: card == .current ? waitingSince : nil)
            StepRow(state: .pending, label: "Confirm on car screen")
        }
        .overlay(alignment: .top) { Paper.rule.frame(height: 1) }
    }

    private var found: StepRow.State {
        phase == .connecting ? .current : .done
    }

    private var card: StepRow.State {
        phase == .tapCard ? .current : .pending
    }

    private var pairingFooter: some View {
        Button(action: model.cancel) { Text("Cancel").frame(maxWidth: .infinity) }
            .buttonStyle(PaperButtonStyle(height: 52))
    }

    // MARK: Done

    private var done: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepLabel("Step 3 of 3")
            Circle()
                .fill(Paper.ink)
                .frame(width: 48, height: 48)
                .overlay {
                    Image(systemName: "checkmark")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Paper.background)
                }
                .padding(.top, 16)
                .accessibilityHidden(true)
            Text("You're set")
                .font(.geist(40, .medium))
                .tracking(-1.6)
                .padding(.top, 20)
                .accessibilityAddTraits(.isHeader)
            Text("This phone is now a key for your car.")
                .font(.geist(15))
                .foregroundStyle(Paper.secondary)
                .lineSpacing(3)
                .padding(.top, 12)
            Text("Open the boot with the Action Button")
                .font(.geist(17, .semibold))
                .tracking(-0.17)
                .padding(.top, 36)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                NumberedRow(number: 1, text: "Open iPhone \(bold("Settings"))")
                NumberedRow(number: 2, text: "Tap \(bold("Action Button"))")
                NumberedRow(number: 3, text: "Swipe to \(bold("Shortcut"))")
                NumberedRow(number: 4, text: "Choose \(bold("Toggle Boot")) from Not a Key")
            }
            .overlay(alignment: .top) { Paper.rule.frame(height: 1) }
            .padding(.top, 12)
            Text("Works with the phone locked. No Action Button? Use Siri or the Shortcuts app.")
                .font(.geist(13))
                .foregroundStyle(Paper.secondary)
                .lineSpacing(2)
                .padding(.top, 12)
        }
    }

    private func bold(_ text: String) -> Text {
        Text(text).font(.geist(15, .semibold))
    }

    @ViewBuilder private var doneFooter: some View {
        Button(action: onDone) { Text("Done").frame(maxWidth: .infinity) }
            .buttonStyle(PaperButtonStyle(filled: true, height: 56, fontSize: 16))
        Button("Open Settings") {
            // Apps can only open Settings at their own page; Action Button is one tap back from it.
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        }
        .font(.geist(15, .medium))
        .frame(maxWidth: .infinity, minHeight: 48)
        .contentShape(Rectangle())
        .padding(.top, 8)
    }

    // MARK: Shared

    private func stepLabel(_ text: String) -> some View {
        Text(text)
            .font(.geist(13))
            .foregroundStyle(Paper.secondary)
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.geist(40, .medium))
            .tracking(-1.6)
            .padding(.top, 8)
            .accessibilityAddTraits(.isHeader)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.geist(15))
            .foregroundStyle(Paper.secondary)
            .lineSpacing(3)
            .padding(.top, 16)
    }

    private func pair() {
        guard vinIsValid else { return }
        vinIsFocused = false
        model.pair(vin: vinText)
    }
}

/// The app icon's mark: a nearly full bar on a light tile.
private struct AppMark: View {
    var body: some View {
        // The icon's 260-point grid, drawn at 64 points.
        let scale: CGFloat = 64 / 260
        RoundedRectangle(cornerRadius: 14)
            .fill(OnboardingView.fieldFill)
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Paper.rule, lineWidth: 1) }
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .leading) {
                    Capsule().fill(Paper.rule).frame(width: 148 * scale)
                    Capsule().fill(Paper.ink).frame(width: 121 * scale)
                }
                .frame(height: 24 * scale)
                .offset(x: 56 * scale, y: 118 * scale)
            }
            .frame(width: 64, height: 64)
            .accessibilityHidden(true)
    }
}

/// One thing the owner needs before pairing: an icon, what it is, and why.
private struct NeedRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .light))
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.geist(16, .medium))
                Text(detail)
                    .font(.geist(13))
                    .foregroundStyle(Paper.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 64)
        .overlay(alignment: .bottom) { Paper.rule.frame(height: 1) }
        .accessibilityElement(children: .combine)
    }
}

/// Where the car shows its VIN: a sketch of the Controls › Software screen.
private struct SoftwareCard: View {
    /// The card's divider, a shade darker than the card.
    private static let divider = Color(light: 0xD4D4CF, dark: 0x2E2E2B)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Controls").foregroundStyle(Paper.secondary)
                Text("›").foregroundStyle(Paper.secondary)
                Text("Software").font(.geist(12, .medium))
            }
            .font(.geist(12))
            Self.divider.frame(height: 1)
            HStack(alignment: .firstTextBaseline) {
                Text("VIN")
                    .font(.geist(13))
                    .foregroundStyle(Paper.secondary)
                Spacer()
                Text("7SAY••••••••••••")
                    .font(.system(size: 13, design: .monospaced))
                    .tracking(0.78)
                    .foregroundStyle(Paper.background)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Paper.ink, in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(16)
        .background(Paper.card, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityHidden(true)
    }
}

/// One numbered instruction on the final screen.
private struct NumberedRow: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(spacing: 16) {
            Text("\(number)")
                .font(.geist(22, .medium))
                .tracking(-0.66)
                .frame(width: 28, alignment: .leading)
            Text(text).font(.geist(15))
            Spacer(minLength: 0)
        }
        .frame(minHeight: 56)
        .overlay(alignment: .bottom) { Paper.rule.frame(height: 1) }
        .accessibilityElement(children: .combine)
    }
}

/// One stage of pairing: a ticked, current or empty circle, then its name.
private struct StepRow: View {
    enum State {
        case done, current, pending
    }

    let state: State
    let label: String
    var since: Date?

    var body: some View {
        HStack(spacing: 14) {
            indicator
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            Text(label)
                .font(.geist(15, state == .current ? .medium : .regular))
                .foregroundStyle(state == .pending ? Paper.secondary : Paper.ink)
            Spacer()
            if let since {
                Text(timerInterval: since...Date.distantFuture, countsDown: false)
                    .font(.geist(13))
                    .monospacedDigit()
                    .foregroundStyle(Paper.secondary)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 60)
        .overlay(alignment: .bottom) { Paper.rule.frame(height: 1) }
        .accessibilityElement(children: .combine)
        .accessibilityValue(state == .done ? "Done" : state == .current ? "In progress" : "")
    }

    @ViewBuilder private var indicator: some View {
        switch state {
        case .done:
            Circle()
                .fill(Paper.ink)
                .overlay {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Paper.background)
                }
        case .current:
            Circle()
                .strokeBorder(Paper.ink, lineWidth: 1.5)
                .overlay { Circle().fill(Paper.ink).frame(width: 8, height: 8) }
        case .pending:
            Circle().strokeBorder(Paper.disabledOutline, lineWidth: 1.5)
        }
    }
}
