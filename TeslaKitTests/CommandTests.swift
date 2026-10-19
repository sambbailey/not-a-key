import Foundation
import Testing
@testable import TeslaKit

@Test func climateOnMatchesVector() throws {
    #expect(VehicleCommand.climateOn.domain == .infotainment)
    #expect(try VehicleCommand.climateOn.payload() == Data(hex: "120452020801"))
}

@Test func moveTrunkPayload() throws {
    #expect(VehicleCommand.moveTrunk.domain == .vehicleSecurity)
    let msg = try VCSEC_UnsignedMessage(serializedBytes: VehicleCommand.moveTrunk.payload())
    #expect(msg.closureMoveRequest.rearTrunk == .closureMoveTypeMove)
    #expect(msg.closureMoveRequest.frontTrunk == .closureMoveTypeNone)
}

@Test func addKeyEnvelopeShape() throws {
    let key = Data([4]) + Data(repeating: 0xAB, count: 64)
    let envelope = try VCSEC_ToVCSECMessage(serializedBytes: VehicleCommand.addKeyEnvelope(publicKeyX963: key))
    #expect(envelope.signedMessage.signatureType == .presentKey)
    let unsigned = try VCSEC_UnsignedMessage(serializedBytes: envelope.signedMessage.protobufMessageAsBytes)
    let op = unsigned.whitelistOperation
    #expect(op.addKeyToWhitelistAndAddPermissions.key.publicKeyRaw == key)
    #expect(op.addKeyToWhitelistAndAddPermissions.keyRole == .driver)
    #expect(op.metadataForKey.keyFormFactor == .iosDevice)
}

@Test func bodyControllerStateRequestsStatus() throws {
    let msg = try VCSEC_UnsignedMessage(serializedBytes: VehicleCommand.bodyControllerStatePayload())
    guard case .informationRequest(let request)? = msg.subMessage else {
        Issue.record("expected an information request")
        return
    }
    #expect(request.informationRequestType == .getStatus)
}

@Test func classifyWaitIsBusy() throws {
    var msg = VCSEC_FromVCSECMessage()
    msg.commandStatus.operationStatus = .operationstatusWait
    guard case .busy = try VCSECReply.classify(msg) else {
        Issue.record("expected busy")
        return
    }
}

@Test func classifyOtherCommandStatusIsPending() throws {
    var msg = VCSEC_FromVCSECMessage()
    msg.commandStatus.operationStatus = .operationstatusOk
    guard case .pending = try VCSECReply.classify(msg) else {
        Issue.record("expected pending")
        return
    }
}

@Test func classifyEmptyIsDone() throws {
    guard case .done = try VCSECReply.classify(VCSEC_FromVCSECMessage()) else {
        Issue.record("expected done")
        return
    }
    var status = VCSEC_FromVCSECMessage()
    status.vehicleStatus.vehicleLockState = .vehiclelockstateLocked
    guard case .done(let reply) = try VCSECReply.classify(status) else {
        Issue.record("expected done")
        return
    }
    #expect(reply.vehicleStatus.vehicleLockState == .vehiclelockstateLocked)
}

@Test func classifyNominalErrorThrows() {
    var msg = VCSEC_FromVCSECMessage()
    msg.nominalError.genericError = .genericerrorClosuresOpen
    #expect(throws: VehicleError.rejected("genericerrorClosuresOpen")) {
        try VCSECReply.classify(msg)
    }
}

@Test func snapshotMapping() {
    var status = VCSEC_VehicleStatus()
    status.closureStatuses.rearTrunk = .closurestateOpen
    status.closureStatuses.frontTrunk = .closurestateFailedUnlatch
    status.vehicleLockState = .vehiclelockstateInternalLocked
    status.vehicleSleepStatus = .vehicleSleepStatusAsleep
    let snapshot = VehicleSnapshot(status)
    #expect(snapshot == VehicleSnapshot(isLocked: true, rearTrunk: .open, frontTrunk: .unknown, isAsleep: true))

    status.vehicleLockState = .vehiclelockstateSelectiveUnlocked
    status.vehicleSleepStatus = .vehicleSleepStatusUnknown
    #expect(!VehicleSnapshot(status).isLocked)
    #expect(!VehicleSnapshot(status).isAsleep)
}

@Test func faultMapping() {
    #expect(VehicleError.from(fault: .rrorUnknownKeyID) == .notPaired)
    #expect(VehicleError.from(fault: .rrorInactiveKey) == .notPaired)
    #expect(VehicleError.from(fault: .rrorBusy) == .busy)
    #expect(VehicleError.from(fault: .rrorIncorrectEpoch) == .protocolFault(.rrorIncorrectEpoch))
}
