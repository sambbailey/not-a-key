import Foundation
import TeslaKit

/// What pressing "toggle boot" is about to do, judged from the boot's state just before.
enum BootToggleOutcome: Equatable {
    case opening, closing, moving
}

/// Runs one piece of work against the car: connect, use a fresh client, disconnect.
struct VehicleService: Sendable {
    let vin: String
    let key: KeyAgreementKey
    private let connect: @Sendable (String) async throws -> VehicleTransport

    init(vin: String, key: KeyAgreementKey,
         connect: @escaping @Sendable (String) async throws -> VehicleTransport = {
             try await BLETransport.connect(vin: $0)
         }) {
        self.vin = vin
        self.key = key
        self.connect = connect
    }

    /// Connects, runs `body`, and always closes the connection afterwards.
    func withClient<T: Sendable>(_ body: @Sendable (VehicleClient) async throws -> T) async throws -> T {
        let transport = try await connect(vin)
        defer { transport.close() }
        return try await body(VehicleClient(vin: vin, key: key, transport: transport))
    }

    /// Opens a closed boot or closes an open one. A boot that is moving or in an unknown
    /// state is still sent the move command; the outcome then just says it is moving.
    /// With a `deadline`, no request is sent to the car after it passes.
    func toggleBoot(before deadline: ContinuousClock.Instant? = nil) async throws -> BootToggleOutcome {
        try await withClient { client in
            let state = try await client.bodyControllerState(deadline: Self.limit(.seconds(5), to: deadline))
            let outcome: BootToggleOutcome = switch state.rearTrunk {
            case .closed: .opening
            case .open, .ajar: .closing
            case .opening, .closing, .unknown: .moving
            }
            try await client.execute(.moveTrunk, deadline: Self.limit(.seconds(8), to: deadline))
            return outcome
        }
    }

    func snapshot() async throws -> VehicleSnapshot {
        try await withClient { try await $0.bodyControllerState() }
    }

    /// A request's own `timeout`, shortened so it ends no later than `deadline`.
    private static func limit(_ timeout: Duration, to deadline: ContinuousClock.Instant?) -> Duration {
        guard let deadline else { return timeout }
        return min(timeout, deadline - .now)
    }
}
