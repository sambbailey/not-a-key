import Foundation
import Observation
import os
import TeslaKit

private let log = Logger(subsystem: "com.nevelen.notakey", category: "home")

/// What the home screen shows and does: reads the car when asked, sends one command at a time,
/// and remembers the last readings for when the car is out of range.
@Observable @MainActor
final class HomeModel {
    enum Reach: Equatable {
        case unknown, nearby, notInRange
    }

    enum Control: Hashable, CaseIterable {
        case boot, doors, sentry, frunk, chargePort, climate
    }

    struct Banner: Equatable, Identifiable {
        let id = UUID()
        var message: String
        /// The raw error under the friendly copy, for telling causes apart at the car.
        var detail: String?
        var isError: Bool
        var control: Control?
    }

    /// A charging setting stepped with − and +.
    enum ChargeSetting: Hashable {
        case limit, amps
    }

    /// The phone's car key is missing or can't be read; only re-pairing fixes it.
    struct KeyUnavailable: Error {}

    private(set) var charge: ChargeReading?
    private(set) var body: BodyReading?
    private(set) var reach = Reach.unknown
    /// Cabin climate from the last read, updated as this app changes it.
    private(set) var climate: ClimateSnapshot? {
        didSet { if let climate { store.save(climate) } }
    }
    /// Sentry Mode from the last read, remembered for the out-of-range line.
    private(set) var sentry: SentrySnapshot? {
        didSet {
            if let sentry { store.save(sentry) }
            // The car doesn't say when the alarm went off, so it's timed from the first read showing it.
            if sentry?.state?.isAlarm == true {
                if alarmSince == nil { alarmSince = now() }
            } else {
                alarmSince = nil
            }
        }
    }
    /// When a read first showed the Sentry alarm, while it lasts.
    private(set) var alarmSince: Date?
    /// Gear, speed and route from the last read. Not kept across launches, so an old drive never shows.
    private(set) var drive: DriveSnapshot?
    /// The control whose command is in flight. Only one runs at a time; the car takes one connection.
    private(set) var working: Control?
    private(set) var keyIsMissing = false
    #if DEBUG
    /// Shows sample readings and never connects; for App Store screenshots.
    private var isDemo = false
    #endif
    /// Whether Face ID is up before an unlock; a second tap meanwhile is ignored.
    private(set) var isConfirmingUnlock = false
    /// Whether "Try again" is looking for the car.
    private(set) var isRetrying = false
    var banner: Banner?

    /// How long a normal read looks for the car, and how long "Try again" does.
    static let scanLimit: Duration = .seconds(10)
    static let retryLimit: Duration = .seconds(5)

    /// How often drive state is read while the car is driven, over one held connection.
    static let drivingRefresh: Duration = .milliseconds(250)
    /// Charge and climate are read again on every this many drive reads, about every 10 seconds.
    static let drivingStatusEvery = 40
    /// How often a parked car nearby is checked for being put in gear, over one held connection.
    static let parkedRefresh: Duration = .seconds(2)

    /// The reads that wait for the car to be put in gear, then keep it live while driving. They
    /// hold the car's connection; commands stop them first.
    private var driveWatch: Task<Void, Never>?
    private let drivingRefresh: Duration
    private let parkedRefresh: Duration

    /// Values stepped with − and + but not yet confirmed by the car, shown in place of its reading.
    private(set) var pending: [ChargeSetting: Int] = [:]
    /// The wait before each stepped value is sent. Dropped once the send starts, so a later tap
    /// can't cancel a command already on its way.
    private var settingTasks: [ChargeSetting: Task<Void, Never>] = [:]
    /// How long after the last tap of − or + the value is sent.
    static let settingSettle: Duration = .seconds(3)
    private let settingSettle: Duration
    /// How long after a charging setting is sent the car is read again, for its new time to the limit.
    static let settingReread: Duration = .seconds(10)
    private var rereadTask: Task<Void, Never>?

    /// The read in flight. It runs alongside the controls; they cancel it before connecting.
    private var readTask: Task<Void, Never>?
    /// Whether `readTask` is a full read, rather than a wait to see a moving boot or frunk settle.
    private var readIsFull = false

    private let store: ChargeStore
    /// Makes a service whose connect gives up looking for the car after the given time.
    private let makeService: (Duration) throws -> VehicleService
    private let now: @Sendable () -> Date
    /// Asks the owner to confirm before the doors unlock; false keeps them locked.
    private let confirmUnlock: () async -> Bool

    init(store: ChargeStore = ChargeStore(), now: @escaping @Sendable () -> Date = Date.init,
         drivingRefresh: Duration = HomeModel.drivingRefresh,
         parkedRefresh: Duration = HomeModel.parkedRefresh,
         settingSettle: Duration = HomeModel.settingSettle,
         confirmUnlock: @escaping () async -> Bool = { true },
         makeService: @escaping (_ scanLimit: Duration) throws -> VehicleService) {
        self.store = store
        self.now = now
        self.drivingRefresh = drivingRefresh
        self.parkedRefresh = parkedRefresh
        self.settingSettle = settingSettle
        self.confirmUnlock = confirmUnlock
        self.makeService = makeService
        charge = store.last
        body = store.lastBody
        climate = store.lastClimate
        sentry = store.lastSentry
    }

    convenience init(car: CarStore, keyStore: KeyStore = KeyStore()) {
        self.init(confirmUnlock: {
            guard car.faceIDForUnlock else { return true }
            return await OwnerCheck.confirm("Unlock your car")
        }) { scanLimit in
            let stored: KeyAgreementKey?
            do {
                stored = try keyStore.load()
            } catch let failure as KeyStore.Failure {
                // A keychain error is passing (e.g. before first unlock); anything else means
                // the stored key is broken and only re-pairing fixes it.
                guard case .keychain = failure else { throw KeyUnavailable() }
                throw failure
            }
            guard let vin = car.vin, let key = stored else { throw KeyUnavailable() }
            return VehicleService(vin: vin, key: key, connect: {
                try await BLETransport.connect(vin: $0, scanTimeout: scanLimit)
            })
        }
    }

    var isReading: Bool { readTask != nil && readIsFull }

    /// Whether the car has Sentry Mode and has said what it's doing.
    var hasSentry: Bool { sentry?.state != nil && sentry?.isAvailable != false }

    /// Sentry has been set off, and the car is in range to say so.
    var isAlarmed: Bool { reach == .nearby && sentry?.state?.isAlarm == true }

    /// In Drive or Reverse at the last read, with the car still in range.
    var isDriving: Bool { reach == .nearby && drive?.isDriving == true }

    /// Stops any read in flight and the drive watch, e.g. before the key is removed or
    /// when the app goes to the background.
    func stop() {
        readTask?.cancel()
        rereadTask?.cancel()
        driveWatch?.cancel()
        driveWatch = nil
    }

    /// The command a tap on `control` sends now, or nil if it can't do anything from this state.
    func command(for control: Control) -> VehicleCommand? {
        // Only climate can change while the car is in gear.
        if isDriving, control != .climate { return nil }
        return switch control {
        case .boot: .moveTrunk
        case .doors: body.map { $0.isLocked ? .unlock : .lock }
        case .sentry:
            switch sentry?.state {
            case nil: nil
            case .off?: .setSentryMode(true)
            case _?: .setSentryMode(false)
            }
        // Tesla has no frunk-close command; an open frunk is shut by hand.
        case .frunk: body?.frunk == .closed ? .openFrunk : nil
        case .chargePort:
            switch charge?.phase {
            case nil: nil
            case .charging?: .stopCharging
            case .plugged?: .startCharging
            // Nothing to send; the row opens the charging screen.
            case .noPower?: nil
            case .idle?: charge?.isPortOpen == true ? .closeChargePort : .openChargePort
            }
        case .climate: climate?.isOn == true ? .climateOff : .climateOn
        }
    }

    /// The value `setting` shows: the one being stepped to, or else the car's.
    func value(of setting: ChargeSetting) -> Int? {
        pending[setting] ?? carValue(of: setting)
    }

    /// The values `setting` can take; nil until the car has said.
    func range(of setting: ChargeSetting) -> ClosedRange<Int>? {
        switch setting {
        case .limit: charge?.chargeLimitRange ?? 50...100
        case .amps: charge?.currentRequestMax.map { 1...max(1, $0) }
        }
    }

    /// Moves `setting` one step; see `set(_:to:)`.
    func step(_ setting: ChargeSetting, by delta: Int) {
        guard let current = value(of: setting) else { return }
        set(setting, to: current + delta)
    }

    /// Moves `setting` to `value`, kept within its range, at once on screen, and sends it
    /// `settingSettle` after the last change. Only the latest value is sent.
    func set(_ setting: ChargeSetting, to value: Int) {
        guard let current = self.value(of: setting), let range = range(of: setting) else { return }
        let target = min(max(value, range.lowerBound), range.upperBound)
        guard target != current else { return }
        pending[setting] = target
        settingTasks[setting]?.cancel()
        settingTasks[setting] = Task {
            do {
                try await Task.sleep(for: settingSettle)
                while working != nil { try await Task.sleep(for: .milliseconds(200)) }
            } catch {
                return  // Stepped again; that step's task sends the newer value.
            }
            settingTasks[setting] = nil
            if target != carValue(of: setting) {
                await send(setting == .limit ? .setChargeLimit(percent: target) : .setChargingAmps(target),
                           for: .chargePort)
                // The car is slow to work out its new time to the limit; read it again once it has.
                if carValue(of: setting) == target { rereadSoon() }
            }
            // A step during the send keeps its own value pending.
            if pending[setting] == target { pending[setting] = nil }
        }
    }

    private func rereadSoon() {
        rereadTask?.cancel()
        rereadTask = Task {
            do { try await Task.sleep(for: Self.settingReread) } catch { return }
            guard reach == .nearby else { return }
            await refresh()
        }
    }

    private func carValue(of setting: ChargeSetting) -> Int? {
        switch setting {
        case .limit: charge?.chargeLimit
        case .amps: charge?.currentRequest
        }
    }

    /// Wakes the car if needed and reads lock, closures and charge, or waits for the read in flight.
    /// Skipped while a command runs, and while driving, when the car is already read live.
    /// While parked, the watch for the car being put in gear makes way and starts again after.
    func refresh() async {
        await refresh(scanLimit: Self.scanLimit)
    }

    /// Looks for the car again for up to `retryLimit`, then reads it if found. Counts as
    /// retrying for at least that long, so a quick failure doesn't flash past.
    func retry() async {
        guard !isRetrying else { return }
        isRetrying = true
        defer { isRetrying = false }
        let started = ContinuousClock.now
        await refresh(scanLimit: Self.retryLimit)
        if reach != .nearby {
            try? await Task.sleep(until: started + Self.retryLimit)
        }
    }

    private func refresh(scanLimit: Duration) async {
        #if DEBUG
        if isDemo { return }
        #endif
        if !isDriving, working == nil { _ = await stopDriveWatch() }
        if readTask == nil, working == nil, driveWatch == nil {
            readIsFull = true
            readTask = Task {
                defer { readTask = nil }
                await read(scanLimit: scanLimit)
            }
        }
        await readTask?.value
    }

    func perform(_ control: Control) async {
        guard let command = command(for: control), working == nil, !isConfirmingUnlock else { return }
        if command == .unlock {
            isConfirmingUnlock = true
            let confirmed = await confirmUnlock()
            isConfirmingUnlock = false
            guard confirmed else { return }
        }
        await send(command, for: control)
    }

    /// Sends `command` on behalf of `control`, then shows what changed. Ignored while another
    /// command runs.
    func send(_ command: VehicleCommand, for control: Control) async {
        // Checked before any suspension, so a double tap can't start two connections.
        guard working == nil else { return }
        working = control
        let interruptedFullRead = await stopRead()
        let interruptedWatch = await stopDriveWatch()
        do {
            let result = try await makeService(Self.scanLimit).send(command)
            reach = .nearby
            keyIsMissing = false
            apply(BodyReading(result.after, readAt: now()))
            applyClimate(after: command)
            if let snapshot = result.sentry {
                sentry = snapshot
            } else if case .setSentryMode(let on) = command, var sentry {
                sentry.state = on ? .armed : .off
                self.sentry = sentry
            }
            let hadCable = charge?.hasCable == true
            if let snapshot = result.charge {
                // The car can take a moment to report a change it has accepted, so what the
                // command set wins over the read until the next one.
                var reading = ChargeReading(snapshot, readAt: now())
                reading.apply(command)
                reading.keepTimePending(from: charge)
                charge = reading
                store.save(reading)
            } else if var charge {
                charge.apply(command)
                self.charge = charge
                store.save(charge)
            }
            let message = switch command {
            case .moveTrunk: IntentMessages.success(BootToggleOutcome(bootBefore: result.before.rearTrunk))
            case .openChargePort where hadCable: IntentMessages.cableUnlocked
            default: IntentMessages.success(command)
            }
            banner = Banner(message: message, isError: false, control: control)
        } catch {
            report(error)
        }
        working = nil
        // The command took the car's connection mid-read; read again now it's free.
        if interruptedFullRead {
            Task { await refresh() }
        } else if interruptedWatch {
            watchDrive()
        } else {
            watchMovingClosures()
        }
    }

    private func read(scanLimit: Duration) async {
        do {
            let status = try await makeService(scanLimit).refreshStatus(into: store, now: now)
            var reading = status.charge
            reading.keepTimePending(from: charge)
            if reading != status.charge { store.save(reading) }
            charge = reading
            body = status.body
            if let climate = status.climate { self.climate = climate }
            drive = status.drive
            if let sentry = status.sentry { self.sentry = sentry }
            reach = .nearby
            keyIsMissing = false
            watchDrive()
        } catch {
            // Cancelled to make way for a command; that command reports its own outcome.
            guard !Task.isCancelled else { return }
            report(error)
        }
    }

    /// Cancels the read in flight and waits for it to let go of the car.
    /// Returns whether a full read was interrupted, so it can be started again afterwards.
    private func stopRead() async -> Bool {
        guard let readTask else { return false }
        let wasFull = readIsFull
        readTask.cancel()
        await readTask.value
        return wasFull
    }

    /// While the boot or frunk is moving, reads them again every few seconds until they stop.
    private func watchMovingClosures(attempt: Int = 0) {
        guard readTask == nil, working == nil, attempt < 5,
              let body, body.boot.isMoving || body.frunk.isMoving else { return }
        readIsFull = false
        readTask = Task {
            try? await Task.sleep(for: .seconds(3))
            let snapshot = Task.isCancelled ? nil : try? await makeService(Self.scanLimit).snapshot()
            readTask = nil
            guard !Task.isCancelled, let snapshot else { return }
            apply(BodyReading(snapshot, readAt: now()))
            watchMovingClosures(attempt: attempt + 1)
        }
    }

    /// Waits for the parked car to be put in gear, then keeps speed, power and gear live while
    /// it's driven. Once it's out of gear or the connection drops, reads the car in full again,
    /// which shows the parked car or the error.
    private func watchDrive() {
        guard driveWatch == nil, reach == .nearby else { return }
        driveWatch = Task {
            do {
                let service = try makeService(Self.scanLimit)
                if !isDriving {
                    let drive = try await service.waitForDrive(every: parkedRefresh) { [weak self] snapshot in
                        await self?.applyParked(snapshot)
                    }
                    try Task.checkCancellation()
                    self.drive = drive
                }
                try await service.watchDrive(every: drivingRefresh,
                                                                 statusEvery: Self.drivingStatusEvery) { [weak self] update in
                    await self?.apply(update)
                }
            } catch {
                log.error("Live drive reads stopped: \(String(describing: error), privacy: .public)")
            }
            guard !Task.isCancelled else { return }
            driveWatch = nil
            await refresh()
        }
    }

    /// Cancels the live reads and waits for them to let go of the car.
    /// Returns whether they were running, so they can be started again afterwards.
    private func stopDriveWatch() async -> Bool {
        guard let driveWatch else { return false }
        driveWatch.cancel()
        self.driveWatch = nil
        await driveWatch.value
        return true
    }

    private func applyParked(_ snapshot: VehicleSnapshot) {
        guard driveWatch != nil else { return }
        apply(BodyReading(snapshot, readAt: now()))
    }

    private func apply(_ update: VehicleService.DriveUpdate) {
        guard driveWatch != nil else { return }
        drive = update.drive
        if let snapshot = update.charge {
            var reading = ChargeReading(snapshot, readAt: now())
            reading.keepTimePending(from: charge)
            charge = reading
            store.save(reading)
        }
        if let climate = update.climate { self.climate = climate }
    }

    /// Shows the climate a successful `command` leads to, until the next read confirms it.
    private func applyClimate(after command: VehicleCommand) {
        var climate = climate ?? ClimateSnapshot(isOn: false)
        switch command {
        case .climateOn: climate.isOn = true
        case .climateOff:
            climate.isOn = false
            climate.keeperMode = .off
        case .setTemperature(let celsius): climate.setCelsius = celsius
        case .setDefrost(let on):
            climate.isDefrosting = on
            // Defrost runs the climate at full power, so it switches climate on too.
            if on { climate.isOn = true }
        case .climateKeeper(let mode):
            climate.keeperMode = mode
            // Keep, Dog and Camp all run the climate.
            if mode != .off { climate.isOn = true }
        default: return
        }
        self.climate = climate
    }

    private func apply(_ reading: BodyReading) {
        body = reading
        store.save(reading)
    }

    private func report(_ error: any Error) {
        log.error("Home: \(String(describing: error), privacy: .public)")
        switch error {
        case VehicleError.notInRange:
            reach = .notInRange
        case is KeyUnavailable:
            keyIsMissing = true
            banner = Banner(message: "This phone's car key is missing or can't be read. Remove it in Settings and pair again.",
                            isError: true)
        default:
            banner = Banner(message: IntentMessages.failure(error), detail: String(describing: error), isError: true)
        }
    }
}

#if DEBUG
extension HomeModel {
    /// The charging states the demo can show.
    enum DemoCharge {
        case plugged, charging, supercharging, noPower
    }

    /// Sample readings for App Store screenshots: a car nearby, being driven with `driving`, or
    /// plugged in with `charging`.
    static func demo(driving: Bool = false, charging: DemoCharge? = nil, alarm: Bool = false) -> HomeModel {
        let suite = "com.nevelen.notakey.demo"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = HomeModel(store: ChargeStore(defaults: defaults)) { _ in throw CancellationError() }
        model.isDemo = true
        model.reach = .nearby
        model.charge = switch charging {
        case nil:
            ChargeReading(batteryLevel: 78, rangeMiles: 241, isCharging: false, isPortOpen: false, readAt: .now)
        case .plugged?:
            ChargeReading(batteryLevel: 82, rangeMiles: 254, isCharging: false, isPortOpen: true,
                          chargingState: .stopped, chargeLimit: 90, chargeLimitRange: 50...100, isScheduled: true,
                          scheduledStart: Calendar.current.date(bySettingHour: 0, minute: 30, second: 0,
                                                                of: .now.addingTimeInterval(86_400)),
                          readAt: .now)
        case .charging?:
            ChargeReading(batteryLevel: 82, rangeMiles: 254, isCharging: true, chargerPowerKW: 7, isPortOpen: true,
                          chargingState: .charging, chargeLimit: 90, chargeLimitRange: 50...100, minutesToLimit: 40,
                          chargeRateMph: 28, isFastCharger: false, energyAddedKWh: 14.2, milesAdded: 52,
                          chargerAmps: 32, chargerVolts: 230, readAt: .now)
        case .noPower?:
            ChargeReading(batteryLevel: 27, rangeMiles: 83, isCharging: false, chargerPowerKW: 0, isPortOpen: true,
                          chargingState: .noPower, chargeLimit: 80, chargeLimitRange: 50...100, isFastCharger: false,
                          currentRequest: 16, currentRequestMax: 32, readAt: .now)
        case .supercharging?:
            ChargeReading(batteryLevel: 34, rangeMiles: 105, isCharging: true, chargerPowerKW: 145, isPortOpen: true,
                          chargingState: .charging, chargeLimit: 80, chargeLimitRange: 50...100, minutesToLimit: 18,
                          chargeRateMph: 590, isFastCharger: true, energyAddedKWh: 17.5, milesAdded: 62,
                          chargerAmps: 360, chargerVolts: 402, readAt: .now)
        }
        model.body = BodyReading(isLocked: true, boot: .closed, frunk: .closed, readAt: .now)
        model.sentry = SentrySnapshot(state: alarm ? .panic : .armed)
        if alarm { model.alarmSince = .now - 120 }
        model.climate = ClimateSnapshot(isOn: !driving, insideCelsius: 19, outsideCelsius: 9, setCelsius: 21)
        if driving {
            model.drive = DriveSnapshot(gear: .drive, speedMph: 42, powerKW: 18, odometerMiles: 3_412,
                                        route: .init(destination: "Home", minutesToArrival: 14, milesToArrival: 8.6,
                                                     batteryAtArrival: 74))
        }
        return model
    }
}
#endif
