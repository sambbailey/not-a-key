import SwiftUI

@main
struct SentryApp: App {
    @State private var store = CarStore()

    var body: some Scene {
        WindowGroup {
            if store.isPaired && store.vin != nil {
                DebugHomeView(store: store)
            } else {
                OnboardingView(store: store)
            }
        }
    }
}
