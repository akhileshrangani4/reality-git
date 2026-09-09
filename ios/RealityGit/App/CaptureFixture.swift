#if DEBUG
import CoreImage
import RealityGitCore
import simd

enum CaptureFixture {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    static func frame(time: Double, offset: Float, hidden: Bool = false, cameraX: Float = 0) throws -> FrameSample {
        let width = 1920, height = 1440, dw = 256, dh = 192
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else {
            throw NativeCodexError.invalidResponse
        }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let x = (0.25 + Double(offset)) * Double(width)
        let background = CIImage(color: CIColor(red: 0.12, green: 0.14, blue: 0.17)).cropped(to: bounds)
        let box = CIImage(color: CIColor(red: 0.95, green: 0.12, blue: 0.08))
            .cropped(to: CGRect(x: x, y: 360, width: 480, height: 720))
        let patch = CIImage(color: .white).cropped(to: CGRect(x: x + 90, y: 600, width: 100, height: 120))
        context.render(hidden ? background : patch.composited(over: box.composited(over: background)), to: buffer)
        var depth = [Float](repeating: 3, count: dw * dh)
        if !hidden {
            let left = max(0, min(dw, Int((0.25 + offset) * Float(dw))))
            let right = max(0, min(dw, Int((0.5 + offset) * Float(dw))))
            for y in 48..<144 {
                for x in left..<right { depth[y * dw + x] = 1 }
            }
        }
        var pose = matrix_identity_float4x4
        pose.columns.3.x = cameraX
        return FrameSample(image: buffer, depth: depth, confidence: [UInt8](repeating: 2, count: depth.count),
            depthWidth: dw, depthHeight: dh, intrinsics: simd_float3x3(SIMD3(1200, 0, 0), SIMD3(0, 1200, 0), SIMD3(960, 720, 1)),
            cameraToWorld: pose, timestamp: time)
    }
}
#endif
