import SwiftUI

/// First-run setup: the owner enters their VIN, then approves this phone on the car.
struct OnboardingView: View {
    @State private var model: PairingModel
    @State private var vinText: String

    init(store: CarStore) {
        _model = State(initialValue: PairingModel(store: store))
        _vinText = State(initialValue: store.vin ?? "")
    }

    private var vinIsValid: Bool { VIN.normalize(vinText) != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("VIN", text: $vinText)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                        .disabled(model.isWorking)
                } header: {
                    Text("Your car's VIN")
                } footer: {
                    if !vinText.isEmpty && !vinIsValid {
                        Text("A VIN is 17 letters and numbers, and never contains I, O or Q.")
                            .foregroundStyle(.red)
                    } else {
                        Text("Find it on the car's screen under Controls > Software.")
                    }
                }

                Section {
                    Button("Pair") {
                        Task { await model.start(vin: vinText) }
                    }
                    .disabled(!vinIsValid || model.isWorking)
                }

                if model.phase != .enterVIN {
                    Section {
                        PhaseRow(phase: model.phase)
                    }
                }
            }
            .navigationTitle("Set up Not a Key")
        }
    }
}

private struct PhaseRow: View {
    let phase: PairingModel.Phase

    var body: some View {
        switch phase {
        case .enterVIN:
            EmptyView()
        case .connecting:
            Label {
                Text("Looking for your car. Stay close to it with Bluetooth on.")
            } icon: {
                ProgressView()
            }
        case .tapCard:
            Label {
                Text("Tap your key card on the centre console, then confirm on the car's screen.")
            } icon: {
                ProgressView()
            }
        case .done:
            Label("Paired", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(message)
                    Text("Tap Pair to try again.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .foregroundStyle(.red)
        }
    }
}
