import RealityKit
import RealityGitCore
import UIKit
import Metal

@MainActor
final class DiffRenderer {
    private(set) var status = "Capturing depth shape…"
    private var red: AnchorEntity?
    private var green: AnchorEntity?
    private var referenceKey: ObservationKey?
    func reset() {
        red?.removeFromParent(); green?.removeFromParent()
        red = nil; green = nil; referenceKey = nil
    }
    func update(in view: ARView, reference: ReferenceState?, current: SIMD3<Float>?,
                showRed: Bool, showGreen: Bool, reliable: Bool) {
        guard let reference else { reset(); return }
        if referenceKey != reference.captureKey {
            reset(); referenceKey = reference.captureKey
            do {
                red = try splats(reference: reference, tint: SIMD3(1, 0.15, 0.1))
                green = try splats(reference: reference, tint: SIMD3(0.1, 1, 0.25))
                status = "Gaussian shape ready · \(reference.points.count) points"
                print("Gaussian ghost ready: \(reference.points.count) captured surface points")
            } catch {
                status = "Shape renderer unavailable · bounds preview"
                print("Gaussian ghost unavailable: \(error)")
                red = box(position: reference.position, size: reference.bounds, color: .systemRed)
                green = box(position: reference.position, size: reference.bounds, color: .systemGreen)
            }
            if let red { view.scene.addAnchor(red) }
            if let green { view.scene.addAnchor(green) }
        }
        red?.isEnabled = reliable && showRed
        green?.isEnabled = reliable && showGreen && current != nil
        if let current { green?.setPosition(current, relativeTo: nil) }
    }
    private func splats(reference: ReferenceState, tint: SIMD3<Float>) throws -> AnchorEntity {
        let stride = 60
        let byteCount = reference.points.count * stride
        let buffer = try LowLevelBuffer(descriptor: .init(capacity: (byteCount + 15) & ~15, sizeMultiple: 16))
        buffer.withUnsafeMutableBytes { bytes in
            let values = bytes.bindMemory(to: Float.self)
            for (index, point) in reference.points.enumerated() {
                let base = index * 15
                let color = point.color * 0.35 + tint * 0.65
                let data: [Float] = [point.position.x, point.position.y, point.position.z,
                    0.006, 0.006, 0.006, 1, 0, 0, 0, 0.25,
                    (color.x - 0.5) / 0.2820948, (color.y - 0.5) / 0.2820948, (color.z - 0.5) / 0.2820948, 0]
                for i in 0..<15 { values[base + i] = data[i] }
            }
        }
        buffer.bytesUsed = byteCount
        func descriptor(_ format: MTLAttributeFormat, _ offset: Int) -> GaussianSplatResource.BufferDescriptor {
            .init(buffer: buffer, format: format, stride: stride, offset: offset)
        }
        let resource = GaussianSplatResource(try .init(count: reference.points.count,
            position: descriptor(.float3, 0), scale: descriptor(.float3, 12), rotation: descriptor(.float4, 24),
            opacity: descriptor(.float, 40), sphericalHarmonics: (descriptor(.float3, 44), .zero)))
        resource.scaleActivation = .identity
        resource.opacityActivation = .identity
        let entity = Entity()
        entity.components.set(GaussianSplatComponent(resource))
        let anchor = AnchorEntity(world: reference.position)
        anchor.addChild(entity)
        return anchor
    }

    private func box(position: SIMD3<Float>, size: SIMD3<Float>, color: UIColor) -> AnchorEntity {
        let anchor = AnchorEntity(world: position)
        var material = UnlitMaterial(color: color)
        material.blending = .transparent(opacity: .init(floatLiteral: 0.25))
        let entity = ModelEntity(mesh: .generateBox(size: size), materials: [material])
        anchor.addChild(entity)
        return anchor
    }
}
