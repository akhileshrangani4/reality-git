import XCTest
import simd
@testable import RealityGitCore

final class CapturedReferenceTests: XCTestCase {
    func testVisibilityDoesNotCallOffscreenOrOcclusionAbsent() {
        XCTAssertEqual(ReferenceVisibility.classify(differences: Array(repeating: 0.2, count: 20), projectedCount: 20, totalCount: 100), .unknown)
        XCTAssertEqual(ReferenceVisibility.classify(differences: Array(repeating: -0.2, count: 100), projectedCount: 100, totalCount: 100), .occluded)
        XCTAssertEqual(ReferenceVisibility.classify(differences: Array(repeating: 0.2, count: 100), projectedCount: 100, totalCount: 100), .visibleEmpty)
        XCTAssertEqual(ReferenceVisibility.classify(differences: Array(repeating: 0.2, count: 5), projectedCount: 100, totalCount: 100), .unknown)
    }
    func testFallbackRejectsCloserHandAndAccountsForCameraMotion() {
        XCTAssertFalse(ForegroundDepth.allowsFallback(measuredDepth: 0.7, supportedWorld: SIMD3(0,0,-1), cameraToWorld: matrix_identity_float4x4))
        XCTAssertFalse(ForegroundDepth.allowsFallback(measuredDepth: 1.3, supportedWorld: SIMD3(0,0,-1), cameraToWorld: matrix_identity_float4x4))
        var movedCamera = matrix_identity_float4x4
        movedCamera.columns.3.z = -0.3
        XCTAssertTrue(ForegroundDepth.allowsFallback(measuredDepth: 0.7, supportedWorld: SIMD3(0,0,-1), cameraToWorld: movedCamera))
    }
    func testRetainedBoxWithoutSupportedGeometryDoesNotVetoAbsence() {
        let box = CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        XCTAssertNil(ReferenceVisibility.occupiedRect(trackedRect: box, position: nil, bounds: nil, confidence: 0.95))
        XCTAssertNil(ReferenceVisibility.occupiedRect(trackedRect: box, position: .zero, bounds: .one, confidence: 0.5))
        XCTAssertEqual(ReferenceVisibility.occupiedRect(trackedRect: box, position: .zero, bounds: .one, confidence: 0.95), box)
        XCTAssertEqual(ReferenceVisibility.classify(differences: Array(repeating: 0.2, count: 100), projectedCount: 100, totalCount: 100), .visibleEmpty)
        XCTAssertEqual(ReferenceVisibility.classify(differences: Array(repeating: -0.2, count: 100), projectedCount: 100, totalCount: 100), .occluded)
    }
    func testEveryVisibilityInterruptionRestartsAbsenceConfirmation() {
        for interruption in [VisibilityEvidence.visibleOccupied, .occluded, .unknown] {
            var reducer = DiffReducer(referencePosition: .zero)
            reducer.observe(position: nil, identityConfirmed: false, visibility: .visibleEmpty, time: 0, frameID: 0)
            reducer.observe(position: nil, identityConfirmed: false, visibility: .visibleEmpty, time: 0.4, frameID: 1)
            reducer.observe(position: nil, identityConfirmed: false, visibility: interruption, time: 0.6, frameID: 2)
            reducer.observe(position: nil, identityConfirmed: false, visibility: .visibleEmpty, time: 1.1, frameID: 3)
            reducer.observe(position: nil, identityConfirmed: false, visibility: .visibleEmpty, time: 1.5, frameID: 4)
            reducer.observe(position: nil, identityConfirmed: false, visibility: .visibleEmpty, time: 1.9, frameID: 5)
            XCTAssertEqual(reducer.state, .unchanged)
            reducer.observe(position: nil, identityConfirmed: false, visibility: .visibleEmpty, time: 2.2, frameID: 6)
            XCTAssertEqual(reducer.state, .absent)
        }
    }
    func testCaptureIsBounded() throws {
        let key = ObservationKey(sessionID: UUID(), objectID: UUID(), frameID: 1, captureTime: 1)
        let points = Array(repeating: CapturedPoint(position: .zero, color: .one), count: 9000)
        let ref = try XCTUnwrap(ReferenceState(key: key, position: .zero, bounds: .one, points: points))
        XCTAssertEqual(ref.points.count, 8000)
    }
    func testShortMissingSamplePausesMoveConfirmation() {
        var reducer = DiffReducer(referencePosition: .zero)
        reducer.observe(position: SIMD3(0.2,0,0), identityConfirmed: true, visibility: .unknown, time: 0, frameID: 1)
        reducer.observe(position: nil, identityConfirmed: false, visibility: .unknown, time: 0.2, frameID: 2)
        reducer.observe(position: SIMD3(0.2,0,0), identityConfirmed: true, visibility: .unknown, time: 0.4, frameID: 3)
        reducer.observe(position: SIMD3(0.2,0,0), identityConfirmed: true, visibility: .unknown, time: 0.6, frameID: 4)
        XCTAssertEqual(reducer.state, .moved)
        for i in 5...7 { reducer.observe(position: .zero, identityConfirmed: true, visibility: .visibleOccupied, time: Double(i) * 0.3, frameID: UInt64(i)) }
        XCTAssertEqual(reducer.state, .unchanged)
    }
    func testAbsentNeedsOneSecondAndRestorationClearsIt() {
        var reducer = DiffReducer(referencePosition: .zero)
        for i in 0...2 { reducer.observe(position: nil, identityConfirmed: false, visibility: .visibleEmpty, time: Double(i) * 0.4, frameID: UInt64(i)) }
        XCTAssertEqual(reducer.state, .unchanged)
        reducer.observe(position: nil, identityConfirmed: false, visibility: .visibleEmpty, time: 1.1, frameID: 3)
        XCTAssertEqual(reducer.state, .absent)
        for i in 4...6 { reducer.observe(position: .zero, identityConfirmed: true, visibility: .visibleOccupied, time: Double(i) * 0.3, frameID: UInt64(i)) }
        XCTAssertEqual(reducer.state, .unchanged)
    }
    func testTightlyBoxedForegroundUsesOnlyExternalBackgroundRing() {
        var depth = Array(repeating: Float(1), count: 1600)
        let confidence = Array(repeating: UInt8(2), count: 1600)
        for y in 12...27 { for x in 12...27 { depth[y * 40 + x] = 0.8 } }
        let rect = CGRect(x: 0.3, y: 0.3, width: 0.375, height: 0.375)
        let points = ForegroundDepth.indices(depth: depth, confidence: confidence, width: 40, height: 40, rect: rect)
        XCTAssertEqual(points.count, 256)
        XCTAssertTrue(points.allSatisfy { depth[$0] == 0.8 })
        let flat = Array(repeating: Float(0.8), count: 1600)
        XCTAssertTrue(ForegroundDepth.indices(depth: flat, confidence: confidence, width: 40, height: 40, rect: rect).isEmpty)
    }
    func testExternalRingClampsAtImageEdgeAndKeepsComponentInsideSelection() {
        var depth = Array(repeating: Float(1), count: 1600)
        for y in 0...15 { for x in 0...15 { depth[y * 40 + x] = 0.8 } }
        let points = ForegroundDepth.indices(depth: depth, confidence: Array(repeating: 2, count: 1600), width: 40, height: 40, rect: CGRect(x: 0, y: 0, width: 0.375, height: 0.375))
        XCTAssertEqual(points.count, 256)
        XCTAssertTrue(points.allSatisfy { $0 % 40 <= 15 && $0 / 40 <= 15 })
    }
    func testSlantedSupportPlaneAtClampedCornerIsNotAnObject() {
        let depth = (0..<1600).map { i in Float(1) / (2 - 0.025 * Float(i % 40 + i / 40)) }
        let confidence = Array(repeating: UInt8(2), count: 1600)
        let rect = CGRect(x: 0, y: 0, width: 0.375, height: 0.375)
        XCTAssertTrue(ForegroundDepth.indices(depth: depth, confidence: confidence, width: 40, height: 40, rect: rect).isEmpty)
        var raised = depth
        for y in 0...15 { for x in 0...15 { raised[y * 40 + x] = 0.35 } }
        XCTAssertEqual(ForegroundDepth.indices(depth: raised, confidence: confidence, width: 40, height: 40, rect: rect).count, 256)
    }
    func testForegroundRequiresSeparatedDepthComponent() {
        var depth = Array(repeating: Float(1), count: 1600)
        let confidence = Array(repeating: UInt8(2), count: 1600)
        let rect = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        XCTAssertTrue(ForegroundDepth.indices(depth: depth, confidence: confidence, width: 40, height: 40, rect: rect).isEmpty)
        for y in 14..<26 { for x in 14..<26 { depth[y * 40 + x] = 0.8 } }
        let points = ForegroundDepth.indices(depth: depth, confidence: confidence, width: 40, height: 40, rect: rect)
        XCTAssertEqual(points.count, 144)
        XCTAssertTrue(points.allSatisfy { depth[$0] == 0.8 })
    }
}
