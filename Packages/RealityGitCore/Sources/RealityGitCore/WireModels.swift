import Foundation

/// A sampled camera frame sent to the Mac assistant.
///
/// JPEG pixels use the camera's native axes and are tagged with orientation `.up`;
/// they are not physically rotated upright. `seedRect` is `[x, y, width, height]`
/// in normalized pixel coordinates with a top-left origin in those native axes.
public struct FrameRequest: Codable, Equatable, Sendable {
    public let key: ObservationKey
    public let jpeg: Data
    public let seedRect: [Double]?
    public let isReference: Bool
    public let seedPoint: [Double]?

    public init(key: ObservationKey, jpeg: Data, seedRect: [Double]? = nil, isReference: Bool = false, seedPoint: [Double]? = nil) {
        self.key = key
        self.jpeg = jpeg
        self.seedRect = seedRect
        self.isReference = isReference
        self.seedPoint = seedPoint
    }
}

public enum DetectionStatus: String, Codable, Equatable, Sendable {
    /// The selected object was located. The active route uses Astra confirmation.
    case tracked
    /// A lookalike recovery proposal; never proof that this is the selected object.
    case candidate
    /// Astra identified and localized the initial user selection.
    case identityConfirmed
    case notFound
}

/// A server localization result. Candidate results are deliberately unconfirmed;
/// callers must not treat them as the selected object's identity.
public struct DetectionReply: Codable, Equatable, Sendable {
    public let key: ObservationKey
    public let rect: [Double]?
    public let confidence: Double
    public let candidateID: String?
    public let status: DetectionStatus
    public let semanticLabel: String?
    public let semanticStatus: String?
    /// Astra's visible silhouette, in normalized top-left image coordinates.
    public let outline: [[Double]]?

    public init(key: ObservationKey, rect: [Double]?, confidence: Double,
                candidateID: String?, status: DetectionStatus, semanticLabel: String? = nil, semanticStatus: String? = nil,
                outline: [[Double]]? = nil) {
        self.key = key
        self.rect = rect
        self.confidence = confidence
        self.candidateID = candidateID
        self.status = status
        self.semanticLabel = semanticLabel
        self.semanticStatus = semanticStatus
        self.outline = outline
    }
}
