import Foundation

/// A connection to one vehicle that carries whole, already de-framed messages.
public protocol VehicleTransport: AnyObject, Sendable {
    /// Returns once the vehicle has the whole message.
    ///
    /// - After `close()` or a disconnect, throws immediately instead of hanging
    ///   (BLE: `VehicleError.notInRange`).
    /// - Each chunk write is bounded, so a write the link never acknowledges fails
    ///   (BLE: 5 s per chunk, `VehicleError.timeout`).
    func send(_ message: Data) async throws
    /// Every message the vehicle sends, including replies addressed to other clients.
    ///
    /// Returns the same stream instance on every access, and that stream has a single consumer.
    /// It finishes on `close()`, and also when the vehicle disconnects, which additionally
    /// fails any pending `send`.
    var incoming: AsyncStream<Data> { get }
    /// Disconnects, finishes `incoming` and fails any pending `send`.
    func close()
}
