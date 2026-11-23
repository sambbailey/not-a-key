import SwiftUI

@main
struct NotAKeyApp: App {
    @State private var store = CarStore()
    /// The simulated car's store; demo mode is on while it counts as paired.
    @State private var demo = CarStore.demo()
    /// Keeps setup on screen after pairing, until the owner leaves its final screen.
    @State private var isSettingUp = false

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let demo = ProcessInfo.processInfo.environment["DEMO"] {
                DemoScreen(name: demo)
            } else {
                main
            }
            #else
            main
            #endif
        }
    }

    @ViewBuilder private var main: some View {
        if demo.isPaired {
            HomeView(store: demo)
                .safeAreaInset(edge: .top, spacing: 0) { DemoBanner(onExit: demo.endDemo) }
        } else if store.isPaired && store.vin != nil && !isSettingUp {
            HomeView(store: store)
        } else {
            OnboardingView(store: store, onTryDemo: { Task { await demo.startDemo() } }) { isSettingUp = false }
                .onAppear { isSettingUp = true }
        }
    }
}
