import Foundation

/// Sentry Mode as infotainment reports it in closures state.
public struct SentrySnapshot: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case off, idle, armed, aware, panic, quiet

        /// On and watching: Armed, Idle or Quiet.
        public var isArmed: Bool { self == .armed || self == .idle || self == .quiet }
        /// Something set it off: Aware or Panic.
        public var isAlarm: Bool { self == .aware || self == .panic }
    }

    /// Nil if the car didn't say.
    public var state: State?
    /// False on cars without Sentry Mode; nil if the car didn't say.
    public var isAvailable: Bool?

    public init(state: State?, isAvailable: Bool? = true) {
        self.state = state
        self.isAvailable = isAvailable
    }
}

extension SentrySnapshot {
    init(_ closures: CarServer_ClosuresState) {
        state = switch closures.sentryModeState.type {
        case .off?: .off
        case .idle?: .idle
        case .armed?: .armed
        case .aware?: .aware
        case .panic?: .panic
        case .quiet?: .quiet
        case nil: nil
        }
        if case .sentryModeAvailable(let available)? = closures.optionalSentryModeAvailable {
            isAvailable = available
        }
    }
}
