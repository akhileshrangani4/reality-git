import Foundation

public enum Projection {
    /// Input pixels use the native camera image's top-left origin. Output uses
    /// ARKit camera axes: x right, y up, and negative z in front of the camera.
    public static func unproject(u: Float, v: Float, depth: Float,
                                 fx: Float, fy: Float, cx: Float, cy: Float) -> SIMD3<Float>? {
        guard [u, v, depth, fx, fy, cx, cy].allSatisfy(\.isFinite),
              depth > 0, fx > 0, fy > 0 else { return nil }
        let result = SIMD3((u - cx) * depth / fx, -(v - cy) * depth / fy, -depth)
        guard result.x.isFinite, result.y.isFinite, result.z.isFinite else { return nil }
        return result
    }

    public static func imagePixel(depthX: Int, depthY: Int,
                                  depthWidth: Int, depthHeight: Int,
                                  imageWidth: Int, imageHeight: Int) -> SIMD2<Float>? {
        guard depthWidth > 0, depthHeight > 0, imageWidth > 0, imageHeight > 0,
              (0..<depthWidth).contains(depthX), (0..<depthHeight).contains(depthY) else { return nil }
        return SIMD2((Float(depthX) + 0.5) * Float(imageWidth) / Float(depthWidth),
                     (Float(depthY) + 0.5) * Float(imageHeight) / Float(depthHeight))
    }

    public static func medianPosition(_ points: [SIMD3<Float>]) -> SIMD3<Float>? {
        let valid = points.filter { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
        guard !valid.isEmpty else { return nil }
        func median(_ values: [Float]) -> Float {
            let sorted = values.sorted()
            let mid = sorted.count / 2
            return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
        }
        return SIMD3(median(valid.map(\.x)), median(valid.map(\.y)), median(valid.map(\.z)))
    }
}
