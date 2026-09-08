import XCTest
@testable import RealityGitCore

final class ProjectionTests: XCTestCase {
    func testOpticalCenterFacesNegativeZ() throws {
        let p = try XCTUnwrap(Projection.unproject(u: 320, v: 240, depth: 2,
            fx: 500, fy: 500, cx: 320, cy: 240))
        XCTAssertEqual(p, SIMD3<Float>(0, 0, -2))
    }

    func testTopRightPixelHasPositiveXAndY() throws {
        let p = try XCTUnwrap(Projection.unproject(u: 420, v: 140, depth: 2,
            fx: 500, fy: 500, cx: 320, cy: 240))
        XCTAssertEqual(p.x, 0.4, accuracy: 0.0001)
        XCTAssertEqual(p.y, 0.4, accuracy: 0.0001)
    }

    func testRejectsInvalidDepthAndCalibration() {
        for depth: Float in [0, -1, .nan, .infinity] {
            XCTAssertNil(Projection.unproject(u: 0, v: 0, depth: depth,
                fx: 1, fy: 1, cx: 0, cy: 0))
        }
        XCTAssertNil(Projection.unproject(u: 0, v: 0, depth: 1,
            fx: 0, fy: 1, cx: 0, cy: 0))
        XCTAssertNil(Projection.unproject(u: .nan, v: 0, depth: 1,
            fx: 1, fy: 1, cx: 0, cy: 0))
    }

    func testPixelCentersRescaleToDepthResolution() {
        let p = Projection.imagePixel(depthX: 0, depthY: 0,
            depthWidth: 256, depthHeight: 192, imageWidth: 1920, imageHeight: 1440)
        XCTAssertEqual(p, SIMD2<Float>(3.75, 3.75))
    }

    func testRobustPositionRejectsBackgroundOutlier() {
        let points: [SIMD3<Float>] = [[0,0,-1], [0.01,0,-1.01], [-0.01,0,-0.99], [2,3,-8]]
        let center = Projection.medianPosition(points)
        XCTAssertEqual(center?.x ?? 99, 0.005, accuracy: 0.0001)
        XCTAssertEqual(center?.z ?? 99, -1.005, accuracy: 0.0001)
        XCTAssertNil(Projection.medianPosition([]))
    }
}
