import SwiftUI
import TeslaKit

/// A plain screen for checking the key works at the car. Replaced in Plan 2.
struct DebugHomeView: View {
    let store: CarStore

    @Environment(\.scenePhase) private var scenePhase
    @State private var charge: ChargeReading? = ChargeStore().last
    /// Whether `charge` was read since the app last came to the foreground.
    @State private var chargeIsFresh = false
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
            .task { await refreshCharge() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await refreshCharge() } }
                if phase == .background { chargeIsFresh = false }
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

    /// Wakes the car if needed and reads charge. Skipped while another request is running,
    /// since the car takes one connection at a time.
    private func refreshCharge() async {
        guard !isWorking else { return }
        await run { service in
            charge = try await service.refreshCharge(into: chargeStore)
            chargeIsFresh = true
        }
    }

    private func toggleBoot() async {
        await run { service in
            lastResult = IntentMessages.success(try await service.toggleBoot())
        }
    }

    private func run(_ work: (VehicleService) async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        lastResult = nil
        lastError = nil
        lastErrorDetail = nil
        do {
            try await work(try service())
        } catch is KeyUnavailable {
            lastError = "This phone's car key is missing or can't be read. Tap Re-pair to set it up again."
        } catch {
            lastError = IntentMessages.failure(error)
            // The friendly copy folds many causes into one; the raw error tells them apart at the car.
            lastErrorDetail = String(describing: error)
        }
    }

    private func repair() {
        do {
            try keyStore.delete()
            store.isPaired = false
        } catch {
            lastError = "Couldn't delete this phone's car key"
            lastErrorDetail = String(describing: error)
        }
    }
}
