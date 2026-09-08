import Foundation
import simd

/// A conservative fallback for a tight explicit selection. A separated foreground
/// component is required; a flat desk or wall is never accepted as the object.
public enum ForegroundDepth {
    public static func allowsFallback(measuredDepth: Float, supportedWorld: SIMD3<Float>, cameraToWorld: simd_float4x4) -> Bool {
        let p = cameraToWorld.inverse * SIMD4(supportedWorld.x, supportedWorld.y, supportedWorld.z, 1)
        return measuredDepth.isFinite && p.z < -0.1 && abs(measuredDepth + p.z) <= 0.05
    }

    public static func indices(depth: [Float], confidence: [UInt8], width: Int, height: Int, rect: CGRect) -> [Int] {
        guard width > 0, height > 0, depth.count == width * height, confidence.count == depth.count,
              [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy(\.isFinite), rect.width > 0, rect.height > 0 else { return [] }
        let left = max(0, Int(rect.minX * Double(width))), right = min(width - 1, Int(rect.maxX * Double(width)))
        let top = max(0, Int(rect.minY * Double(height))), bottom = min(height - 1, Int(rect.maxY * Double(height)))
        guard right - left >= 5, bottom - top >= 5 else { return [] }
        func valid(_ i: Int) -> Bool { confidence[i] >= 2 && depth[i].isFinite && depth[i] > 0.15 && depth[i] < 4 }
        var ring: [Float] = [], center: [Int] = []
        let marginX = max(2, Int(Double(right - left + 1) * 0.2))
        let marginY = max(2, Int(Double(bottom - top + 1) * 0.2))
        for y in max(0, top - marginY)...min(height - 1, bottom + marginY) {
            for x in max(0, left - marginX)...min(width - 1, right + marginX) {
                guard x < left || x > right || y < top || y > bottom else { continue }
                let i = y * width + x
                if valid(i) { ring.append(depth[i]) }
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
        guard ring.count >= 12, center.count >= 12 else { return [] }
        ring.sort(); center.sort { depth[$0] < depth[$1] }
        let seed = center[center.count / 5], foreground = depth[seed]
        // At least 75% of the external ring must be behind the seed, preventing a
        // component cut out of the support plane from becoming a reference.
        guard ring[ring.count / 4] - foreground > 0.07 else { return [] }
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
