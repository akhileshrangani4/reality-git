import Foundation

/// A bounded connected patch of measured depth around a tap. This is temporary capture
/// feedback, never object identity, a remembered reference, or evidence of movement.
public enum DepthPreview {
    public static func pixels(depth: [Float], confidence: [UInt8], width: Int, height: Int,
                              point: CGPoint, focalLength: Float, selection: CGRect? = nil) -> [(Int, Int)] {
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              depth.count == width * height, confidence.count == depth.count,
              point.x.isFinite, point.y.isFinite, (0...1).contains(point.x), (0...1).contains(point.y),
              focalLength.isFinite, focalLength > 0 else { return [] }
        if let selection, LocalTrackingEvidence.validSelectionRectangle(selection) == nil { return [] }
        let region = selection?.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        func inRegion(_ x: Int, _ y: Int) -> Bool {
            region?.contains(CGPoint(x: (Double(x) + 0.5) / Double(width), y: (Double(y) + 0.5) / Double(height))) ?? true
        }
        let cx = min(width - 1, Int(point.x * Double(width))), cy = min(height - 1, Int(point.y * Double(height)))
        func valid(_ index: Int) -> Bool { confidence[index] >= 1 && depth[index].isFinite && (0.15...8).contains(depth[index]) }
        var seed: Int?
        var distance = Int.max
        for y in max(0, cy - 2)...min(height - 1, cy + 2) {
            for x in max(0, cx - 2)...min(width - 1, cx + 2) where valid(y * width + x) {
                guard inRegion(x, y) else { continue }
                let squared = (x - cx) * (x - cx) + (y - cy) * (y - cy)
                if squared < distance { distance = squared; seed = y * width + x }
            }
        }
        guard let seed else { return [] }
        let z = depth[seed]
        let maximumRadius = max(3, Float(min(width, height)) * 0.24)
        let radius = Int(max(3, min(maximumRadius, 0.3 * focalLength / z)))
        let tolerance = max(0.025, min(0.12, z * 0.07))
        var visited = [Bool](repeating: false, count: depth.count)
        var queue = [seed], cursor = 0
        visited[seed] = true
        while cursor < queue.count {
            let current = queue[cursor]; cursor += 1
            let x = current % width, y = current / width
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                let next = ny * width + nx
                guard !visited[next] else { continue }
                visited[next] = true
                if let region {
                    guard region.contains(CGPoint(x: (Double(nx) + 0.5) / Double(width), y: (Double(ny) + 0.5) / Double(height))) else { continue }
                } else {
                    guard abs(nx - cx) <= radius, abs(ny - cy) <= radius else { continue }
                }
                guard valid(next), abs(depth[next] - z) <= tolerance,
                      abs(depth[next] - depth[current]) <= tolerance * 0.7 else { continue }
                queue.append(next)
            }
        }
        return queue.count >= 12 ? queue.map { ($0 % width, $0 / width) } : []
    }
}

/// Recent pixel tracks can carry a newly confirmed silhouette forward without replaying images.
/// The cache only matches the exact source frame within uninterrupted, fresh local continuity.
public struct TraceContinuityCache: Sendable {
    private struct Entry: Sendable { let time: Double; let rect: CGRect }
    private var entries: [Entry] = []
    public init() {}
    public mutating func reset() { entries.removeAll(keepingCapacity: true) }
    public mutating func record(rect: CGRect?, confidence: Float, time: Double) {
        guard let rect = rect.flatMap(LocalTrackingEvidence.validSelectionRectangle), confidence.isFinite,
              confidence >= 0.75, time.isFinite else { reset(); return }
        if let last = entries.last, time <= last.time || time - last.time > 0.25 { reset() }
        entries.append(Entry(time: time, rect: rect))
        entries.removeAll { time - $0.time > AstraGeometry.authorityLifetime }
        if entries.count > 360 { entries.removeFirst(entries.count - 360) }
    }
    public func sourceRect(matching rect: CGRect, time: Double, now: Double) -> CGRect? {
        guard time.isFinite, now.isFinite, now >= time, now - time <= AstraGeometry.authorityLifetime,
              let last = entries.last, now >= last.time, now - last.time <= 0.25,
              let entry = entries.first(where: { abs($0.time - time) < 0.0001 }) else { return nil }
        let intersection = entry.rect.intersection(rect)
        guard !intersection.isNull else { return nil }
        let overlap = intersection.width * intersection.height
        let union = entry.rect.width * entry.rect.height + rect.width * rect.height - overlap
        return union > 0 && overlap / union >= 0.65 ? entry.rect : nil
    }
}
