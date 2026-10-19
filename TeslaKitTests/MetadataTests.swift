import Foundation
import Testing
@testable import TeslaKit

@Test func serializesSortedTLVWithTerminator() throws {
    var m = Metadata()
    try m.add(.personalization, Data("abc".utf8))
    try m.add(.counter, uint32: 100)
    #expect(m.serialized() == Data(hex: "0203616263050400000064FF"))
}

@Test func rejectsOutOfOrderTags() {
    var m = Metadata()
    #expect(throws: MetadataError.outOfOrder) {
        try m.add(.counter, uint32: 1); try m.add(.domain, Data([2]))
    }
}

@Test func rejectsLongValues() {
    var m = Metadata()
    #expect(throws: MetadataError.tooLong) { try m.add(.personalization, Data(count: 256)) }
}

@Test func encodesZeroLengthValue() throws {
    var m = Metadata()
    try m.add(.personalization, Data())
    #expect(m.serialized() == Data(hex: "0200FF"))
}

@Test func reproducesProtocolDocHvacMetadata() throws {
    var m = Metadata()
    try m.add(.signatureType, Data([5]))     // SIGNATURE_TYPE_AES_GCM_PERSONALIZED
    try m.add(.domain, Data([3]))            // DOMAIN_INFOTAINMENT
    try m.add(.personalization, Data(TestVectors.vin.utf8))
    try m.add(.epoch, Data(hex: "4c463f9cc0d3d26906e982ed224adde6"))
    try m.add(.expiresAt, uint32: 2655)
    try m.add(.counter, uint32: 7)
    try m.add(.flags, uint32: 2)
    #expect(m.serialized() == TestVectors.hvacOnMetadata)
}

@Test func localNameMatchesSpec() {
    #expect(VehicleLocalName.make(vin: "5YJS0000000000000") == "S1a87a5a75f3df858C")
}
