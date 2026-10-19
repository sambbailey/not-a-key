import Foundation
import Testing
@testable import TeslaKit

@Test func routableMessageRoundTrips() throws {
    var msg = UniversalMessage_RoutableMessage()
    msg.toDestination.domain = .vehicleSecurity
    msg.uuid = Data(repeating: 1, count: 16)
    let decoded = try UniversalMessage_RoutableMessage(serializedBytes: msg.serializedData())
    #expect(decoded.toDestination.domain == .vehicleSecurity)
    #expect(decoded.uuid == msg.uuid)
}
