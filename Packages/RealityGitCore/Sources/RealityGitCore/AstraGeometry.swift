import Foundation

/// Validates image geometry, then samples physical depth inside Astra's silhouette.
/// This never decides identity from Apple's segmentation, color or apparent size.
public enum AstraGeometry {
    public static let sourceLifetime: Double = 30
    public static let authorityLifetime: Double = 10

    public static func rectangle(_ values: [Double]) -> CGRect? {
        guard values.count == 4, values.allSatisfy(\.isFinite) else { return nil }
        return LocalTrackingEvidence.validSelectionRectangle(CGRect(x: values[0], y: values[1], width: values[2], height: values[3]))
    }

    public static func validOutline(_ outline: [[Double]], rect: [Double]) -> Bool {
        guard let box = rectangle(rect), (3...16).contains(outline.count),
              outline.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) &&
                  $0[0] >= box.minX - 0.002 && $0[0] <= box.maxX + 0.002 &&
                  $0[1] >= box.minY - 0.002 && $0[1] <= box.maxY + 0.002 &&
                  (0...1).contains($0[0]) && (0...1).contains($0[1]) }) else { return false }
        var area = 0.0
        for i in outline.indices {
            let a = outline[i], b = outline[(i + 1) % outline.count]
            area += a[0] * b[1] - b[0] * a[1]
        }
        return abs(area) > 0.00001
    }

    public static func contains(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var previous = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[previous]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            previous = i
        }
        return inside
    }

    public static func depthPixels(depth: [Float], confidence: [UInt8], width: Int, height: Int,
                                   polygon: [CGPoint]) -> [(Int, Int)] {
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              depth.count == width * height, confidence.count == depth.count,
              polygon.count >= 3, polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return [] }
        var pixels: [(Int, Int)] = []
        var depths: [Float] = []
        let xs = polygon.map { max(0, min(1, $0.x)) * Double(width) }
        let ys = polygon.map { max(0, min(1, $0.y)) * Double(height) }
        let minX = Int(floor(xs.min()!)), maxX = min(width, Int(ceil(xs.max()!)))
        let minY = Int(floor(ys.min()!)), maxY = min(height, Int(ceil(ys.max()!)))
        pixels.reserveCapacity((maxX - minX) * (maxY - minY))
        depths.reserveCapacity((maxX - minX) * (maxY - minY))
        for y in minY..<maxY {
            // Intersect the silhouette once per row, rather than walking all its edges
            // again for every depth pixel. Preserve the same pixel-center inclusion rule.
            let row = (Double(y) + 0.5) / Double(height)
            var crossings: [Double] = []
            var previous = polygon.count - 1
            for index in polygon.indices {
                let a = polygon[index], b = polygon[previous]
                if (a.y > row) != (b.y > row) {
                    crossings.append((b.x - a.x) * (row - a.y) / (b.y - a.y) + a.x)
                }
                previous = index
            }
            crossings.sort()
            var crossing = 0, inside = crossings.count.isMultiple(of: 2) == false
            for x in minX..<maxX {
                let column = (Double(x) + 0.5) / Double(width)
                while crossing < crossings.count, crossings[crossing] <= column {
                    inside.toggle(); crossing += 1
                }
                let i = y * width + x
                guard inside, confidence[i] >= 1, depth[i].isFinite, (0.1...8).contains(depth[i]) else { continue }
                pixels.append((x, y)); depths.append(depth[i])
            }
        }
        guard depths.count >= 12 else { return [] }
        let sorted = depths.sorted(), median = sorted[sorted.count / 2]
        let deviations = depths.map { abs($0 - median) }.sorted()
        let tolerance = max(0.04, min(0.35, deviations[deviations.count / 2] * 3))
        return pixels.enumerated().compactMap { abs(depths[$0.offset] - median) <= tolerance ? $0.element : nil }
    }
}
