import XCTest
@testable import RealityGitCore

final class MacRecoveryTests: XCTestCase {
    let session = UUID(), object = UUID()
    func reply(time: Double = 2, status: DetectionStatus = .tracked, confidence: Double = 0.9,
               object: UUID? = nil) -> DetectionReply {
        DetectionReply(key: ObservationKey(sessionID: session, objectID: object ?? self.object,
            frameID: UInt64(time * 100), captureTime: time), rect: [0.2, 0.2, 0.3, 0.3],
            confidence: confidence, candidateID: nil, status: status)
    }
    func testLostTrackCanRecoverOnceFromFreshContinuousEvidence() {
        var policy = MacRecoveryPolicy()
        XCTAssertNil(policy.admit(reply(), sourceTime: 2, currentTime: 2.2, sessionID: session, objectID: object))
        policy.markLost(at: 1.9)
        XCTAssertNotNil(policy.admit(reply(), sourceTime: 2, currentTime: 2.2, sessionID: session, objectID: object))
        XCTAssertNil(policy.admit(reply(), sourceTime: 2, currentTime: 2.8, sessionID: session, objectID: object))
        XCTAssertNil(policy.admit(reply(time: 2.3), sourceTime: 2.3, currentTime: 2.4, sessionID: session, objectID: object))
        policy.markTracked()
        XCTAssertNil(policy.admit(reply(time: 3), sourceTime: 3, currentTime: 3.1, sessionID: session, objectID: object))
        XCTAssertEqual(policy.attempts, 1)
    }
    func testCandidatesOldSelectionAndStaleOrBackwardsSourcesNeverReseed() {
        var policy = MacRecoveryPolicy(); policy.markLost(at: 1.9)
        for value in [reply(status: .candidate), reply(status: .identityConfirmed), reply(status: .notFound),
                      reply(confidence: 0.59), reply(object: UUID())] {
            XCTAssertNil(policy.admit(value, sourceTime: 2, currentTime: 2.2, sessionID: session, objectID: object))
        }
        XCTAssertNil(policy.admit(reply(), sourceTime: 2, currentTime: 3.01, sessionID: session, objectID: object))
        XCTAssertNil(policy.admit(reply(), sourceTime: 2, currentTime: 2, sessionID: session, objectID: object))
        XCTAssertNil(policy.admit(reply(), sourceTime: 2.1, currentTime: 2.3, sessionID: session, objectID: object))
        XCTAssertNil(policy.admit(reply(time: 1.8), sourceTime: 1.8, currentTime: 2.2, sessionID: session, objectID: object))
        // A reset/new selection never inherits the old loss epoch or accepts the previous object.
        policy = MacRecoveryPolicy(); policy.markLost(at: 2.1)
        XCTAssertNil(policy.admit(reply(), sourceTime: 2, currentTime: 2.3, sessionID: session, objectID: UUID()))
        XCTAssertEqual(policy.attempts, 0)
    }
    func testExecutorSeedsExactSourceThenAdvancesBeforePublishingNewEpoch() {
        final class Epoch { var frames: [Int] = [] }
        let old = Epoch(); old.frames = [10, 11]
        let result = MacRecoveryExecutor.recover(source: 12, current: 14,
            rect: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3), makeSequence: { Epoch() },
            seed: { epoch, frame, _ in epoch.frames.append(frame); return 0.9 },
            advance: { epoch, frame, previous in
                XCTAssertEqual(previous, 0.9); epoch.frames.append(frame); return 0.8
            }, accepts: { $0 >= 0.6 })
        XCTAssertEqual(result?.0.frames, [12, 14])
        XCTAssertEqual(result?.1, 0.8)
        XCTAssertEqual(old.frames, [10, 11], "Never replay older evidence into the existing sequence")
        let failed = MacRecoveryExecutor.recover(source: 12, current: 14, rect: .zero,
            makeSequence: { Epoch() }, seed: { _, _, _ in 0.9 }, advance: { _, _, _ in 0.2 },
            accepts: { $0 >= 0.6 })
        XCTAssertNil(failed, "A confident source alone cannot publish a recovery epoch")
    }
}
