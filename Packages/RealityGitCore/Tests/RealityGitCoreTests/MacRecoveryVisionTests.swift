#if canImport(Vision)
import CoreGraphics
import Vision
import XCTest
@testable import RealityGitCore

final class MacRecoveryVisionTests: XCTestCase {
    func testRealVisionRecoveryAdvancesFromSourceImageToMovedTarget() throws {
        func frame(shift: Int) throws -> CGImage {
            let context = try XCTUnwrap(CGContext(data: nil, width: 320, height: 240, bitsPerComponent: 8,
                bytesPerRow: 320 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.setFillColor(CGColor(gray: 0.15, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
            for row in 0..<8 {
                for column in 0..<8 {
                    context.setFillColor(CGColor(gray: (row + column) % 2 == 0 ? 0.95 : 0.35, alpha: 1))
                    context.fill(CGRect(x: 80 + shift + column * 10, y: 80 + row * 10, width: 10, height: 10))
                }
            }
            return try XCTUnwrap(context.makeImage())
        }
        let source = try frame(shift: 0), current = try frame(shift: 8)
        let result = try MacRecoveryExecutor.recover(source: source, current: current,
            rect: CGRect(x: 0.25, y: 1.0 / 3, width: 0.25, height: 1.0 / 3),
            makeSequence: { VNSequenceRequestHandler() },
            seed: { (sequence: VNSequenceRequestHandler, frame: CGImage, box: CGRect) -> VNDetectedObjectObservation? in
                let request = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: box))
                request.trackingLevel = .accurate
                try sequence.perform([request], on: frame, orientation: .up)
                return request.results?.first as? VNDetectedObjectObservation
            }, advance: { (sequence: VNSequenceRequestHandler, frame: CGImage, previous: VNDetectedObjectObservation) -> VNDetectedObjectObservation? in
                let request = VNTrackObjectRequest(detectedObjectObservation: previous)
                request.trackingLevel = .accurate
                try sequence.perform([request], on: frame, orientation: .up)
                return request.results?.first as? VNDetectedObjectObservation
            }, accepts: { $0.confidence >= 0.6 })
        let observation = try XCTUnwrap(result?.1)
        XCTAssertGreaterThan(observation.boundingBox.minX, 0.26)
        XCTAssertEqual(observation.boundingBox.minX, 0.275, accuracy: 0.03)
    }
}
#endif
