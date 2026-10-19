import Foundation

/// What to do with one of the up to three replies VCSEC sends for a request.
public enum VCSECReply: Sendable {
    /// The final reply; for status requests it carries `vehicleStatus`.
    case done(VCSEC_FromVCSECMessage)
    /// An interim command status; keep reading.
    case pending
    /// VCSEC is busy with another request; retry after a short delay.
    case busy

    /// Classifies a decoded reply per protocol.md "VCSEC application-layer responses".
    public static func classify(_ msg: VCSEC_FromVCSECMessage) throws -> VCSECReply {
        switch msg.subMessage {
        case .nominalError(let error)?:
            throw VehicleError.rejected(String(describing: error.genericError))
        case .commandStatus(let status)?:
            // OPERATIONSTATUS_ERROR is for legacy clients; a specific error follows.
            return status.operationStatus == .operationstatusWait ? .busy : .pending
        default:
            return .done(msg)
        }
    }
}

public struct VehicleSnapshot: Sendable, Equatable {
    public enum ClosureState: Sendable, Equatable {
        case closed, open, ajar, opening, closing, unknown
    }

    public var isLocked: Bool
    public var rearTrunk: ClosureState
    public var frontTrunk: ClosureState
    public var isAsleep: Bool

    public init(isLocked: Bool, rearTrunk: ClosureState, frontTrunk: ClosureState, isAsleep: Bool) {
        self.isLocked = isLocked
        self.rearTrunk = rearTrunk
        self.frontTrunk = frontTrunk
        self.isAsleep = isAsleep
    }

    public init(_ status: VCSEC_VehicleStatus) {
        switch status.vehicleLockState {
        case .vehiclelockstateLocked, .vehiclelockstateInternalLocked: isLocked = true
        default: isLocked = false
        }
        rearTrunk = ClosureState(status.closureStatuses.rearTrunk)
        frontTrunk = ClosureState(status.closureStatuses.frontTrunk)
        isAsleep = status.vehicleSleepStatus == .vehicleSleepStatusAsleep
    }
}

extension VehicleSnapshot.ClosureState {
    init(_ state: VCSEC_ClosureState_E) {
        switch state {
        case .closurestateClosed: self = .closed
        case .closurestateOpen: self = .open
        case .closurestateAjar: self = .ajar
        case .closurestateOpening: self = .opening
        case .closurestateClosing: self = .closing
        default: self = .unknown
        }
    }
}
