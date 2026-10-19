import AppIntents

/// Makes Toggle Boot available to Siri, Shortcuts and the Action Button with no setup.
struct SentryShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleBootIntent(),
            phrases: [
                "Toggle boot with \(.applicationName)",
                "Open boot with \(.applicationName)",
            ],
            shortTitle: "Toggle Boot",
            systemImageName: "car.rear"
        )
    }
}
