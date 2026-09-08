import Foundation
import simd

public struct ReferenceState: Sendable {
    public let captureKey: ObservationKey
    public let transform: simd_float4x4
    public let bounds: SIMD3<Float>
    public let appearanceReference: String?
    public var position: SIMD3<Float> { SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z) }
    public init?(key: ObservationKey, position: SIMD3<Float>, bounds: SIMD3<Float>, appearanceReference: String? = nil) {
        guard [position.x, position.y, position.z, bounds.x, bounds.y, bounds.z, Float(key.captureTime)].allSatisfy(\.isFinite),
              bounds.x > 0, bounds.y > 0, bounds.z > 0 else { return nil }
        captureKey = key; self.bounds = bounds; self.appearanceReference = appearanceReference
        var matrix = matrix_identity_float4x4
        matrix.columns.3 = SIMD4(position.x, position.y, position.z, 1)
        transform = matrix
    }
}
