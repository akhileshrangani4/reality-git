import Foundation
import simd

public struct CapturedPoint: Sendable {
    public let position: SIMD3<Float>
    public let color: SIMD3<Float>
    public init(position: SIMD3<Float>, color: SIMD3<Float>) { self.position = position; self.color = color }
}

public struct ReferenceState: Sendable {
    public let captureKey: ObservationKey
    public let transform: simd_float4x4
    public let bounds: SIMD3<Float>
    public let points: [CapturedPoint]
    public let appearanceReference: String?
    public var position: SIMD3<Float> { SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z) }
    public init?(key: ObservationKey, position: SIMD3<Float>, bounds: SIMD3<Float>, appearanceReference: String? = nil, points: [CapturedPoint] = []) {
        guard [position.x, position.y, position.z, bounds.x, bounds.y, bounds.z, Float(key.captureTime)].allSatisfy(\.isFinite),
              bounds.x > 0, bounds.y > 0, bounds.z > 0 else { return nil }
        self.points = Array(points.filter { [$0.position.x, $0.position.y, $0.position.z, $0.color.x, $0.color.y, $0.color.z].allSatisfy(\.isFinite) }.prefix(8000))
        captureKey = key; self.bounds = bounds; self.appearanceReference = appearanceReference
        var matrix = matrix_identity_float4x4
        matrix.columns.3 = SIMD4(position.x, position.y, position.z, 1)
        transform = matrix
    }
}

public enum ReferenceVisibility {
    /// A temporal image box is not evidence of an occupied physical location.
    public static func occupiedRect(trackedRect: CGRect?, position: SIMD3<Float>?, bounds: SIMD3<Float>?, confidence: Float) -> CGRect? {
        guard let position, let bounds, confidence.isFinite, confidence >= 0.6,
              [position.x, position.y, position.z, bounds.x, bounds.y, bounds.z].allSatisfy(\.isFinite),
              bounds.x > 0, bounds.y > 0, bounds.z > 0 else { return nil }
        return trackedRect
    }

    public static func classify(differences: [Float], projectedCount: Int, totalCount: Int) -> VisibilityEvidence {
        guard totalCount >= 12, projectedCount * 5 >= totalCount * 4,
              differences.count >= 12, differences.count * 5 >= projectedCount * 4 else { return .unknown }
        if differences.filter({ $0 < -0.06 }).count * 5 > differences.count { return .occluded }
        if differences.filter({ $0 > 0.08 }).count * 10 >= differences.count * 9 { return .visibleEmpty }
        return .unknown
    }
}
