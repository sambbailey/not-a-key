import Foundation
@testable import TeslaKit

/// Constants from pkg/protocol/protocol.md in teslamotors/vehicle-command.
enum TestVectors {
    static let vin = "5YJ30123456789ABC"

    static let clientPrivateKey = Data(hex: "2538CDC29A97C19C1E99A637D6CF4F8C970C118B56EDE1E6323E6D162C4B30DB")
    static let vehiclePrivateKey = Data(hex: "344EE5B466A7CF1EEB12B6F50331DB2E5EC5834EF5F4BEFCFD8CBE55C2528D70")

    /// Uncompressed SEC1 point: 04 ‖ Vx ‖ Vy.
    static let vehiclePublicX963 = Data(hex:
        "04"
        + "C7A1F47138486AA4729971494878D33B1A24E39571F748A6E16C5955B3D877D3"
        + "A6AAA0E955166474AF5D32C410F439A2234137AD1BB085FD4E8813C958F11D97")

    static let sharedKeyK = Data(hex: "1b2fce19967b79db696f909cff89ea9a")

    static let sessionInfoBytes = Data(hex:
        "0806124104c7a1f47138486aa4729971494878d33b1a24e39571f748a6e16c5955b3d877d3"
        + "a6aaa0e955166474af5d32c410f439a2234137ad1bb085fd4e8813c958f11d97"
        + "1a104c463f9cc0d3d26906e982ed224adde6255a0a0000")

    static let handshakeResponse: UniversalMessage_RoutableMessage = {
        var msg = UniversalMessage_RoutableMessage()
        msg.toDestination.routingAddress = Data(hex: "2c907bd76c640d360b3027dc7404efde")
        msg.fromDestination.domain = .infotainment
        msg.signatureData.sessionInfoTag.tag = Data(hex: "996c1fe38331be138f8039c194b14db2198846ed7d8251e6749284d7b32ea002")
        msg.sessionInfo = sessionInfoBytes
        msg.requestUuid = Data(hex: "1588d5a30eabc6f8fc9a951b11f6fd11")
        return msg
    }()

    static let hvacOnMetadata = Data(hex:
        "000105010103021135594a333031323334353637383941424303104c463f9cc0d3d26906e982ed224adde6"
        + "040400000a5f050400000007070400000002ff")
}

extension Data {
    /// Decodes a hex string; traps on malformed input (test-only helper).
    init(hex: String) {
        precondition(hex.count.isMultiple(of: 2), "odd-length hex")
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { preconditionFailure("bad hex: \(hex)") }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
