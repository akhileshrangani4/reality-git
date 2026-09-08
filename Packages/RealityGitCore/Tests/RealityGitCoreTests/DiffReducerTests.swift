import XCTest
@testable import RealityGitCore

final class DiffReducerTests: XCTestCase {
    func testMoveAndRestoreRequireIndependentFramesAndHalfSecond() {
        var diff = DiffReducer(referencePosition: .zero)
        diff.observe(position: SIMD3(0.2, 0, 0), identityConfirmed: true, visibility: .visibleOccupied, time: 1, frameID: 1)
        diff.observe(position: SIMD3(0.2, 0, 0), identityConfirmed: true, visibility: .visibleOccupied, time: 2, frameID: 1)
        diff.observe(position: SIMD3(0.2, 0, 0), identityConfirmed: true, visibility: .visibleOccupied, time: 1.25, frameID: 2)
        XCTAssertEqual(diff.state, .unchanged)
        diff.observe(position: SIMD3(0.2, 0, 0), identityConfirmed: true, visibility: .visibleOccupied, time: 1.5, frameID: 3)
        XCTAssertEqual(diff.state, .moved)
        for id in 4...6 {
            diff.observe(position: SIMD3(0.1, 0, 0), identityConfirmed: true, visibility: .visibleOccupied, time: Double(id), frameID: UInt64(id))
        }
        XCTAssertEqual(diff.state, .moved, "Partial restoration must preserve confirmed movement")
        for id in 7...9 {
            diff.observe(position: SIMD3(0.05, 0, 0), identityConfirmed: true, visibility: .visibleOccupied, time: Double(id), frameID: UInt64(id))
        }
        XCTAssertEqual(diff.state, .unchanged)
    }
    func testUnknownOrContradictoryEvidenceBreaksConfirmationAndLossNeverMeansRemoval() {
        var diff = DiffReducer(referencePosition: .zero)
        diff.observe(position: SIMD3(0.2, 0, 0), identityConfirmed: true, visibility: .visibleOccupied, time: 1, frameID: 1)
        diff.observe(position: nil, identityConfirmed: false, visibility: .unknown, time: 2, frameID: 2)
        diff.observe(position: SIMD3(0.2, 0, 0), identityConfirmed: true, visibility: .visibleOccupied, time: 3, frameID: 3)
        XCTAssertEqual(diff.state, .unchanged)
        for id in 4...8 { diff.observe(position: nil, identityConfirmed: false, visibility: .occluded, time: Double(id), frameID: UInt64(id)) }
        XCTAssertEqual(diff.state, .unchanged)
        for id in 9...11 { diff.observe(position: nil, identityConfirmed: false, visibility: .visibleEmpty, time: Double(id), frameID: UInt64(id)) }
        XCTAssertEqual(diff.state, .absent)
    }
    func testConfirmedMoveSurvivesCurrentPositionLossButCannotRestoreFromCandidate() {
        var diff = DiffReducer(referencePosition: .zero)
        for id in 1...3 { diff.observe(position: SIMD3(0.3, 0, 0), identityConfirmed: true, visibility: .visibleOccupied, time: Double(id), frameID: UInt64(id)) }
        for id in 4...8 { diff.observe(position: .zero, identityConfirmed: false, visibility: .unknown, time: Double(id), frameID: UInt64(id)) }
        XCTAssertEqual(diff.state, .moved)
    }
}
