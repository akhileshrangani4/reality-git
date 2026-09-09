import Foundation
import simd

/// Projects measured world points for the current camera. Camera motion changes screen
/// coordinates, not the remembered identity or the object's measured world position.
public enum SurfaceProjection {
    public static func rectangle(points: [SIMD3<Float>], cameraToWorld: simd_float4x4,
                                 intrinsics: simd_float3x3, imageWidth: Int, imageHeight: Int) -> CGRect? {
        let fx = intrinsics[0][0], fy = intrinsics[1][1], cx = intrinsics[2][0], cy = intrinsics[2][1]
        guard imageWidth > 0, imageHeight > 0, fx > 0, fy > 0,
              [fx, fy, cx, cy].allSatisfy(\.isFinite) else { return nil }
        let worldToCamera = cameraToWorld.inverse
        var minX = Float.infinity, minY = Float.infinity, maxX = -Float.infinity, maxY = -Float.infinity
        var visible = 0
        for point in points {
            let p = worldToCamera * SIMD4(point, 1)
            guard p.x.isFinite, p.y.isFinite, p.z.isFinite, p.z < -0.1 else { continue }
            let x = (fx * p.x / -p.z + cx) / Float(imageWidth)
            let y = (fy * -p.y / -p.z + cy) / Float(imageHeight)
            guard x.isFinite, y.isFinite else { continue }
            minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            visible += 1
        }
        guard visible >= 3 else { return nil }
        return visibleRectangle(CGRect(x: Double(minX), y: Double(minY),
            width: Double(maxX - minX), height: Double(maxY - minY)), minimumVisibleFraction: 0)
    }

    /// A partially visible Vision box can retain its tracking observation; a fully absent
    /// object cannot. Do not clamp the observation itself, which would distort its outline.
    public static func visibleRectangle(_ rect: CGRect, minimumVisibleFraction: Double = 0.2) -> CGRect? {
        guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
              rect.width > 0, rect.height > 0 else { return nil }
        let visible = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !visible.isNull, !visible.isEmpty,
              visible.width * visible.height / (rect.width * rect.height) >= minimumVisibleFraction else { return nil }
        return visible
    }
}
