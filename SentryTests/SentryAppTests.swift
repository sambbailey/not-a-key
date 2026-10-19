import Testing
@testable import Sentry

// Placeholder so the SentryTests bundle has a binary; real suites arrive with the app features.
@Test func appModuleLoads() {
    _ = SentryApp.self
}
