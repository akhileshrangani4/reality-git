import Foundation

public enum ObservationSource: Int, Sendable { case local = 0, server = 1 }
public struct PositionObservation: Sendable {
    public let key: ObservationKey
    public let position: SIMD3<Float>
    public let identityConfirmed: Bool
    public let confidence: Float
    public let source: ObservationSource
    public init(key: ObservationKey, position: SIMD3<Float>, identityConfirmed: Bool,
                confidence: Float, source: ObservationSource = .local) {
        self.key = key; self.position = position; self.identityConfirmed = identityConfirmed
        self.confidence = confidence; self.source = source
    }
}
public struct Reconciler: Sendable {
    public let referencePosition: SIMD3<Float>
    public let sessionID: UUID
    public let objectID: UUID
    public private(set) var currentPosition: SIMD3<Float>?
    public private(set) var accepted: PositionObservation?
    public private(set) var confirmationCount = 0
    public private(set) var pendingCandidate: PositionObservation?
    public init(referencePosition: SIMD3<Float>, sessionID: UUID, objectID: UUID) {
        self.referencePosition = referencePosition; self.sessionID = sessionID; self.objectID = objectID
    }
    @discardableResult public mutating func accept(_ observation: PositionObservation) -> Bool {
        guard observation.key.sessionID == sessionID, observation.key.objectID == objectID,
              observation.key.captureTime.isFinite,
              [observation.position.x, observation.position.y, observation.position.z, observation.confidence].allSatisfy(\.isFinite),
              (0...1).contains(observation.confidence) else { return false }
        if let accepted {
            guard observation.key.frameID >= accepted.key.frameID,
                  observation.key.captureTime >= accepted.key.captureTime else { return false }
            if observation.key.frameID == accepted.key.frameID {
                guard observation.key.captureTime == accepted.key.captureTime,
                      observation.source.rawValue > accepted.source.rawValue ||
                      (observation.source == accepted.source && observation.confidence > accepted.confidence) else { return false }
            }
        }
        guard observation.identityConfirmed else { pendingCandidate = observation; return false }
        if accepted?.key.frameID != observation.key.frameID { confirmationCount += 1 }
        accepted = observation; currentPosition = observation.position; pendingCandidate = nil
        return true
    }
}
