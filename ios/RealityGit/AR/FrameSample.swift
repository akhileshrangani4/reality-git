import ARKit
import CoreVideo
import simd

/// A single owned image and copied depth/calibration snapshot. The image is
/// immutable after construction; no ARFrame is retained by the Vision worker.
final class FrameSample: @unchecked Sendable {
    let image: CVPixelBuffer
    let depth: [Float]
    let confidence: [UInt8]
    let depthWidth: Int
    let depthHeight: Int
    let intrinsics: simd_float3x3
    let cameraToWorld: simd_float4x4
    let timestamp: TimeInterval

    init?(frame: ARFrame) {
        guard let source = frame.sceneDepth,
              let image = Self.copyImage(frame.capturedImage),
              let confidenceMap = source.confidenceMap else { return nil }
        self.image = image
        intrinsics = frame.camera.intrinsics
        cameraToWorld = frame.camera.transform
        timestamp = frame.timestamp
        depthWidth = CVPixelBufferGetWidth(source.depthMap)
        depthHeight = CVPixelBufferGetHeight(source.depthMap)
        guard CVPixelBufferGetPixelFormatType(source.depthMap) == kCVPixelFormatType_DepthFloat32,
              CVPixelBufferGetPixelFormatType(confidenceMap) == kCVPixelFormatType_OneComponent8,
              CVPixelBufferGetWidth(confidenceMap) == depthWidth,
              CVPixelBufferGetHeight(confidenceMap) == depthHeight else { return nil }
        CVPixelBufferLockBaseAddress(source.depthMap, .readOnly)
        CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(source.depthMap, .readOnly)
            CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
        }
        guard let depthBase = CVPixelBufferGetBaseAddress(source.depthMap),
              let confidenceBase = CVPixelBufferGetBaseAddress(confidenceMap) else { return nil }
        var values = [Float]()
        var scores = [UInt8]()
        values.reserveCapacity(depthWidth * depthHeight)
        scores.reserveCapacity(depthWidth * depthHeight)
        for y in 0..<depthHeight {
            let row = depthBase.advanced(by: y * CVPixelBufferGetBytesPerRow(source.depthMap)).assumingMemoryBound(to: Float.self)
            let scoreRow = confidenceBase.advanced(by: y * CVPixelBufferGetBytesPerRow(confidenceMap)).assumingMemoryBound(to: UInt8.self)
            values.append(contentsOf: UnsafeBufferPointer(start: row, count: depthWidth))
            scores.append(contentsOf: UnsafeBufferPointer(start: scoreRow, count: depthWidth))
        }
        depth = values
        confidence = scores
    }

    private static func copyImage(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        var output: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault,
            CVPixelBufferGetWidth(source), CVPixelBufferGetHeight(source),
            CVPixelBufferGetPixelFormatType(source), nil, &output)
        guard result == kCVReturnSuccess, let output else { return nil }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(output, [])
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(output, [])
        }
        if CVPixelBufferIsPlanar(source) {
            for plane in 0..<CVPixelBufferGetPlaneCount(source) {
                guard let src = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                      let dst = CVPixelBufferGetBaseAddressOfPlane(output, plane) else { return nil }
                let srcStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                let dstStride = CVPixelBufferGetBytesPerRowOfPlane(output, plane)
                for row in 0..<CVPixelBufferGetHeightOfPlane(source, plane) {
                    memcpy(dst.advanced(by: row * dstStride), src.advanced(by: row * srcStride), min(srcStride, dstStride))
                }
            }
        } else {
            guard let src = CVPixelBufferGetBaseAddress(source),
                  let dst = CVPixelBufferGetBaseAddress(output) else { return nil }
            let srcStride = CVPixelBufferGetBytesPerRow(source)
            let dstStride = CVPixelBufferGetBytesPerRow(output)
            for row in 0..<CVPixelBufferGetHeight(source) {
                memcpy(dst.advanced(by: row * dstStride), src.advanced(by: row * srcStride), min(srcStride, dstStride))
            }
        }
        CVBufferPropagateAttachments(source, output)
        return output
    }
}
