import SwiftUI
import TeslaKit

/// The home screen: battery and range up top, then one row per control.
struct HomeView: View {
    enum Route: Hashable {
        case climate, settings
    }

    let store: CarStore

    @State private var model: HomeModel
    @State private var path: [Route] = []
    @Environment(\.scenePhase) private var scenePhase
    @State private var wasInBackground = false

    init(store: CarStore) {
        self.store = store
        _model = State(initialValue: HomeModel(car: store))
    }

    private var isAway: Bool { model.reach == .notInRange }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    hero
                        .padding(.top, 48)
                    if isAway {
                        awayCard.padding(.top, 28)
                        controls.padding(.top, 24)
                    } else {
                        controls.padding(.top, 44)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .refreshable { await model.refresh() }
            .safeAreaInset(edge: .bottom) { footer }
            .background(Paper.background)
            .foregroundStyle(Paper.ink)
            .animation(.default, value: model.reach)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .climate: ClimateView(model: model)
                case .settings: SettingsView(store: store, model: model)
                }
            }
        }
        // Over the whole stack, so a command's outcome shows on whichever screen sent it.
        .overlay(alignment: .top) { banner }
        .animation(.snappy, value: model.banner)
        .onChange(of: model.banner) { _, banner in
            if let banner { AccessibilityNotification.Announcement(banner.message).post() }
        }
        .tint(Paper.ink)
        .task { await model.refresh() }
        .onChange(of: scenePhase) { _, phase in
            // Only a real return to the foreground reads again, not Control Centre or a Face ID sheet.
            switch phase {
            case .background:
                wasInBackground = true
            case .active where wasInBackground:
                wasInBackground = false
                Task { await model.refresh() }
            default:
                break
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text(store.vin.flatMap(VIN.modelName) ?? "Your car")
                .font(.geist(17, .semibold))
                .tracking(-0.17)
            Spacer()
            HStack(spacing: 6) {
                switch model.reach {
                case .nearby:
                    Circle().fill(Paper.nearby).frame(width: 7, height: 7)
                    Text("Nearby")
                case .notInRange:
                    Circle().strokeBorder(Paper.staleBar, lineWidth: 1.5).frame(width: 7, height: 7)
                    Text(model.isRetrying ? "Checking" : "Not in range")
                case .unknown:
                    Circle().strokeBorder(Paper.staleBar, lineWidth: 1.5).frame(width: 7, height: 7)
                    Text(model.isReading ? "Connecting" : "Not connected")
                }
            }
            .font(.geist(13))
            .foregroundStyle(Paper.secondary)
            .accessibilityElement(children: .combine)
            NavigationLink(value: Route.settings) {
                Image("Gear")
                    .resizable()
                    .frame(width: 20, height: 20)
                    .foregroundStyle(Paper.ink)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Settings")
            // A full-size tap target that still lines the icon up with the screen's margin.
            .padding(.leading, 2)
            .padding(.trailing, -12)
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom) {
                level
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(model.charge.map { "\(Int($0.rangeMiles.rounded()))" } ?? "–")
                        .font(.geist(28, .medium))
                        .tracking(-0.56)
                    Text("miles range")
                        .font(.geist(13))
                        .foregroundStyle(Paper.secondary)
                }
                .padding(.bottom, 6)
                .accessibilityElement(children: .combine)
            }
            .foregroundStyle(isAway ? Paper.stale : Paper.ink)

            GeometryReader { geometry in
                Capsule().fill(Paper.rule)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(isAway ? Paper.staleBar : Paper.ink)
                            .frame(width: geometry.size.width * CGFloat(model.charge?.batteryLevel ?? 0) / 100)
                    }
                    .clipShape(Capsule())
            }
            .frame(height: 6)
            .padding(.top, 22)
            .accessibilityHidden(true)

            TimelineView(.everyMinute) { context in
                Text(isAway
                     ? HomeText.awayLine(charge: model.charge, body: model.body, now: context.date)
                     : HomeText.statusLine(charge: model.charge, body: model.body,
                                           isReading: model.isReading, now: context.date))
                    .font(.geist(13))
                    .foregroundStyle(Paper.secondary)
            }
            .padding(.top, 10)
        }
    }

    private var level: some View {
        Group {
            if let charge = model.charge {
                Text("\(charge.batteryLevel)")
                    .font(.geist(132, .medium, relativeTo: nil))
                    .tracking(-7.9)
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
        .accessibilityLabel(model.charge.map { "Battery \($0.batteryLevel) percent" } ?? "Battery not read yet")
    }

    private var awayCard: some View {
        HStack(alignment: .top, spacing: 12) {
            PaperIcon(kind: .bluetooth).drawn(size: 20).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.isRetrying ? "Looking for your car…" : "Car not in range")
                    .font(.geist(15, .medium))
                Text("Controls work again once you're within Bluetooth range. Numbers shown are from the last read.")
                    .font(.geist(13))
                    .foregroundStyle(Paper.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Paper.card, in: RoundedRectangle(cornerRadius: 14))
    }

    private var controls: some View {
        VStack(spacing: 0) {
            ForEach(HomeModel.Control.allCases, id: \.self) { control in
                ControlRow(row: row(for: control), compact: isAway,
                           open: control == .climate && !isAway ? { path.append(.climate) } : nil) {
                    // Starting climate goes by its screen, to pick a temperature first.
                    if control == .climate, model.climate?.isOn != true {
                        path.append(.climate)
                    } else {
                        Task { await model.perform(control) }
                    }
                }
            }
        }
        .overlay(alignment: .top) { Paper.rule.frame(height: 1) }
    }

    @ViewBuilder
    private var footer: some View {
        Group {
            if isAway {
                Button {
                    Task { await model.retry() }
                } label: {
                    HStack(spacing: 10) {
                        if model.isRetrying {
                            ProgressView().tint(Paper.ink)
                            Text("Checking…")
                        } else {
                            Text("Try again")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PaperButtonStyle(height: 52))
                .allowsHitTesting(!model.isRetrying)
                .accessibilityLabel(model.isRetrying ? "Checking for the car" : "Try again")
            } else {
                Text("Bluetooth key · No internet needed")
                    .font(.geist(12))
                    .tracking(0.24)
                    .foregroundStyle(Paper.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(Paper.background)
    }

    @ViewBuilder
    private var banner: some View {
        if let banner = model.banner {
            BannerView(banner: banner)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { model.banner = nil }
                .task(id: banner.id) {
                    try? await Task.sleep(for: banner.isError ? .seconds(8) : .seconds(4))
                    if model.banner?.id == banner.id { model.banner = nil }
                }
        }
    }

    // MARK: - Rows

    private func row(for control: HomeModel.Control) -> ControlRow.Model {
        let body = model.body
        let isWorking = model.working == control
        let canSend = model.working == nil && !isAway && model.command(for: control) != nil
        switch control {
        case .boot:
            let moving = body?.boot.isMoving == true
            return .init(icon: .boot, title: "Boot",
                         state: isWorking ? "Sending…" : body.map { HomeText.state(of: $0.boot) },
                         showsProgress: isWorking || moving,
                         action: HomeText.bootAction(body?.boot), isPrimary: !moving, isEnabled: canSend)
        case .doors:
            return .init(icon: .lock, title: "Doors",
                         state: isWorking ? "Sending…" : body.map { $0.isLocked ? "Locked" : "Unlocked" },
                         showsProgress: isWorking,
                         action: body?.isLocked == false ? "Lock" : "Unlock", isEnabled: canSend)
        case .frunk:
            let state: String? = switch body?.frunk {
            case .open?, .ajar?: "Open · Close by hand"
            case let frunk?: HomeText.state(of: frunk)
            case nil: nil
            }
            return .init(icon: .frunk, title: "Frunk", state: isWorking ? "Sending…" : state,
                         showsProgress: isWorking || body?.frunk.isMoving == true,
                         action: "Open", isEnabled: canSend)
        case .climate:
            return .init(icon: .climate, title: "Climate",
                         state: isWorking ? "Sending…" : model.climate.map(ClimateText.summary),
                         showsProgress: isWorking,
                         action: model.climate?.isOn == true ? "Stop" : "Start",
                         // Start only opens the climate screen, so it doesn't wait on a reading.
                         isEnabled: model.climate?.isOn == true ? canSend : !isAway)
        }
    }
}

/// One control: icon, name and state, and the button that changes it.
struct ControlRow: View {
    struct Model {
        var icon: PaperIcon.Kind
        var title: String
        var state: String?
        var showsProgress = false
        var action: String
        var isPrimary = false
        var isEnabled: Bool
    }

    let row: Model
    /// The out-of-range layout: no icon, shorter rows.
    var compact = false
    /// Opens the control's own screen when the row is tapped outside its button.
    var open: (() -> Void)?
    let perform: () -> Void

    /// Nothing moves while the car is out of range, so the bar only shows in range.
    private var showsProgress: Bool { row.showsProgress && !compact }

    var body: some View {
        HStack(spacing: 14) {
            if !compact {
                PaperIcon(kind: row.icon).drawn()
            }
            VStack(alignment: .leading, spacing: showsProgress ? 6 : 2) {
                Text(row.title)
                    .font(.geist(16, .medium))
                if let state = row.state {
                    HStack(spacing: 8) {
                        Text(state)
                            .font(.geist(13))
                            .foregroundStyle(showsProgress ? Paper.ink : Paper.secondary)
                        if showsProgress {
                            ProgressBar()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { open?() }
            .accessibilityAddTraits(open == nil ? [] : .isButton)
            .accessibilityAction { open?() }
            Button(row.action, action: perform)
                .buttonStyle(PaperButtonStyle(filled: row.isPrimary && !compact))
                .disabled(!row.isEnabled)
                .accessibilityLabel("\(row.action) \(row.title.lowercased())")
        }
        .frame(minHeight: compact ? 68 : 76)
        .overlay(alignment: .bottom) { Paper.rule.frame(height: 1) }
        .accessibilityElement(children: .contain)
    }
}

/// A short bar that sweeps while something is moving or a command is on its way.
private struct ProgressBar: View {
    @State private var sweeping = false

    var body: some View {
        Capsule().fill(Paper.rule)
            .frame(width: 64, height: 3)
            .overlay(alignment: .leading) {
                Capsule().fill(Paper.ink)
                    .frame(width: 29)
                    .offset(x: sweeping ? 35 : 0)
            }
            .clipShape(Capsule())
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever()) { sweeping = true }
            }
            .accessibilityHidden(true)
    }
}

/// The note that drops in from the top after a command, or when one fails.
private struct BannerView: View {
    let banner: HomeModel.Banner

    var body: some View {
        HStack(spacing: 12) {
            PaperIcon(kind: icon).drawn(size: 20, lineWidth: 1.7)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.message)
                    .font(.geist(15, .medium))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = banner.detail {
                    Text(detail)
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(Paper.bannerSecondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
            Text("Now")
                .font(.geist(13))
                .foregroundStyle(Paper.bannerSecondary)
        }
        .foregroundStyle(Paper.background)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 56)
        .background(Paper.ink, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }

    private var icon: PaperIcon.Kind {
        guard !banner.isError else { return .warning }
        return switch banner.control {
        case .boot?: .boot
        case .doors?: .lock
        case .frunk?: .frunk
        case .climate?: .climate
        case nil: .warning
        }
    }
}

#Preview {
    HomeView(store: CarStore())
}
