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

    public init(key: ObservationKey, jpeg: Data, seedRect: [Double]? = nil, isReference: Bool = false) {
        self.key = key
        self.jpeg = jpeg
        self.seedRect = seedRect
        self.isReference = isReference
    }
}

public enum DetectionStatus: String, Codable, Equatable, Sendable {
    /// Temporal continuity from the previously initialized Vision sequence.
    case tracked
    /// A lookalike recovery proposal; never proof that this is the selected object.
    case candidate
    /// The user's first explicit reference crop for a selection, echoed as initialized.
    case identityConfirmed
    case notFound
}

/// A Mac localization result. Candidate results are deliberately unconfirmed;
/// callers must not treat them as the selected object's identity.
public struct DetectionReply: Codable, Equatable, Sendable {
    public let key: ObservationKey
    public let rect: [Double]?
    public let confidence: Double
    public let candidateID: String?
    public let status: DetectionStatus

    public init(key: ObservationKey, rect: [Double]?, confidence: Double,
                candidateID: String?, status: DetectionStatus) {
        self.key = key
        self.rect = rect
        self.confidence = confidence
        self.candidateID = candidateID
        self.status = status
    }
}
