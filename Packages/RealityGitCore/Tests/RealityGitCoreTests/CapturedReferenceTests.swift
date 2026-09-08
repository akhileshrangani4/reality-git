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
    func testFreshSeparatedComponentCanRelocateInDepthButRejectsOccluderAppearance() throws {
        let points = (0..<64).map { i in SIMD3(Float(i % 8) * 0.01, Float(i / 8) * 0.01, Float(-1)) }
        let support: [SIMD2<Float>] = (0..<64).map { i in
            let x = (Float(i % 8) + 0.5) / 8
            let y = (Float(i / 8) + 0.5) / 8
            return SIMD2<Float>(x, y)
        }
        let colors = Array(repeating: SIMD3<Float>(0.1, 0.3, 0.8), count: 64)
        let initial = try XCTUnwrap(DepthComponentSignature(points: points, colors: colors, support: support))
        for delta: Float in [-0.3, 0.3] {
            let moved = points.map { $0 + SIMD3(0, 0, delta) }
            let candidate = try XCTUnwrap(DepthComponentSignature(points: moved, colors: colors, support: support))
            XCTAssertTrue(initial.accepts(candidate, confidence: 0.9))
            XCTAssertFalse(ForegroundDepth.allowsFallback(measuredDepth: 1 - delta, supportedWorld: SIMD3(0,0,-1), cameraToWorld: matrix_identity_float4x4), "Old support cannot establish the relocated depth")
            var diff = DiffReducer(referencePosition: SIMD3(0,0,-1))
            for frame in 0...2 { diff.observe(position: SIMD3(0,0,-1 + delta), identityConfirmed: initial.accepts(candidate, confidence: 0.9), visibility: .visibleOccupied, time: Double(frame) * 0.3, frameID: UInt64(frame)) }
            XCTAssertEqual(diff.state, .moved)
        }
        let handColors = Array(repeating: SIMD3<Float>(0.8, 0.5, 0.4), count: 64)
        let hand = try XCTUnwrap(DepthComponentSignature(points: points.map { $0 + SIMD3(0,0,0.3) }, colors: handColors, support: support))
        XCTAssertFalse(initial.accepts(hand, confidence: 0.95))
        let larger = try XCTUnwrap(DepthComponentSignature(points: points.map { SIMD3($0.x * 2, $0.y, $0.z) }, colors: colors, support: support))
        XCTAssertFalse(initial.accepts(larger, confidence: 0.95))
    }
    func testMaskAndDepthSupportShareTrackedBoxDespiteSmallerMaskExtent() throws {
        let trackedRect = CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
        let maskRect = CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.3)
        let imagePoints: [SIMD2<Float>] = (0..<64).map { i in
            let u = Float(0.3) + (Float(i % 8) + 0.5) * 0.3 / 8
            let v = Float(0.3) + (Float(i / 8) + 0.5) * 0.3 / 8
            return SIMD2(u, v)
        }
        let points = imagePoints.map { SIMD3($0.x, $0.y, Float(-1)) }
        let colors = Array(repeating: SIMD3<Float>(0.2, 0.3, 0.8), count: 64)
        let trackedSupport = DepthComponentSignature.normalizedSupport(imagePoints: imagePoints, trackingRect: trackedRect)
        let mask = try XCTUnwrap(DepthComponentSignature(points: points, colors: colors, support: trackedSupport))
        let moved = try XCTUnwrap(DepthComponentSignature(points: points.map { $0 + SIMD3(0,0,0.3) }, colors: colors, support: trackedSupport))
        XCTAssertTrue(mask.accepts(moved, confidence: 0.9))
        let mismatched = try XCTUnwrap(DepthComponentSignature(points: points, colors: colors, support: DepthComponentSignature.normalizedSupport(imagePoints: imagePoints, trackingRect: maskRect)))
        XCTAssertFalse(mismatched.accepts(moved, confidence: 0.9), "This fixture reproduces the former mixed-coordinate rejection")
    }
    func testKnownObjectProposalDoesNotRequireExposedBackgroundBoundary() throws {
        let rect = CGRect(x: 0.3, y: 0.3, width: 0.375, height: 0.375)
        let depth = Array(repeating: Float(0.8), count: 1600)
        let confidence = Array(repeating: UInt8(2), count: 1600)
        XCTAssertTrue(ForegroundDepth.indices(depth: depth, confidence: confidence, width: 40, height: 40, rect: rect).isEmpty, "Initial capture still needs background separation")
        let indices = ForegroundDepth.indices(depth: depth, confidence: confidence, width: 40, height: 40, rect: rect, requireSeparatedBackground: false)
        XCTAssertEqual(indices.count, 256)
        let imagePoints = indices.map { SIMD2((Float($0 % 40) + 0.5) / 40, (Float($0 / 40) + 0.5) / 40) }
        let support = DepthComponentSignature.normalizedSupport(imagePoints: imagePoints, trackingRect: rect)
        let initialPoints = imagePoints.map { SIMD3($0.x, $0.y, Float(-1.1)) }
        let movedPoints = initialPoints.map { $0 + SIMD3(0,0,0.3) }
        let blue = Array(repeating: SIMD3<Float>(0.1,0.3,0.8), count: indices.count)
        let known = try XCTUnwrap(DepthComponentSignature(points: initialPoints, colors: blue, support: support))
        let moved = try XCTUnwrap(DepthComponentSignature(points: movedPoints, colors: blue, support: support))
        XCTAssertTrue(known.accepts(moved, confidence: 0.85))
        for color in [SIMD3<Float>(0.7,0.6,0.5), SIMD3<Float>(0.8,0.4,0.3)] {
            let distractor = try XCTUnwrap(DepthComponentSignature(points: movedPoints, colors: Array(repeating: color, count: indices.count), support: support))
            XCTAssertFalse(known.accepts(distractor, confidence: 0.9))
            XCTAssertEqual(known.rejectionReason(distractor, confidence: 0.9), "color")
        }
    }
    func testCurrentScreenGreenUsesOnlyFreshLocalTrackDuringConfirmedMove() {
        func visible(state: DiffState = .moved, fresh: Bool = true, confidence: Float = 0.9, world: Bool = false, reliable: Bool = true, drawing: Bool = false) -> Bool {
            CurrentScreenOverlay.isVisible(state: state, freshLocalTrack: fresh, confidence: confidence, hasCurrentWorldPosition: world, arReliable: reliable, drawing: drawing)
        }
        XCTAssertTrue(visible())
        XCTAssertFalse(visible(state: .unchanged))
        XCTAssertTrue(visible(state: .absent), "A freshly recovered object may have a screen location before its metric state reconciles")
        XCTAssertFalse(visible(state: .absent, fresh: false))
        XCTAssertFalse(visible(fresh: false), "Stale, lost or candidate-only boxes cannot show the overlay")
        XCTAssertFalse(visible(confidence: 0.5))
        XCTAssertFalse(visible(world: true), "Use the 3D current marker when its metric position is available")
        XCTAssertFalse(visible(reliable: false))
        XCTAssertFalse(visible(drawing: true))
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
