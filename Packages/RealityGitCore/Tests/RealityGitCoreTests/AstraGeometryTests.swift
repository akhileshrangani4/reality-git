import XCTest
@testable import RealityGitCore

final class AstraGeometryTests: XCTestCase {
    func testAstraSilhouetteCapturesDepthWithoutExposedBackgroundRingOrAppearanceSignature() {
        let polygon = [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.2), CGPoint(x: 0.8, y: 0.8), CGPoint(x: 0.2, y: 0.8)]
        var depth = [Float](repeating: 1, count: 400)
        // Edge/background outliers inside the silhouette must not become part of the ghost.
        depth[5 * 20 + 5] = 3
        let pixels = AstraGeometry.depthPixels(depth: depth, confidence: [UInt8](repeating: 2, count: 400), width: 20, height: 20, polygon: polygon)
        XCTAssertEqual(pixels.count, 143)
        XCTAssertFalse(pixels.contains { $0 == (5, 5) })
        XCTAssertFalse(pixels.contains { $0 == (1, 1) })
    }

    func testBadDepthAndDegenerateOutlinesNeverCreateGeometry() {
        let rect = [0.2, 0.2, 0.6, 0.6]
        XCTAssertFalse(AstraGeometry.validOutline([[0.2, 0.2], [0.3, 0.3], [0.4, 0.4]], rect: rect))
        XCTAssertFalse(AstraGeometry.validOutline([[0.1, 0.2], [0.8, 0.2], [0.8, 0.8]], rect: rect))
        let polygon = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
        XCTAssertTrue(AstraGeometry.depthPixels(depth: [.nan], confidence: [2], width: 1, height: 1, polygon: polygon).isEmpty)
        XCTAssertTrue(AstraGeometry.depthPixels(depth: [Float](repeating: 1, count: 400), confidence: [UInt8](repeating: 0, count: 400), width: 20, height: 20, polygon: polygon).isEmpty)
    }

    func testDelayedAstraReplyCanUsePinnedSourceButCannotBecomeFreshScreenOverlay() {
        let key = ObservationKey(sessionID: UUID(), objectID: UUID(), frameID: 1, captureTime: 1)
        let reply = DetectionReply(key: key, rect: [0.2, 0.2, 0.4, 0.4], confidence: 0.95, candidateID: nil, status: .tracked)
        XCTAssertTrue(AssistantPolicy.validReply(reply, sent: key, now: 7,
            lastAcceptedTime: 0, sourceExists: true, maxAge: AstraGeometry.sourceLifetime))
        XCTAssertFalse(AssistantPolicy.validReply(reply, sent: key, now: 32,
            lastAcceptedTime: 0, sourceExists: true, maxAge: AstraGeometry.sourceLifetime))
        XCTAssertFalse(AssistantPolicy.validReply(reply, sent: key, now: 7,
            lastAcceptedTime: 0, sourceExists: false, maxAge: AstraGeometry.sourceLifetime))
        XCTAssertFalse(AssistantPolicy.overlayIsFresh(age: 6, translation: 0, rotationRadians: 0))
    }
}
