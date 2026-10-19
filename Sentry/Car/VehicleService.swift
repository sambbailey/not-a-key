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
    func toggleBoot() async throws -> BootToggleOutcome {
        try await withClient { client in
            let outcome: BootToggleOutcome = switch try await client.bodyControllerState().rearTrunk {
            case .closed: .opening
            case .open, .ajar: .closing
            case .opening, .closing, .unknown: .moving
            }
            try await client.execute(.moveTrunk)
            return outcome
        }
    }

    func snapshot() async throws -> VehicleSnapshot {
        try await withClient { try await $0.bodyControllerState() }
    }
}

/// Plain words for an error from talking to the car.
// Interim: Task 12's IntentMessages becomes the shared source of this copy.
func plainMessage(for error: any Error) -> String {
    switch error {
    case VehicleError.bluetoothOff: "Bluetooth is off"
    case VehicleError.bluetoothUnauthorized: "Allow Bluetooth for Sentry in Settings"
    case VehicleError.notInRange: "Car not in range"
    case VehicleError.notPaired: "Key not paired"
    case VehicleError.busy: "Car busy, try again"
    case VehicleError.timeout: "Car didn't respond"
    case VehicleError.rejected(let reason): "The car refused: \(reason)"
    case VehicleError.protocolFault(let fault): "The car reported an error (\(fault))"
    case is KeyStore.Failure: "This phone's car key can't be read"
    default: error.localizedDescription
    }
}
