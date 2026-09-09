import CoreVideo
import Foundation
import RealityGitCore
import simd

enum CaptureGeometry {
    static func measure(_ sample: FrameSample, polygon: [CGPoint]) -> ReferenceCapture? {
        let pixels = AstraGeometry.depthPixels(depth: sample.depth, confidence: sample.confidence,
            width: sample.depthWidth, height: sample.depthHeight, polygon: polygon)
        return measure(sample, pixels: pixels)
    }

    static func measure(_ sample: FrameSample, pixels: [(Int, Int)], maximumPoints: Int = ReferenceCapture.maximumPointCount) -> ReferenceCapture? {
        guard pixels.count >= 12 else { return nil }
        let width = CVPixelBufferGetWidth(sample.image), height = CVPixelBufferGetHeight(sample.image)
        let fx = sample.intrinsics[0][0], fy = sample.intrinsics[1][1]
        let cx = sample.intrinsics[2][0], cy = sample.intrinsics[2][1]
        guard [fx, fy, cx, cy].allSatisfy(\.isFinite), fx > 0, fy > 0,
              width > 0, height > 0, sample.depthWidth > 0, sample.depthHeight > 0 else { return nil }
        let raysX = (0..<sample.depthWidth).map { ((Float($0) + 0.5) * Float(width) / Float(sample.depthWidth) - cx) / fx }
        let raysY = (0..<sample.depthHeight).map { -((Float($0) + 0.5) * Float(height) / Float(sample.depthHeight) - cy) / fy }
        var points: [SIMD3<Float>] = [], acceptedPixels: [(Int, Int)] = []
        points.reserveCapacity(min(maximumPoints, pixels.count)); acceptedPixels.reserveCapacity(min(maximumPoints, pixels.count))
        let step = max(1, Int(ceil(Double(pixels.count) / Double(maximumPoints))))
        for i in stride(from: 0, to: pixels.count, by: step) {
            let (x, y) = pixels[i]
            let z = sample.depth[y * sample.depthWidth + x]
            let world = sample.cameraToWorld * SIMD4(raysX[x] * z, raysY[y] * z, -z, 1)
            guard world.x.isFinite, world.y.isFinite, world.z.isFinite else { continue }
            points.append(SIMD3(world.x, world.y, world.z)); acceptedPixels.append((x, y))
        }
        guard points.count >= 12 else { return nil }
        // Each axis is sorted once for both the median center and robust extent.
        func summarize(_ values: [Float]) -> (center: Float, extent: Float) {
            let sorted = values.sorted(), mid = values.count / 2
            let center = values.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
            let extent = max(0.03, sorted[Int(Double(sorted.count - 1) * 0.95)] - sorted[Int(Double(sorted.count - 1) * 0.05)])
            return (center, extent)
        }
        let x = summarize(points.map(\.x)), y = summarize(points.map(\.y)), z = summarize(points.map(\.z))
        let center = SIMD3(x.center, y.center, z.center), bounds = SIMD3(x.extent, y.extent, z.extent)
        let colors = sample.colors(at: acceptedPixels)
        return ReferenceCapture(timestamp: sample.timestamp, position: center, bounds: bounds,
            points: zip(points, colors).map { CapturedPoint(position: $0.0 - center, color: $0.1) })
    }
    static func preview(_ sample: FrameSample, selection: ObjectSelection) -> (ReferenceCapture, CGRect)? {
        let point: CGPoint, rectangle: CGRect?
        switch selection {
        case .point(let value): point = value; rectangle = nil
        case .rectangle(let value): point = CGPoint(x: value.midX, y: value.midY); rectangle = value
        }
        let pixels = DepthPreview.pixels(depth: sample.depth, confidence: sample.confidence,
            width: sample.depthWidth, height: sample.depthHeight, point: point,
            focalLength: sample.intrinsics[0][0] * Float(sample.depthWidth) / Float(CVPixelBufferGetWidth(sample.image)),
            selection: rectangle)
        guard let capture = measure(sample, pixels: pixels, maximumPoints: 1400),
              let minX = pixels.map(\.0).min(), let maxX = pixels.map(\.0).max(),
              let minY = pixels.map(\.1).min(), let maxY = pixels.map(\.1).max() else { return nil }
        let rect = CGRect(x: Double(minX) / Double(sample.depthWidth), y: Double(minY) / Double(sample.depthHeight),
            width: Double(maxX - minX + 1) / Double(sample.depthWidth), height: Double(maxY - minY + 1) / Double(sample.depthHeight))
        return (capture, rect)
    }
}
