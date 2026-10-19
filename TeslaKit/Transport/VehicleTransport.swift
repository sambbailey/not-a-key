import Foundation

/// A connection to one vehicle that carries whole, already de-framed messages.
public protocol VehicleTransport: AnyObject, Sendable {
    func send(_ message: Data) async throws
    /// Every message the vehicle sends, including replies addressed to other clients.
    var incoming: AsyncStream<Data> { get }
    func close()
}
