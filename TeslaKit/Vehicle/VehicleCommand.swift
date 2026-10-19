import Foundation

/// A command the vehicle executes, with the domain that handles it.
public enum VehicleCommand: Sendable, Equatable {
    case moveTrunk, openFrunk, lock, unlock, wake, climateOn, climateOff
    /// Sets both front zones to `celsius`.
    case setTemperature(celsius: Double)
    /// Turns defrost (maximum preconditioning) on or off.
    case setDefrost(Bool)
    /// Turns "Keep" climate mode on or off, which holds the cabin while parked.
    case keepClimate(Bool)

    public var domain: UniversalMessage_Domain {
        switch self {
        case .moveTrunk, .openFrunk, .lock, .unlock, .wake: .vehicleSecurity
        case .climateOn, .climateOff, .setTemperature, .setDefrost, .keepClimate: .infotainment
        }
    }

    /// The serialized `VCSEC.UnsignedMessage` or `CarServer.Action`, ready to sign for `domain`.
    public func payload() throws -> Data {
        switch self {
        case .moveTrunk:
            var request = VCSEC_ClosureMoveRequest()
            request.rearTrunk = .closureMoveTypeMove
            return try Self.vcsec(.closureMoveRequest(request))
        case .openFrunk:
            var request = VCSEC_ClosureMoveRequest()
            request.frontTrunk = .closureMoveTypeMove
            return try Self.vcsec(.closureMoveRequest(request))
        case .lock: return try Self.vcsec(.rkeaction(.rkeActionLock))
        case .unlock: return try Self.vcsec(.rkeaction(.rkeActionUnlock))
        case .wake: return try Self.vcsec(.rkeaction(.rkeActionWakeVehicle))
        case .climateOn: return try Self.hvacAuto(powerOn: true)
        case .climateOff: return try Self.hvacAuto(powerOn: false)
        case .setTemperature(let celsius):
            var action = CarServer_Action()
            action.vehicleAction.hvacTemperatureAdjustmentAction.driverTempCelsius = Float(celsius)
            action.vehicleAction.hvacTemperatureAdjustmentAction.passengerTempCelsius = Float(celsius)
            return try action.serializedData()
        case .setDefrost(let on):
            var action = CarServer_Action()
            action.vehicleAction.hvacSetPreconditioningMaxAction.on = on
            return try action.serializedData()
        case .keepClimate(let on):
            var action = CarServer_Action()
            action.vehicleAction.hvacClimateKeeperAction.climateKeeperAction = on ? .climateKeeperActionOn : .climateKeeperActionOff
            action.vehicleAction.hvacClimateKeeperAction.manualOverride = true
            return try action.serializedData()
        }
    }

    /// Asks VCSEC for lock, closure and sleep status; the reply carries a `VCSEC_VehicleStatus`.
    public static func bodyControllerStatePayload() throws -> Data {
        var request = VCSEC_InformationRequest()
        request.informationRequestType = .getStatus
        return try vcsec(.informationRequest(request))
    }

    /// Asks infotainment for climate state; the reply's `vehicleData.climateState` carries it.
    public static func climateStatePayload() throws -> Data {
        var action = CarServer_Action()
        action.vehicleAction.getVehicleData.getClimateState = CarServer_GetClimateState()
        return try action.serializedData()
    }

    /// Asks infotainment for charge state; the reply's `vehicleData.chargeState` carries it.
    public static func chargeStatePayload() throws -> Data {
        var action = CarServer_Action()
        action.vehicleAction.getVehicleData.getChargeState = CarServer_GetChargeState()
        return try action.serializedData()
    }

    /// The raw `VCSEC.ToVCSECMessage` asking the car to whitelist `publicKeyX963` as a driver key.
    /// It is not wrapped in a RoutableMessage; the owner approves it with a key card tap.
    public static func addKeyEnvelope(publicKeyX963: Data) throws -> Data {
        var permissions = VCSEC_PermissionChange()
        permissions.key.publicKeyRaw = publicKeyX963
        permissions.keyRole = .driver
        var operation = VCSEC_WhitelistOperation()
        operation.addKeyToWhitelistAndAddPermissions = permissions
        operation.metadataForKey.keyFormFactor = .iosDevice

        var envelope = VCSEC_ToVCSECMessage()
        envelope.signedMessage.protobufMessageAsBytes = try vcsec(.whitelistOperation(operation))
        envelope.signedMessage.signatureType = .presentKey
        return try envelope.serializedData()
    }

    private static func vcsec(_ subMessage: VCSEC_UnsignedMessage.OneOf_SubMessage) throws -> Data {
        var message = VCSEC_UnsignedMessage()
        message.subMessage = subMessage
        return try message.serializedData()
    }

    private static func hvacAuto(powerOn: Bool) throws -> Data {
        var action = CarServer_Action()
        action.vehicleAction.hvacAutoAction.powerOn = powerOn
        return try action.serializedData()
    }
}
