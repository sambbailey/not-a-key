import SwiftUI

/// The Action Button hint, which car this key is for, and removing the key.
struct SettingsView: View {
    let store: CarStore
    let model: HomeModel

    @State private var confirmingRemove = false
    @State private var removeError: String?

    private let keyStore = KeyStore()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                settingsSection("Action Button") {
                    row("Shortcut", value: "Toggle Boot", height: 64, emphasised: true)
                    Text("Set it in iPhone Settings › Action Button › Shortcut.")
                        .font(.geist(13))
                        .foregroundStyle(Paper.secondary)
                        .lineSpacing(4)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .bottom) { Paper.rule.frame(height: 1) }
                }
                settingsSection("Key") {
                    row("Car", value: store.vin.flatMap(VIN.modelName) ?? "Tesla")
                    row("VIN", value: store.vin ?? "–")
                    row("Role", value: "Driver")
                }
            }
            .padding(.horizontal, 24)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if let removeError {
                    Text(removeError)
                        .font(.geist(13))
                        .foregroundStyle(Paper.danger)
                }
                Button("Remove key from this phone", role: .destructive) { confirmingRemove = true }
                    .buttonStyle(RemoveButtonStyle())
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
            .background(Paper.background)
        }
        .background(Paper.background)
        .foregroundStyle(Paper.ink)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Paper.background, for: .navigationBar)
        .confirmationDialog("Remove this phone's key?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove key and re-pair", role: .destructive, action: removeKey)
        } message: {
            Text("This deletes the phone's car key. You'll need your key card to pair again.")
        }
    }

    private func settingsSection(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.geist(13))
                .foregroundStyle(Paper.secondary)
            VStack(spacing: 0, content: rows)
                .overlay(alignment: .top) { Paper.rule.frame(height: 1) }
        }
        .padding(.top, 32)
    }

    private func row(_ label: String, value: String, height: CGFloat = 56, emphasised: Bool = false) -> some View {
        HStack(spacing: 14) {
            Text(label)
                .font(.geist(16, emphasised ? .medium : .regular))
            Spacer()
            Text(value)
                .font(.geist(15))
                .foregroundStyle(Paper.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(minHeight: height)
        .overlay(alignment: .bottom) { Paper.rule.frame(height: 1) }
        .accessibilityElement(children: .combine)
    }

    private func removeKey() {
        model.stop()
        do {
            try keyStore.delete()
            store.isPaired = false
        } catch {
            removeError = "Couldn't delete this phone's car key"
        }
    }
}

private struct RemoveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.geist(15, .medium))
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(Paper.danger)
            .overlay { Capsule().strokeBorder(Paper.danger, lineWidth: 1) }
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
