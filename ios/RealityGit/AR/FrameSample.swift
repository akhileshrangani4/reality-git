import ARKit
import CoreVideo
import RealityGitCore
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

extension FrameSample {
    /// A measured aiming point for capture feedback, not an object identity or reference.
    func captureAim(at point: CGPoint) -> SIMD3<Float>? {
        guard point.x.isFinite, point.y.isFinite, (0...1).contains(point.x),
              (0...1).contains(point.y) else { return nil }
        let x = min(depthWidth - 1, Int(point.x * Double(depthWidth)))
        let y = min(depthHeight - 1, Int(point.y * Double(depthHeight)))
        var depths: [Float] = []
        for row in max(0, y - 2)...min(depthHeight - 1, y + 2) {
            for column in max(0, x - 2)...min(depthWidth - 1, x + 2) {
                let index = row * depthWidth + column
                let value = depth[index]
                if confidence[index] >= 1, value.isFinite, (0.15...8).contains(value) { depths.append(value) }
            }
        }
        guard depths.count >= 3 else { return nil }
        depths.sort()
        guard let camera = RealityGitCore.Projection.unproject(
            u: Float(point.x) * Float(CVPixelBufferGetWidth(image)),
            v: Float(point.y) * Float(CVPixelBufferGetHeight(image)), depth: depths[depths.count / 2],
            fx: intrinsics[0][0], fy: intrinsics[1][1], cx: intrinsics[2][0], cy: intrinsics[2][1]) else { return nil }
        let world = cameraToWorld * SIMD4(camera, 1)
        return SIMD3(world.x, world.y, world.z)
    }

    /// Camera YCbCr sampled only at accepted depth pixels.
    func colors(at pixels: [(Int, Int)]) -> [SIMD3<Float>] {
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard CVPixelBufferGetPlaneCount(image) == 2,
              let yBase = CVPixelBufferGetBaseAddressOfPlane(image, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(image, 1) else {
            return pixels.map { _ in SIMD3(repeating: 0.7) }
        }
        let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
        return pixels.map { pixel in
            let x = min(width - 1, pixel.0 * width / depthWidth)
            let y = min(height - 1, pixel.1 * height / depthHeight)
            let luma = Float(yBase.assumingMemoryBound(to: UInt8.self)[y * CVPixelBufferGetBytesPerRowOfPlane(image, 0) + x]) / 255
            let uv = uvBase.assumingMemoryBound(to: UInt8.self)
            let index = (y / 2) * CVPixelBufferGetBytesPerRowOfPlane(image, 1) + (x / 2) * 2
            let cb = Float(uv[index]) / 255 - 0.5, cr = Float(uv[index + 1]) / 255 - 0.5
            return simd_clamp(SIMD3(luma + 1.402 * cr, luma - 0.344136 * cb - 0.714136 * cr, luma + 1.772 * cb), SIMD3(repeating: 0), SIMD3(repeating: 1))
        }
    }
}
