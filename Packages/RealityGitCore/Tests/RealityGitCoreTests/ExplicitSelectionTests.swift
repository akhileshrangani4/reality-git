import XCTest
@testable import RealityGitCore

final class ExplicitSelectionTests: XCTestCase {
    func testExplicitBoxInitializesAppearanceWithoutInventingMaskOrMetricReference() {
        let box = CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.3)
        let evidence = LocalTrackingEvidence(confidentTrackedRect: box, maskRect: nil,
            maskPosition: SIMD3(0, 0, -1), explicitSelectionRect: box)
        XCTAssertEqual(evidence.initializationRect, box)
        XCTAssertEqual(evidence.displayRect, box)
        XCTAssertNil(evidence.referenceRect)
        XCTAssertNil(evidence.worldPosition)
        let masked = LocalTrackingEvidence(confidentTrackedRect: box, maskRect: box,
            maskPosition: SIMD3(0, 0, -1), explicitSelectionRect: box)
        XCTAssertEqual(masked.referenceRect, box)
        XCTAssertEqual(masked.worldPosition, SIMD3(0, 0, -1))
    }
    func testInvalidExplicitBoxesAndTapWithoutMaskCannotBecomeSeeds() {
        for box in [CGRect(x: -0.1, y: 0, width: 0.3, height: 0.3),
                    CGRect(x: 0.9, y: 0, width: 0.3, height: 0.3),
                    CGRect(x: 0, y: 0, width: 0, height: 0.3)] {
            XCTAssertNil(LocalTrackingEvidence.validSelectionRectangle(box))
        }
        let tap = LocalTrackingEvidence(confidentTrackedRect: nil, maskRect: nil, maskPosition: nil)
        XCTAssertNil(tap.initializationRect)
        XCTAssertNil(tap.referenceRect)
    }
}
