import XCTest
@testable import RealityGitCore

final class CaptureCacheTests: XCTestCase {
    private let rect = CGRect(x: 0.25, y: 0.25, width: 0.25, height: 0.5)

    func testFastSilhouetteSamplingMatchesPixelCenterRayCasting() {
        let polygons: [[CGPoint]] = [
            [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.7, y: 0.3), CGPoint(x: 0.4, y: 0.9)],
            [CGPoint(x: -0.2, y: 0.1), CGPoint(x: 1.2, y: 0.1), CGPoint(x: 0.7, y: 1.2), CGPoint(x: 0.4, y: 0.4)],
            [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.1), CGPoint(x: 0.9, y: 0.8), CGPoint(x: 0.5, y: 0.4), CGPoint(x: 0.1, y: 0.8)]
        ]
        for polygon in polygons + polygons.map({ Array($0.reversed()) }) {
            let actual = AstraGeometry.depthPixels(depth: [Float](repeating: 1, count: 64 * 48),
                confidence: [UInt8](repeating: 2, count: 64 * 48), width: 64, height: 48, polygon: polygon)
            let expected = (0..<48).flatMap { y in (0..<64).compactMap { x -> Int? in
                AstraGeometry.contains(CGPoint(x: (Double(x) + 0.5) / 64, y: (Double(y) + 0.5) / 48), polygon: polygon) ? y * 64 + x : nil
            } }
            XCTAssertEqual(actual.map { $0.1 * 64 + $0.0 }, expected)
        }
    }

    func testDepthPreviewStaysOnConnectedMeasuredSurface() {
        let width = 64, height = 48
        var depth = [Float](repeating: 3, count: width * height)
        for y in 12..<36 { for x in 16..<32 { depth[y * width + x] = 1 } }
        let pixels = DepthPreview.pixels(depth: depth, confidence: [UInt8](repeating: 2, count: depth.count),
            width: width, height: height, point: CGPoint(x: 0.375, y: 0.5), focalLength: 40)
        XCTAssertGreaterThan(pixels.count, 100)
        XCTAssertTrue(pixels.allSatisfy { depth[$0.1 * width + $0.0] == 1 })
        let clipped = DepthPreview.pixels(depth: depth, confidence: [UInt8](repeating: 2, count: depth.count),
            width: width, height: height, point: CGPoint(x: 0.375, y: 0.5), focalLength: 40,
            selection: CGRect(x: 0.3, y: 0.4, width: 0.15, height: 0.2))
        XCTAssertGreaterThan(clipped.count, 12)
        XCTAssertTrue(clipped.allSatisfy { (19...28).contains($0.0) && (19...28).contains($0.1) })
    }

    func testPreviewDoesNotInventDepthWhenUnreliableOrOutsideSelection() {
        let depth = [Float](repeating: 1, count: 64 * 48)
        for invalid in [Float.nan, 0, 20] {
            XCTAssertTrue(DepthPreview.pixels(depth: [Float](repeating: invalid, count: depth.count),
                confidence: [UInt8](repeating: 2, count: depth.count), width: 64, height: 48,
                point: CGPoint(x: 0.5, y: 0.5), focalLength: 40).isEmpty)
        }
        XCTAssertTrue(DepthPreview.pixels(depth: depth, confidence: [UInt8](repeating: 0, count: depth.count),
            width: 64, height: 48, point: CGPoint(x: 0.5, y: 0.5), focalLength: 40).isEmpty)
        XCTAssertTrue(DepthPreview.pixels(depth: depth, confidence: [UInt8](repeating: 2, count: depth.count),
            width: 64, height: 48, point: CGPoint(x: 0.8, y: 0.8), focalLength: 40, selection: rect).isEmpty)
        XCTAssertTrue(DepthPreview.pixels(depth: depth, confidence: [], width: 64, height: 48,
            point: CGPoint(x: 0.5, y: 0.5), focalLength: 40).isEmpty)
        XCTAssertLessThan(DepthPreview.pixels(depth: depth, confidence: [UInt8](repeating: 2, count: depth.count),
            width: 64, height: 48, point: CGPoint(x: 0.5, y: 0.5), focalLength: .greatestFiniteMagnitude).count, depth.count)
    }

    func testContinuityReusesExactSourceBoxThroughMotion() {
        var cache = TraceContinuityCache()
        for index in 0...180 {
            cache.record(rect: rect.offsetBy(dx: Double(index) * 0.001, dy: 0), confidence: 0.99, time: Double(index) / 30)
        }
        XCTAssertEqual(cache.sourceRect(matching: rect, time: 0, now: 6.03), rect)
        XCTAssertNil(cache.sourceRect(matching: rect, time: 0.01, now: 6.03), "A nearby frame is not the model's source")
        XCTAssertNil(cache.sourceRect(matching: rect.offsetBy(dx: 0.4, dy: 0), time: 0, now: 6.03), "Another object must reacquire")
        XCTAssertNil(cache.sourceRect(matching: rect, time: 0, now: 6.3), "Stale track must reacquire")
    }

    func testLossGapsLowConfidenceAndResetRevokeCache() {
        for confidence: Float in [0, 0.6, .nan] {
            var cache = TraceContinuityCache()
            cache.record(rect: rect, confidence: 1, time: 0)
            cache.record(rect: rect, confidence: confidence, time: 0.1)
            cache.record(rect: rect, confidence: 1, time: 0.2)
            XCTAssertNil(cache.sourceRect(matching: rect, time: 0, now: 0.2))
        }
        var cache = TraceContinuityCache()
        cache.record(rect: rect, confidence: 1, time: 0)
        cache.record(rect: rect, confidence: 1, time: 0.4)
        XCTAssertNil(cache.sourceRect(matching: rect, time: 0, now: 0.4))
        cache.reset()
        XCTAssertNil(cache.sourceRect(matching: rect, time: 0.4, now: 0.4))
    }

    func testContinuityCannotKeepOldAuthorityAliveForever() {
        var cache = TraceContinuityCache()
        for index in 0...600 { cache.record(rect: rect, confidence: 1, time: Double(index) / 30) }
        XCTAssertNil(cache.sourceRect(matching: rect, time: 0, now: 20))
        XCTAssertEqual(cache.sourceRect(matching: rect, time: 19, now: 20), rect)
    }

    func testCacheRoutingIsStableForObjectButIsolatedAcrossSelections() throws {
        let session = UUID(), object = UUID()
        func body(_ object: UUID, _ number: UInt64) throws -> [String: Any] {
            let frame = FrameRequest(key: .init(sessionID: session, objectID: object, frameID: number, captureTime: Double(number)),
                jpeg: Data([UInt8(number)]), isReference: true, seedPoint: [0.5, 0.5], modelID: "gpt-6-astra")
            return try XCTUnwrap(JSONSerialization.jsonObject(with: NativeCodexClient.observationBody(frame, reference: nil)) as? [String: Any])
        }
        let first = try body(object, 1), next = try body(object, 2), another = try body(UUID(), 3)
        XCTAssertNotNil(first["prompt_cache_key"])
        XCTAssertEqual(first["prompt_cache_key"] as? String, next["prompt_cache_key"] as? String)
        XCTAssertNotEqual(first["prompt_cache_key"] as? String, another["prompt_cache_key"] as? String)
        XCTAssertNotEqual(String(describing: first["input"]), String(describing: next["input"]), "Current images must remain fresh")
    }
}
