import CoreGraphics
import XCTest
@testable import RealityGitCore

final class ImageCoordinatesTests: XCTestCase {
    func testPortraitRotationMapsToNativeImage() {
        let rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1, ty: 0)
        let point = ImageCoordinates.imagePoint(viewPoint: CGPoint(x: 75, y: 40),
            viewport: CGSize(width: 100, height: 200), displayTransform: rotation)
        XCTAssertEqual(point?.x ?? -1, 0.2, accuracy: 1e-6)
        XCTAssertEqual(point?.y ?? -1, 0.25, accuracy: 1e-6)
    }

    func testAspectFillCropIsInverted() {
        let crop = CGAffineTransform(a: 2, b: 0, c: 0, d: 1, tx: -0.5, ty: 0)
        let point = ImageCoordinates.imagePoint(viewPoint: .zero,
            viewport: CGSize(width: 100, height: 100), displayTransform: crop)
        XCTAssertEqual(point, CGPoint(x: 0.25, y: 0))
    }

    func testInvalidViewportAndTransformAreRejected() {
        XCTAssertNil(ImageCoordinates.imagePoint(viewPoint: .zero, viewport: .zero, displayTransform: .identity))
        XCTAssertNil(ImageCoordinates.imagePoint(viewPoint: .zero, viewport: CGSize(width: 100, height: 100),
            displayTransform: CGAffineTransform(scaleX: 0, y: 0)))
    }

    func testVisionRectangleUsesOppositeVerticalOrigin() {
        let rect = CGRect(x: 0.2, y: 0.1, width: 0.3, height: 0.2)
        let converted = ImageCoordinates.topLeftRect(visionRect: rect)
        XCTAssertEqual(converted.minY, 0.7, accuracy: 1e-6)
        let restored = ImageCoordinates.visionRect(topLeftRect: converted)
        XCTAssertEqual(restored.minY, rect.minY, accuracy: 1e-6)
    }
}
