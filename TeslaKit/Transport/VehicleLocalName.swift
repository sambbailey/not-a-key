import CryptoKit
import Foundation

/// The BLE local name a vehicle advertises: `S` ‖ hex(SHA1(VIN)[0..<8]) ‖ `C`.
public enum VehicleLocalName {
    public static func make(vin: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(vin.utf8))
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "S\(hex)C"
    }
}
