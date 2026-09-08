import Foundation
import Testing
@testable import RealityGitCore

@Test func wireModelsRoundTripAndPreserveKey() throws {
    let key = ObservationKey(sessionID: UUID(), objectID: UUID(), frameID: 42, captureTime: 1)
    let request = FrameRequest(key: key, jpeg: Data([1, 2, 3]),
                               seedRect: [0.2, 0.2, 0.3, 0.3], isReference: true)
    let decoded = try JSONDecoder().decode(FrameRequest.self, from: JSONEncoder().encode(request))
    #expect(decoded == request)
    #expect(decoded.key == key)
}

@Test func legacyDetectionReplyDecodesWithoutSemanticMetadata() throws {
    let key = ObservationKey(sessionID: UUID(), objectID: UUID(), frameID: 1, captureTime: 1)
    let reply = DetectionReply(key: key, rect: nil, confidence: 0, candidateID: nil, status: .notFound)
    let encoded = try JSONEncoder().encode(reply)
    let decoded = try JSONDecoder().decode(DetectionReply.self, from: encoded)
    #expect(decoded.semanticLabel == nil)
    #expect(decoded.semanticStatus == nil)
    #expect(decoded == reply)
}
