import XCTest
import simd
@testable import RealityGitCore

final class SurfaceProjectionTests: XCTestCase {
    private let intrinsics = simd_float3x3(SIMD3(640, 0, 0), SIMD3(0, 640, 0), SIMD3(320, 240, 1))
    private let points: [SIMD3<Float>] = [SIMD3(-0.1, -0.1, -1), SIMD3(0.1, -0.1, -1), SIMD3(0.1, 0.1, -1), SIMD3(-0.1, 0.1, -1)]

    private func project(_ camera: simd_float4x4) -> CGRect? {
        SurfaceProjection.rectangle(points: points, cameraToWorld: camera, intrinsics: intrinsics, imageWidth: 640, imageHeight: 480)
    }

    func testCameraTranslationMovesScreenBoxWithoutChangingWorldObject() throws {
        let original = try XCTUnwrap(project(matrix_identity_float4x4))
        var camera = matrix_identity_float4x4
        camera.columns.3.x = 0.15
        let moved = try XCTUnwrap(project(camera))
        XCTAssertEqual(original.midX, 0.5, accuracy: 0.0001)
        XCTAssertEqual(moved.midX, 0.35, accuracy: 0.0001)
        XCTAssertEqual(moved.width, original.width, accuracy: 0.0001)
        XCTAssertEqual(moved.midY, original.midY, accuracy: 0.0001)
    }

    func testTurnAwayAndReturnHidesThenRestoresSameProjection() throws {
        let original = try XCTUnwrap(project(matrix_identity_float4x4))
        let away = simd_float4x4(simd_quatf(angle: .pi, axis: SIMD3(0, 1, 0)))
        XCTAssertNil(project(away))
        XCTAssertEqual(project(matrix_identity_float4x4), original)
        var outside = matrix_identity_float4x4
        outside.columns.3.x = 2
        XCTAssertNil(project(outside))
    }

    func testPartialVisibilityDoesNotRequireAnEntireObjectBoxInFrame() throws {
        let partial = CGRect(x: -0.1, y: 0.2, width: 0.3, height: 0.4)
        let clipped = try XCTUnwrap(SurfaceProjection.visibleRectangle(partial))
        XCTAssertEqual(clipped.minX, 0)
        XCTAssertEqual(clipped.width, 0.2, accuracy: 0.0001)
        XCTAssertNil(SurfaceProjection.visibleRectangle(CGRect(x: -0.4, y: 0.2, width: 0.3, height: 0.4)))
        XCTAssertNil(SurfaceProjection.visibleRectangle(CGRect(x: -0.29, y: 0.2, width: 0.3, height: 0.4)))
        XCTAssertNil(SurfaceProjection.visibleRectangle(CGRect(x: Double.nan, y: 0, width: 0.3, height: 0.4)))
    }
}
