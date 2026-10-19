import CoreBluetooth
import Foundation
import Testing
@testable import TeslaKit

@Test func matchesAdvertisedLocalName() {
    let vin = "5YJ30123456789ABC"
    let ours: [String: Any] = [CBAdvertisementDataLocalNameKey: VehicleLocalName.make(vin: vin)]
    let theirs: [String: Any] = [CBAdvertisementDataLocalNameKey: VehicleLocalName.make(vin: "5YJ3E1EA7KF000000")]
    #expect(BLETransport.matches(advertisement: ours, vin: vin))
    #expect(!BLETransport.matches(advertisement: theirs, vin: vin))
    #expect(!BLETransport.matches(advertisement: [:], vin: vin))
}
