import SwiftUI
import TeslaKit

/// A plain screen for checking the key works at the car. Replaced in Plan 2.
struct DebugHomeView: View {
    let store: CarStore

    @State private var snapshot: VehicleSnapshot?
    @State private var lastResult: String?
    @State private var lastError: String?
    @State private var isWorking = false
    @State private var confirmingRepair = false

    private let keyStore = KeyStore()

    private struct KeyUnavailable: Error {}

    var body: some View {
        NavigationStack {
            Form {
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
                    }
                }

                Section {
                    Button("Re-pair", role: .destructive) { confirmingRepair = true }
                        .disabled(isWorking)
                }
            }
            .navigationTitle("Sentry")
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

    private func toggleBoot() async {
        await run { service in
            lastResult = switch try await service.toggleBoot() {
            case .opening: "Opening boot"
            case .closing: "Closing boot"
            case .moving: "Moving boot"
            }
        }
    }

    private func run(_ work: (VehicleService) async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        lastResult = nil
        lastError = nil
        do {
            try await work(try service())
        } catch is KeyUnavailable {
            lastError = "This phone's car key is missing or can't be read. Tap Re-pair to set it up again."
        } catch {
            lastError = plainMessage(for: error)
        }
    }

    private func repair() {
        do {
            try keyStore.delete()
            store.isPaired = false
        } catch {
            lastError = "Couldn't delete the key: \(plainMessage(for: error))"
        }
    }
}
