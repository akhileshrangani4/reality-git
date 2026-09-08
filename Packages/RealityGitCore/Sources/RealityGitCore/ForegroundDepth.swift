import Foundation
import simd

/// A conservative fallback for a tight explicit selection. A separated foreground
/// component is required for capture. Known-object proposals may omit background
/// separation only when the caller subsequently validates the existing signature.
public enum ForegroundDepth {
    public static func allowsFallback(measuredDepth: Float, supportedWorld: SIMD3<Float>, cameraToWorld: simd_float4x4) -> Bool {
        let p = cameraToWorld.inverse * SIMD4(supportedWorld.x, supportedWorld.y, supportedWorld.z, 1)
        return measuredDepth.isFinite && p.z < -0.1 && abs(measuredDepth + p.z) <= 0.05
    }

    public static func indices(depth: [Float], confidence: [UInt8], width: Int, height: Int, rect: CGRect, requireSeparatedBackground: Bool = true) -> [Int] {
        guard width > 0, height > 0, depth.count == width * height, confidence.count == depth.count,
              [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy(\.isFinite), rect.width > 0, rect.height > 0 else { return [] }
        let left = max(0, Int(rect.minX * Double(width))), right = min(width - 1, Int(rect.maxX * Double(width)))
        let top = max(0, Int(rect.minY * Double(height))), bottom = min(height - 1, Int(rect.maxY * Double(height)))
        guard right - left >= 5, bottom - top >= 5 else { return [] }
        func valid(_ i: Int) -> Bool { confidence[i] >= 2 && depth[i].isFinite && depth[i] > 0.15 && depth[i] < 4 }
        var ring: [Float] = [], center: [Int] = []
        var normal = simd_float3x3(0)
        var target = SIMD3<Float>.zero
        func coordinate(_ x: Int, _ y: Int) -> SIMD3<Float> {
            SIMD3(Float(x - left) / Float(right - left), Float(y - top) / Float(bottom - top), 1)
        }
        let marginX = max(2, Int(Double(right - left + 1) * 0.2))
        let marginY = max(2, Int(Double(bottom - top + 1) * 0.2))
        for y in max(0, top - marginY)...min(height - 1, bottom + marginY) {
            for x in max(0, left - marginX)...min(width - 1, right + marginX) {
                guard x < left || x > right || y < top || y > bottom else { continue }
                let i = y * width + x
                if valid(i) {
                    ring.append(depth[i])
                    let q = coordinate(x, y)
                    normal += simd_float3x3(columns: (q * q.x, q * q.y, q * q.z))
                    target += q / depth[i]
                }
            }
        }
        for y in top...bottom {
            for x in left...right {
                let i = y * width + x
                guard valid(i) else { continue }
                let u = Double(x - left) / Double(right - left), v = Double(y - top) / Double(bottom - top)
                if u > 0.25 && u < 0.75 && v > 0.25 && v < 0.75 { center.append(i) }
            }
        }
        guard center.count >= 12 else { return [] }
        ring.sort(); center.sort { depth[$0] < depth[$1] }
        let seed = center[center.count / 5], foreground = depth[seed]
        if requireSeparatedBackground {
            guard ring.count >= 12 else { return [] }
            // At least 75% of the external ring must be behind the seed, preventing a
            // component cut out of the support plane from becoming a reference.
            guard ring[ring.count / 4] - foreground > 0.07 else { return [] }
            // Perspective depth of a plane has affine inverse depth. A one-sided
            // corner ring can be farther solely because the support plane slopes;
            // require separation from its extrapolated depth at the actual seed too.
            guard abs(simd_determinant(normal)) > 0.00001 else { return [] }
            let plane = normal.inverse * target
            let inverseDepth = simd_dot(plane, coordinate(seed % width, seed / width))
            guard inverseDepth.isFinite, inverseDepth > 0,
                  1 / inverseDepth - foreground > 0.07 else { return [] }
        }
        var queue = [seed], seen: Set<Int> = [seed], cursor = 0
        while cursor < queue.count {
            let i = queue[cursor]; cursor += 1
            let x = i % width, y = i / width
            for (nx, ny) in [(x-1,y),(x+1,y),(x,y-1),(x,y+1)] {
                guard nx >= left, nx <= right, ny >= top, ny <= bottom else { continue }
                let n = ny * width + nx
                guard !seen.contains(n), valid(n), abs(depth[n] - foreground) <= 0.045 else { continue }
                seen.insert(n); queue.append(n)
            }
        }
        guard queue.count >= 12 else { return [] }
        return Array(queue.prefix(8000))
    }
}

/// Association checks for a freshly separated component. Unlike propagated
/// support, this evidence can move in depth, but must retain object appearance.
public struct DepthComponentSignature: Sendable {
    public static func normalizedSupport(imagePoints: [SIMD2<Float>], trackingRect: CGRect) -> [SIMD2<Float>] {
        guard trackingRect.width > 0, trackingRect.height > 0 else { return [] }
        return imagePoints.map { SIMD2(($0.x - Float(trackingRect.minX)) / Float(trackingRect.width), ($0.y - Float(trackingRect.minY)) / Float(trackingRect.height)) }
    }

    private let size: SIMD2<Float>
    private let color: SIMD3<Float>
    private let cells: Set<Int>
    public init?(points: [SIMD3<Float>], colors: [SIMD3<Float>], support: [SIMD2<Float>]) {
        guard points.count >= 12, colors.count == points.count, support.count == points.count else { return nil }
        var low = points[0], high = low
        for p in points { low = simd_min(low, p); high = simd_max(high, p) }
        size = SIMD2(high.x - low.x, high.y - low.y)
        color = colors.reduce(.zero, +) / Float(colors.count)
        cells = Set(support.filter { $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.x <= 1 && $0.y >= 0 && $0.y <= 1 }.map { min(7, Int($0.y * 8)) * 8 + min(7, Int($0.x * 8)) })
        guard size.x > 0.005, size.y > 0.005, [size.x, size.y, color.x, color.y, color.z].allSatisfy(\.isFinite), !cells.isEmpty else { return nil }
    }
    public func accepts(_ candidate: DepthComponentSignature, confidence: Float) -> Bool {
        rejectionReason(candidate, confidence: confidence) == nil
    }
    public func rejectionReason(_ candidate: DepthComponentSignature, confidence: Float) -> String? {
        guard confidence >= 0.8, confidence.isFinite else { return "tracking confidence" }
        guard candidate.size.x / size.x >= 0.7, candidate.size.x / size.x <= 1.3,
              candidate.size.y / size.y >= 0.7, candidate.size.y / size.y <= 1.3 else { return "metric size" }
        guard simd_distance(color, candidate.color) <= 0.25 else { return "color" }
        let intersection = cells.intersection(candidate.cells).count
        guard intersection * 10 >= cells.count * 7 && intersection * 10 >= candidate.cells.count * 7 else { return "support shape" }
        return nil
    }
}
