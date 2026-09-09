import RealityKit
import RealityGitCore
import UIKit
import Metal

@MainActor
final class DiffRenderer {
    private(set) var status = "Capturing depth shape…"
    private var red: AnchorEntity?
    private var green: AnchorEntity?
    private var greenCloud: SplatCloud?
    private var greenUsesBounds = false
    private var greenTimestamp: Double?
    private var referenceKey: ObservationKey?
    func hide() {
        red?.isEnabled = false
        green?.isEnabled = false
    }
    func reset() {
        red?.removeFromParent(); green?.removeFromParent()
        red = nil; green = nil; referenceKey = nil
        greenCloud = nil; greenUsesBounds = false; greenTimestamp = nil
    }
    func update(in view: ARView, reference: ReferenceState?, current: ReferenceCapture?,
                showRed: Bool, showGreen: Bool, reliable: Bool) {
        guard let reference else { reset(); return }
        if referenceKey != reference.captureKey {
            reset(); referenceKey = reference.captureKey
            do {
                red = try SplatCloud(points: reference.points, position: reference.position,
                    tint: SIMD3(1, 0.15, 0.1), radius: 0.006, opacity: 0.25).anchor
                status = "Gaussian shape ready · \(reference.points.count) points"
                print("Gaussian ghost ready: \(reference.points.count) captured surface points")
            } catch {
                status = "Shape renderer unavailable · bounds preview"
                print("Gaussian ghost unavailable: \(error)")
                red = box(position: reference.position, size: reference.bounds, color: .systemRed, opacity: 0.25)
            }
            if let red { view.scene.addAnchor(red) }
        }
        if reliable, showGreen, let current, greenTimestamp != current.timestamp {
            updateGreen(current, in: view)
            greenTimestamp = current.timestamp
        }
        red?.isEnabled = reliable && showRed
        green?.isEnabled = reliable && showGreen && current != nil
    }

    private func updateGreen(_ capture: ReferenceCapture, in view: ARView) {
        if let greenCloud {
            greenCloud.update(points: capture.points, position: capture.position)
            return
        }
        if !greenUsesBounds {
            do {
                let cloud = try SplatCloud(points: capture.points, position: capture.position,
                    tint: SIMD3(0.1, 1, 0.25), radius: 0.003, opacity: 0.045,
                    capacity: ReferenceCapture.maximumPointCount)
                greenCloud = cloud
                green = cloud.anchor
                view.scene.addAnchor(cloud.anchor)
                return
            } catch {
                greenUsesBounds = true
                print("Current surface renderer unavailable: \(error)")
            }
        }
        // The proxy also follows current dimensions, never the saved reference shape.
        green?.removeFromParent()
        green = box(position: capture.position, size: capture.bounds, color: .systemGreen, opacity: 0.06)
        if let green { view.scene.addAnchor(green) }
    }

    private func box(position: SIMD3<Float>, size: SIMD3<Float>, color: UIColor, opacity: Float) -> AnchorEntity {
        let anchor = AnchorEntity(world: position)
        anchor.isEnabled = false
        var material = UnlitMaterial(color: color)
        material.blending = .transparent(opacity: .init(floatLiteral: opacity))
        let entity = ModelEntity(mesh: .generateBox(size: size), materials: [material])
        anchor.addChild(entity)
        return anchor
    }
}

/// Reuses one resource for live surfaces. Zero-opacity slots prevent old points
/// surviving when a later observation contains fewer depth samples.
@MainActor
private final class SplatCloud {
    let anchor = AnchorEntity(world: SIMD3<Float>.zero)
    private let entity = Entity()
    private let buffer: LowLevelBuffer
    private let capacity: Int
    private let tint: SIMD3<Float>
    private let radius: Float
    private let opacity: Float

    init(points: [CapturedPoint], position: SIMD3<Float>, tint: SIMD3<Float>, radius: Float,
         opacity: Float, capacity: Int? = nil) throws {
        self.capacity = max(1, capacity ?? points.count)
        self.tint = tint; self.radius = radius; self.opacity = opacity
        let stride = 60
        let byteCount = self.capacity * stride
        buffer = try LowLevelBuffer(descriptor: .init(capacity: (byteCount + 15) & ~15, sizeMultiple: 16))
        update(points: points, position: position)
        buffer.bytesUsed = byteCount
        func descriptor(_ format: MTLAttributeFormat, _ offset: Int) -> GaussianSplatResource.BufferDescriptor {
            .init(buffer: buffer, format: format, stride: stride, offset: offset)
        }
        let resource = GaussianSplatResource(try .init(count: self.capacity,
            position: descriptor(.float3, 0), scale: descriptor(.float3, 12), rotation: descriptor(.float4, 24),
            opacity: descriptor(.float, 40), sphericalHarmonics: (descriptor(.float3, 44), .zero)))
        resource.scaleActivation = .identity
        resource.opacityActivation = .identity
        entity.components.set(GaussianSplatComponent(resource))
        anchor.isEnabled = false
        anchor.addChild(entity)
    }

    func update(points: [CapturedPoint], position: SIMD3<Float>) {
        precondition(points.count <= capacity)
        buffer.replaceUnsafeMutableBytes { bytes in
            let values = bytes.bindMemory(to: Float.self)
            for index in 0..<capacity {
                let base = index * 15
                for field in 0..<15 { values[base + field] = 0 }
                values[base + 3] = radius; values[base + 4] = radius; values[base + 5] = radius
                values[base + 6] = 1 // Scalar-first identity quaternion.
                guard index < points.count else { continue }
                let point = points[index]
                let color = point.color * 0.35 + tint * 0.65
                values[base] = point.position.x
                values[base + 1] = point.position.y
                values[base + 2] = point.position.z
                values[base + 10] = opacity
                values[base + 11] = (color.x - 0.5) / 0.2820948
                values[base + 12] = (color.y - 0.5) / 0.2820948
                values[base + 13] = (color.z - 0.5) / 0.2820948
            }
        }
        // Positions are world-axis offsets about this observation's own center.
        // A fixed world-origin anchor avoids mixing an old anchor with a new pose.
        entity.position = position
    }
}
