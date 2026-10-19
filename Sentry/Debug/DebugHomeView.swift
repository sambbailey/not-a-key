import SwiftUI
import TeslaKit

/// A plain screen for checking the key works at the car. Replaced in Plan 2.
struct DebugHomeView: View {
    let store: CarStore

    @Environment(\.scenePhase) private var scenePhase
    @State private var charge: ChargeReading?
    /// Whether `charge` was read since the app last came to the foreground.
    @State private var chargeIsFresh = false
    /// The charge read in flight. It runs alongside the buttons; they cancel it before connecting.
    @State private var chargeTask: Task<Void, Never>?
    @State private var wasInBackground = false
    @State private var snapshot: VehicleSnapshot?
    @State private var lastResult: String?
    @State private var lastError: String?
    @State private var lastErrorDetail: String?
    @State private var isWorking = false
    @State private var confirmingRepair = false

    private let keyStore = KeyStore()
    private let chargeStore = ChargeStore()

    private struct KeyUnavailable: Error {}

    var body: some View {
        NavigationStack {
            Form {
                Section("Battery") {
                    LabeledContent("Charge", value: charge.map { $0.levelText + ($0.isCharging ? ", charging" : "") } ?? "-")
                    LabeledContent("Range", value: charge?.rangeText ?? "-")
                    if chargeTask != nil {
                        ProgressView()
                    }
                    if let charge, !chargeIsFresh {
                        TimelineView(.everyMinute) { _ in
                            Text("Updated \(charge.readAt, format: .relative(presentation: .named))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Car") {
                    LabeledContent("VIN", value: store.vin ?? "-")
                    LabeledContent("Locked", value: snapshot.map { $0.isLocked ? "Yes" : "No" } ?? "-")
                    LabeledContent("Boot", value: snapshot.map { "\($0.rearTrunk)" } ?? "-")
                    LabeledContent("Frunk", value: snapshot.map { "\($0.frontTrunk)" } ?? "-")
                    LabeledContent("Asleep", value: snapshot.map { $0.isAsleep ? "Yes" : "No" } ?? "-")
                }

                Section {
                    Button("Refresh") { Task { await refresh() } }
                    Button("Toggle Boot") { Task { await toggleBoot() } }
                    if isWorking {
                        ProgressView()
                    }
                }
                .disabled(isWorking)

                if let lastResult {
                    Section("Last result") { Text(lastResult) }
                }
                if let lastError {
                    Section("Last error") {
                        Text(lastError).foregroundStyle(.red)
                        if let lastErrorDetail {
                            Text(lastErrorDetail)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }

                Section {
                    Button("Re-pair", role: .destructive) { confirmingRepair = true }
                        .disabled(isWorking)
                }
            }
            .navigationTitle("Not a Key")
            .refreshable { await refreshCharge() }
            .task {
                if charge == nil { charge = chargeStore.last }
                await refreshCharge()
            }
            .onChange(of: scenePhase) { _, phase in
                // Only a real return to the foreground reads again, not Control Centre or a Face ID sheet.
                switch phase {
                case .background:
                    wasInBackground = true
                    chargeIsFresh = false
                case .active where wasInBackground:
                    wasInBackground = false
                    Task { await refreshCharge() }
                default:
                    break
                }
            }
            .confirmationDialog("Re-pair this phone?", isPresented: $confirmingRepair, titleVisibility: .visible) {
                Button("Delete key and re-pair", role: .destructive, action: repair)
            } message: {
                Text("This deletes the phone's car key. You'll need your key card to pair again.")
            }
        }
    }

    private func service() throws -> VehicleService {
        guard let vin = store.vin, let key = try? keyStore.load() else { throw KeyUnavailable() }
        return VehicleService(vin: vin, key: key)
    }

    private func refresh() async {
        await run { service in
            snapshot = try await service.snapshot()
            lastResult = "Refreshed"
        }
    }

    /// Wakes the car if needed and reads charge, or waits for the read already in flight.
    /// Skipped while a button's request runs, since the car takes one connection at a time.
    private func refreshCharge() async {
        if chargeTask == nil, !isWorking {
            chargeTask = Task {
                await readCharge()
                chargeTask = nil
            }
        }
        await chargeTask?.value
    }

    private func readCharge() async {
        do {
            charge = try await service().refreshCharge(into: chargeStore)
            chargeIsFresh = true
        } catch {
            // Cancelled to make way for a button; that request reports its own outcome.
            guard !Task.isCancelled else { return }
            report(error)
        }
    }

    /// Cancels the charge read in flight and waits for it to let go of the car.
    private func stopChargeRead() async {
        guard let chargeTask else { return }
        chargeTask.cancel()
        await chargeTask.value
    }

    private func toggleBoot() async {
        await run { service in
            lastResult = IntentMessages.success(try await service.toggleBoot())
        }
    }

    private func run(_ work: (VehicleService) async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        await stopChargeRead()
        lastResult = nil
        lastError = nil
        lastErrorDetail = nil
        do {
            try await work(try service())
        } catch {
            report(error)
        }
    }

    private func report(_ error: any Error) {
        switch error {
        case is KeyUnavailable:
            lastError = "This phone's car key is missing or can't be read. Tap Re-pair to set it up again."
            lastErrorDetail = nil
        default:
            lastError = IntentMessages.failure(error)
            // The friendly copy folds many causes into one; the raw error tells them apart at the car.
            lastErrorDetail = String(describing: error)
        }
    }

    private func repair() {
        chargeTask?.cancel()
        do {
            try keyStore.delete()
            store.isPaired = false
        } catch {
            lastError = "Couldn't delete this phone's car key"
            lastErrorDetail = String(describing: error)
        }
    }
}
