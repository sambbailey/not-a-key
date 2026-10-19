import Foundation

/// A connection to one vehicle that carries whole, already de-framed messages.
public protocol VehicleTransport: AnyObject, Sendable {
    /// Returns once the vehicle has the whole message. Throws, rather than waiting, once the
    /// transport is closed or disconnected, and when the link stops acknowledging writes.
    func send(_ message: Data) async throws
    /// Every message the vehicle sends, including replies addressed to other clients.
    /// The same stream on every access, read by a single consumer; it finishes when the
    /// transport is closed or the vehicle disconnects.
    var incoming: AsyncStream<Data> { get }
    /// Disconnects, finishes `incoming` and fails any pending `send`.
    func close()
}
