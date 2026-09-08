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
