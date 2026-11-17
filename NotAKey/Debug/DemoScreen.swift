#if DEBUG
import SwiftUI

/// One screen filled with sample data, picked by the `DEMO` launch environment variable;
/// for App Store screenshots. Never connects to a car.
struct DemoScreen: View {
    let name: String
    /// Kept apart from the real car's settings.
    @State private var store = CarStore(defaults: UserDefaults(suiteName: "com.nevelen.notakey.demo")!)

    var body: some View {
        switch name {
        case "climate": HomeView(store: store, model: .demo(), path: [.climate])
        case "driving": HomeView(store: store, model: .demo(driving: true))
        case "nopower": HomeView(store: store, model: .demo(charging: .noPower))
        case "nopower-details": HomeView(store: store, model: .demo(charging: .noPower), path: [.charging])
        case "alarm": HomeView(store: store, model: .demo(alarm: true))
        case "plugged": HomeView(store: store, model: .demo(charging: .plugged))
        case "charging": HomeView(store: store, model: .demo(charging: .charging))
        case "charging-details": HomeView(store: store, model: .demo(charging: .charging), path: [.charging])
        case "supercharging": HomeView(store: store, model: .demo(charging: .supercharging), path: [.charging])
        case "welcome": OnboardingView(store: store, demo: .welcome)
        case "vin": OnboardingView(store: store, demo: .vin)
        case "done": OnboardingView(store: store, demo: .done)
        default: HomeView(store: store, model: .demo())
        }
    }
}
#endif
