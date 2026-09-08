import XCTest
@testable import RealityGitCore

final class ReconcilerTests: XCTestCase {
    let session = UUID(), object = UUID()
    func observation(_ frame: UInt64, time: Double, x: Float, source: ObservationSource = .local,
                     confirmed: Bool = true, session: UUID? = nil, object: UUID? = nil) -> PositionObservation {
        PositionObservation(key: ObservationKey(sessionID: session ?? self.session, objectID: object ?? self.object,
            frameID: frame, captureTime: time), position: SIMD3(x, 0, 0), identityConfirmed: confirmed,
            confidence: 1, source: source)
    }
    func testOrderingAndSameFrameCorrectionDoNotMoveReferenceOrDoubleCount() {
        var r = Reconciler(referencePosition: .zero, sessionID: session, objectID: object)
        XCTAssertTrue(r.accept(observation(20, time: 2, x: 1)))
        XCTAssertFalse(r.accept(observation(10, time: 3, x: 2)))
        XCTAssertTrue(r.accept(observation(20, time: 2, x: 1.1, source: .server)))
        XCTAssertFalse(r.accept(observation(20, time: 2, x: 1.2, source: .server)))
        XCTAssertEqual(r.confirmationCount, 1)
        XCTAssertEqual(r.currentPosition, SIMD3<Float>(1.1, 0, 0))
        XCTAssertEqual(r.referencePosition, .zero)
    }
    func testCandidatesAndForeignOrInvalidSourcesCannotChangeCurrent() {
        var r = Reconciler(referencePosition: .zero, sessionID: session, objectID: object)
        XCTAssertTrue(r.accept(observation(1, time: 1, x: 0)))
        XCTAssertFalse(r.accept(observation(2, time: 2, x: 2, confirmed: false)))
        XCTAssertNotNil(r.pendingCandidate)
        XCTAssertFalse(r.accept(observation(3, time: 3, x: 3, session: UUID())))
        XCTAssertFalse(r.accept(observation(3, time: 3, x: 3, object: UUID())))
        XCTAssertFalse(r.accept(observation(3, time: 3, x: .nan)))
        XCTAssertEqual(r.currentPosition, .zero)
        let newSession = UUID()
        r = Reconciler(referencePosition: SIMD3(5, 0, 0), sessionID: newSession, objectID: object)
        XCTAssertFalse(r.accept(observation(99, time: 10, x: 1)))
        XCTAssertTrue(r.accept(observation(1, time: 11, x: 5, session: newSession)))
        XCTAssertEqual(r.confirmationCount, 1)
    }
    func testReferenceCopiesFirstValidGeometryAndRejectsInvalidBounds() throws {
        let key = observation(1, time: 1, x: 0).key
        let reference = try XCTUnwrap(ReferenceState(key: key, position: SIMD3(1, 2, 3), bounds: SIMD3(0.2, 0.3, 0.1)))
        var r = Reconciler(referencePosition: reference.position, sessionID: session, objectID: object)
        XCTAssertTrue(r.accept(observation(2, time: 2, x: 4)))
        XCTAssertEqual(reference.position, SIMD3(1, 2, 3))
        XCTAssertEqual(reference.bounds, SIMD3(0.2, 0.3, 0.1))
        XCTAssertNil(ReferenceState(key: key, position: .zero, bounds: SIMD3(0, 1, 1)))
        XCTAssertNil(ReferenceState(key: key, position: SIMD3(.nan, 0, 0), bounds: SIMD3(repeating: 1)))
    }
}
