import Foundation

public struct ObservationKey: Codable, Hashable, Sendable {
    public let sessionID: UUID
    public let objectID: UUID
    public let frameID: UInt64
    public let captureTime: Double

    public init(sessionID: UUID, objectID: UUID, frameID: UInt64, captureTime: Double) {
        self.sessionID = sessionID
        self.objectID = objectID
        self.frameID = frameID
        self.captureTime = captureTime
    }
}
