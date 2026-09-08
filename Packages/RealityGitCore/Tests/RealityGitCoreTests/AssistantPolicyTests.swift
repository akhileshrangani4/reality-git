import XCTest
@testable import RealityGitCore

final class AssistantPolicyTests: XCTestCase {
    let session = UUID(), object = UUID()
    func key(_ frame: UInt64, time: Double = 1) -> ObservationKey {
        ObservationKey(sessionID: session, objectID: object, frameID: frame, captureTime: time)
    }
    func testBufferCapacityAndExpiry() {
        var buffer = SourceFrameBuffer<Int>()
        for i in 1...13 { buffer.insert(i, for: key(UInt64(i)), now: 1) }
        XCTAssertEqual(buffer.count, 12)
        XCTAssertNil(buffer.value(for: key(1), now: 1))
        XCTAssertEqual(buffer.value(for: key(13), now: 6), 13)
        XCTAssertNil(buffer.value(for: key(13), now: 6.001))
        XCTAssertEqual(buffer.count, 0)
        buffer.insert(100, for: key(100), now: 8)
        XCTAssertEqual(buffer.count, 0)
    }
    func testRepliesRequireExactFreshSourceAndValidPayload() {
        let sent = key(1)
        let reply = DetectionReply(key: sent, rect: [0.2, 0.2, 0.3, 0.3], confidence: 0.8,
            candidateID: "candidate", status: .candidate)
        func accepts(_ value: DetectionReply, sent: ObservationKey? = nil, now: Double = 2,
                     previous: Double = 0, source: Bool = true) -> Bool {
            AssistantPolicy.validReply(value, sent: sent ?? self.key(1), now: now,
                lastAcceptedTime: previous, sourceExists: source)
        }
        XCTAssertTrue(accepts(reply))
        XCTAssertFalse(accepts(reply, sent: key(2)))
        XCTAssertFalse(accepts(reply, now: 7))
        XCTAssertFalse(accepts(reply, previous: 1))
        XCTAssertFalse(accepts(reply, source: false))
        XCTAssertFalse(accepts(DetectionReply(key: sent, rect: [0, 0, 2, 1], confidence: 1,
            candidateID: nil, status: .tracked)))
        XCTAssertFalse(accepts(DetectionReply(key: sent, rect: nil, confidence: .nan,
            candidateID: nil, status: .notFound)))
        let reselection = ObservationKey(sessionID: session, objectID: UUID(), frameID: 1, captureTime: 1)
        XCTAssertFalse(accepts(reply, sent: reselection))
    }
    func testDelayedAndMovingCameraHidesHistoricalOverlay() {
        XCTAssertTrue(AssistantPolicy.overlayIsFresh(age: 0.1, translation: 0.001, rotationRadians: 0.01))
        XCTAssertFalse(AssistantPolicy.overlayIsFresh(age: 0.6, translation: 0, rotationRadians: 0))
        XCTAssertFalse(AssistantPolicy.overlayIsFresh(age: 0.1, translation: 0.05, rotationRadians: 0))
        XCTAssertFalse(AssistantPolicy.overlayIsFresh(age: 0.1, translation: 0, rotationRadians: 0.1))
        XCTAssertFalse(AssistantPolicy.overlayIsFresh(age: -0.1, translation: 0, rotationRadians: 0))
    }
    func testLocalEndpointRejectsInternetAndAmbiguousURLs() {
        for address in ["http://mac.local:8080", "http://192.168.1.2:8080", "http://10.0.0.1", "http://172.16.0.1", "http://127.0.0.1", "http://[::1]:8080"] {
            XCTAssertNotNil(AssistantPolicy.localEndpoint(address), address)
        }
        for address in ["http://example.com", "http://8.8.8.8", "http://172.32.0.1", "http://user@mac.local", "http://mac.local?x=1", "http://mac.local/#foo", "http://mac.local/observe", "https://mac.local", "file:///tmp", "http://192.168.1.999", "http://mac.local:0"] {
            XCTAssertNil(AssistantPolicy.localEndpoint(address), address)
        }
    }
}
