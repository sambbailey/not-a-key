import SwiftUI
import TeslaKit

/// The home screen: battery and range up top, then one row per control.
struct HomeView: View {
    enum Route: Hashable {
        case climate, charging, settings
    }

    let store: CarStore

    @State private var model: HomeModel
    @State private var path: [Route] = []
    @Environment(\.scenePhase) private var scenePhase
    @State private var wasInBackground = false
    /// How far the banner has been dragged; up past a little way clears it.
    @State private var bannerDrag: CGFloat = 0

    init(store: CarStore) {
        self.store = store
        _model = State(initialValue: HomeModel(car: store))
    }

    #if DEBUG
    /// Opens on `model`'s readings, already showing `path`; for App Store screenshots.
    init(store: CarStore, model: HomeModel, path: [Route] = []) {
        self.store = store
        _model = State(initialValue: model)
        _path = State(initialValue: path)
    }
    #endif

    private var isAway: Bool { model.reach == .notInRange }
    /// Controls wait for the car to be found; until then they'd only look connected.
    private var isNearby: Bool { model.reach == .nearby }
    /// Which charging layout the home screen shows. Only for a car nearby and parked; out of
    /// range the reading may be old.
    private var phase: ChargeReading.Phase {
        guard isNearby, !model.isDriving, let charge = model.charge else { return .idle }
        return charge.phase
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if model.isAlarmed {
                        alarmBanner
                            // The design sets the banner a little wider than the page.
                            .padding(.horizontal, -8)
                            .padding(.bottom, 20)
                    }
                    header
                    if model.isDriving, let drive = model.drive {
                        DrivingPanel(drive: drive, charge: model.charge)
                        controls.padding(.top, 20)
                        Text("Boot, frunk, charge port and doors are off while the car is in gear.")
                            .font(.geist(13))
                            .foregroundStyle(Paper.secondary)
                            .lineSpacing(3)
                            .padding(.vertical, 14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(alignment: .bottom) { Paper.rule.frame(height: 1) }
                    } else if isAway {
                        hero.padding(.top, 32)
                        awayCard.padding(.top, 20)
                        controls.padding(.top, 16)
                    } else if phase == .charging {
                        // Charging comes first; the controls follow below.
                        hero.padding(.top, model.isAlarmed ? 32 : 40)
                        chargingPanel.padding(.top, 24)
                        Text("Controls")
                            .font(.geist(13))
                            .foregroundStyle(Paper.secondary)
                            .accessibilityAddTraits(.isHeader)
                            .padding(.top, 36)
                        controls.padding(.top, 8)
                        // The page scrolls here, so the footnote comes at its end.
                        keyNote.padding(.top, 24)
                    } else {
                        hero.padding(.top, model.isAlarmed ? 32 : 48)
                        controls.padding(.top, 28)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .refreshable { await model.refresh() }
            .safeAreaInset(edge: .bottom) { footer }
            .background {
                ZStack {
                    Paper.background
                    Snowfall()
                }
                .ignoresSafeArea()
            }
            .foregroundStyle(Paper.ink)
            .animation(.default, value: model.reach)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .climate: ClimateView(model: model)
                case .charging: ChargingView(model: model)
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
            if phase == .active { Festive.shared.refreshSeason() }
            // Only a real return to the foreground reads again, not Control Centre or a Face ID sheet.
            switch phase {
            case .background:
                wasInBackground = true
                model.stop()
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
        HStack(spacing: 0) {
            Text(store.carName ?? "Your car")
                .font(.geist(17, .semibold))
                .tracking(-0.17)
            Spacer()
            HStack(spacing: 6) {
                switch model.reach {
                case .nearby where phase == .plugged || phase == .noPower:
                    Circle().strokeBorder(phase == .noPower ? Paper.warning : Paper.nearby, lineWidth: 1.5)
                        .frame(width: 7, height: 7)
                    Text("Plugged in")
                case .nearby:
                    Circle().fill(Paper.nearby).frame(width: 7, height: 7)
                    Text(model.isDriving ? "Driving" : phase == .charging ? "Charging" : "Nearby")
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
            .padding(.leading, 8)
            .padding(.trailing, -12)
        }
    }

    @ViewBuilder
    private var hero: some View {
        let charge = model.charge
        let level = charge?.batteryLevel ?? 0
        let range = charge.map { "\(Int($0.rangeMiles.rounded()))" } ?? "–"
        switch phase {
        case .plugged:
            let start = charge?.isWaitingForSchedule == true ? charge?.scheduledStart : nil
            BatteryHero(level: charge?.batteryLevel,
                        figure: start.map { ChargeText.time($0) } ?? range,
                        caption: start == nil ? "miles range" : "charging starts",
                        bar: ChargeBar(level: level, limit: charge?.chargeLimit, charging: false)) {
                limitLine(start == nil ? "Not charging" : "\(range) mi range · Scheduled")
            }
        case .noPower:
            BatteryHero(level: charge?.batteryLevel,
                        figure: charge?.chargeLimit.map { "\($0)%" } ?? "–",
                        caption: "charge limit",
                        bar: ChargeBar(level: level, limit: charge?.chargeLimit, charging: false)) {
                HStack {
                    Text("\(range) mi range · Not charging")
                    Spacer()
                    if let amps = charge?.currentRequest { Text(ChargeText.amps(amps)) }
                }
            }
        case .charging:
            let limit = model.value(of: .limit)
            BatteryHero(level: charge?.batteryLevel,
                        figure: ChargeText.timeToLimit(charge, limit: limit),
                        caption: limit.map { "to \($0)%" } ?? "to limit",
                        bar: ChargeBar(level: level, limit: limit, charging: true,
                                       setLimit: { model.set(.limit, to: $0) })) {
                limitLine("\(range) mi range", limit: limit)
            }
        case .idle:
            BatteryHero(level: charge?.batteryLevel, figure: range, caption: "miles range", isStale: isAway,
                        bar: ChargeBar(level: level, limit: nil, charging: false, isStale: isAway)) {
                TimelineView(.everyMinute) { context in
                    Text(isAway
                         ? HomeText.awayLine(charge: charge, body: model.body, sentry: model.sentry, now: context.date)
                         : HomeText.statusLine(charge: charge, body: model.body,
                                               isReading: model.isReading, now: context.date))
                }
            }
        }
    }

    /// The line under the bar while plugged in: `text` on the left, the charge limit on the right.
    private func limitLine(_ text: String, limit: Int? = nil) -> some View {
        HStack {
            Text(text)
            Spacer()
            if let limit = limit ?? model.charge?.chargeLimit { Text(ChargeText.limit(limit)) }
        }
    }

    /// While charging: what the charger is doing, the limit, and stop.
    private var chargingPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ChargeGrid(charge: model.charge)
            ChargeSettingRow(model: model, setting: .limit, minHeight: 72)
            Button {
                Task { await model.send(.stopCharging, for: .chargePort) }
            } label: {
                HStack(spacing: 10) {
                    if model.working == .chargePort {
                        ProgressView().tint(Paper.ink)
                        Text("Sending…")
                    } else {
                        Text("Stop charging")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PaperButtonStyle(height: 44, fontSize: 15))
            .disabled(model.working != nil)
            .padding(.top, 16)
            if model.charge?.isFastCharger == true {
                Text("Idle fees may apply once charging finishes.")
                    .font(.geist(13))
                    .foregroundStyle(Paper.secondary)
                    .lineSpacing(5)
                    .padding(.top, 14)
            }
        }
    }

    /// The Sentry alarm, held at the top for as long as the car reports it.
    private var alarmBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 18, weight: .medium))
            Text("Sentry alarm · someone at the car")
                .font(.geist(15, .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
            if let since = model.alarmSince {
                TimelineView(.everyMinute) { context in
                    Text(HomeText.shortAge(of: since, now: context.date))
                        .font(.geist(13))
                        .foregroundStyle(Paper.onAlarmSecondary)
                }
            }
        }
        .foregroundStyle(Paper.onAlarm)
        .padding(.horizontal, 16)
        .frame(minHeight: 56)
        .background(Paper.alarmFill, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }

    private var awayCard: some View {
        HStack(alignment: .top, spacing: 12) {
            PaperIcon(kind: .bluetooth).drawn(size: 20).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.isRetrying ? "Looking for your car…" : "Car not in range")
                    .font(.geist(15, .medium))
                Text("Controls return when you're nearby.")
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
            // Only climate can change while the car is in gear.
            ForEach(visibleControls, id: \.self) { control in
                ControlRow(row: row(for: control), compact: isAway, open: open(control)) {
                    // Starting climate goes by its screen, to pick a temperature first.
                    if control == .climate, model.climate?.isOn != true || model.isDriving {
                        path.append(.climate)
                    } else if control == .chargePort, phase == .noPower {
                        path.append(.charging)
                    } else {
                        Task { await model.perform(control) }
                    }
                }
            }
        }
        .overlay(alignment: .top) { Paper.rule.frame(height: 1) }
    }

    /// Only climate can change while the car is in gear. Sentry shows only nearby, on cars that have it;
    /// out of range it joins the "Last seen" line.
    private var visibleControls: [HomeModel.Control] {
        if model.isDriving { return [.climate] }
        return HomeModel.Control.allCases.filter { control in
            switch control {
            case .sentry: isNearby && model.hasSentry
            // While charging, the panel above stands in for the charge port.
            case .chargePort: phase != .charging
            default: true
            }
        }
    }

    /// What tapping `control`'s row outside its button opens, if it has a screen of its own.
    private func open(_ control: HomeModel.Control) -> (() -> Void)? {
        switch control {
        case .climate where isNearby: { path.append(.climate) }
        case .chargePort where phase == .noPower: { path.append(.charging) }
        default: nil
        }
    }

    @ViewBuilder
    private var footer: some View {
        Group {
            // Also after a first read that failed without finding the car, so it's never a dead end.
            if isAway || (model.reach == .unknown && (!model.isReading || model.isRetrying)) {
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
            } else if model.isDriving, let odometer = model.drive?.odometerMiles {
                Text("Odometer \(DriveText.miles(odometer))")
                    .font(.geist(12))
                    .tracking(0.24)
                    .foregroundStyle(Paper.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if phase != .charging {
                keyNote
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        // The design sits the footer just clear of the home indicator.
        .padding(.bottom, 2)
        .background(Paper.background)
    }

    private var keyNote: some View {
        Text("Bluetooth key · No internet needed")
            .font(.geist(12))
            .tracking(0.24)
            .foregroundStyle(Paper.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var banner: some View {
        if let banner = model.banner {
            BannerView(banner: banner)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .offset(y: bannerDrag < 0 ? bannerDrag : bannerDrag / 4)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { model.banner = nil }
                // Swipe up to clear, like a system notification.
                .gesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { bannerDrag = $0.translation.height }
                        .onEnded { drag in
                            if drag.translation.height < -30 || drag.predictedEndTranslation.height < -80 {
                                model.banner = nil
                                bannerDrag = 0
                            } else {
                                withAnimation(.snappy) { bannerDrag = 0 }
                            }
                        }
                )
                .task(id: banner.id) {
                    // A banner that timed out mid-drag mustn't leave the next one offset.
                    bannerDrag = 0
                    try? await Task.sleep(for: banner.isError ? .seconds(8) : .seconds(4))
                    if model.banner?.id == banner.id { model.banner = nil }
                }
        }
    }

    // MARK: - Rows

    private func row(for control: HomeModel.Control) -> ControlRow.Model {
        let body = model.body
        let isWorking = model.working == control
        let canSend = model.working == nil && isNearby && model.command(for: control) != nil
        switch control {
        case .boot:
            let moving = body?.boot.isMoving == true
            return .init(icon: .drawn(.boot), title: "Boot",
                         state: isWorking ? "Sending…" : body.map { HomeText.state(of: $0.boot) },
                         showsProgress: isWorking || moving,
                         action: HomeText.bootAction(body?.boot), isPrimary: !moving, isEnabled: canSend)
        case .doors:
            return .init(icon: .drawn(.lock), title: "Doors",
                         state: isWorking ? "Sending…" : body.map { $0.isLocked ? "Locked" : "Unlocked" },
                         showsProgress: isWorking,
                         action: body?.isLocked == false ? "Lock" : "Unlock", isEnabled: canSend)
        case .frunk:
            let state: String? = switch body?.frunk {
            case .open?, .ajar?: "Open · Close by hand"
            case let frunk?: HomeText.state(of: frunk)
            case nil: nil
            }
            return .init(icon: .drawn(.frunk), title: "Frunk", state: isWorking ? "Sending…" : state,
                         showsProgress: isWorking || body?.frunk.isMoving == true,
                         action: "Open", isEnabled: canSend)
        case .chargePort:
            let opensDetails = phase == .noPower
            return .init(icon: .drawn(.chargePort), title: "Charge port",
                         state: isWorking ? "Sending…" : ChargePortText.state(model.charge),
                         stateTint: phase == .noPower && !isWorking ? Paper.warning : nil,
                         showsProgress: isWorking,
                         action: ChargePortText.action(model.charge),
                         tint: phase == .plugged ? .charge : phase == .noPower ? .warning : nil,
                         // Details only opens the charging screen.
                         isEnabled: opensDetails ? isNearby : canSend)
        case .sentry:
            let state = model.sentry?.state
            let isAlarm = state?.isAlarm == true
            return .init(icon: .sentry, title: "Sentry",
                         state: isWorking ? "Sending…" : state.map(HomeText.sentryState),
                         stateTint: isAlarm && !isWorking ? Paper.alarm : nil,
                         showsProgress: isWorking,
                         action: state == .off ? "Turn on" : "Turn off",
                         tint: isAlarm ? .alarm : nil, isEnabled: canSend)
        case .climate:
            return .init(icon: .drawn(.climate), title: "Climate",
                         state: isWorking ? "Sending…" : model.climate.map(ClimateText.summary),
                         showsProgress: isWorking,
                         action: model.climate?.isOn != true ? "Start" : model.isDriving ? "Adjust" : "Stop",
                         // Start only opens the climate screen, so it doesn't wait on a reading.
                         isEnabled: model.climate?.isOn == true ? canSend : isNearby)
        }
    }
}

/// One control: icon, name and state, and the button that changes it.
struct ControlRow: View {
    enum Icon {
        case drawn(PaperIcon.Kind)
        /// A ring with a red dot, like the car's camera light.
        case sentry
    }

    struct Model {
        var icon: Icon
        var title: String
        var state: String?
        /// Colours the state and sets it in medium, for an alarm or a charger without power.
        var stateTint: Color?
        var showsProgress = false
        var action: String
        var isPrimary = false
        var tint: PaperButtonStyle.Tint?
        var isEnabled: Bool
    }

    let row: Model
    /// The out-of-range layout: icons greyed like the stale numbers.
    var compact = false
    /// Opens the control's own screen when the row is tapped outside its button.
    var open: (() -> Void)?
    let perform: () -> Void

    /// Nothing moves while the car is out of range, so the bar only shows in range.
    private var showsProgress: Bool { row.showsProgress && !compact }

    var body: some View {
        HStack(spacing: 14) {
            icon
                .foregroundStyle(compact ? Paper.stale : Paper.ink)
            VStack(alignment: .leading, spacing: showsProgress ? 6 : 2) {
                Text(row.title)
                    .font(.geist(16, .medium))
                if let state = row.state {
                    HStack(spacing: 8) {
                        Text(state)
                            .font(.geist(13, row.stateTint == nil ? .regular : .medium))
                            .foregroundStyle(row.stateTint ?? (showsProgress ? Paper.ink : Paper.secondary))
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
                .buttonStyle(PaperButtonStyle(filled: row.isPrimary && !compact, tint: compact ? nil : row.tint))
                .disabled(!row.isEnabled)
                .accessibilityLabel("\(row.action) \(row.title.lowercased())")
        }
        .frame(minHeight: 64)
        .overlay(alignment: .bottom) { Paper.rule.frame(height: 1) }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var icon: some View {
        switch row.icon {
        case .drawn(let kind):
            PaperIcon(kind: kind).drawn()
        case .sentry:
            Image(systemName: "smallcircle.filled.circle")
                .symbolRenderingMode(.palette)
                .foregroundStyle(Paper.danger, compact ? Paper.stale : Paper.ink)
                .font(.system(size: 20, weight: .light))
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
        }
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
        case .doors?, .sentry?: .lock
        case .frunk?: .frunk
        case .chargePort?: .chargePort
        case .climate?: .climate
        case nil: .warning
        }
    }
}

#Preview {
    HomeView(store: CarStore())
}
