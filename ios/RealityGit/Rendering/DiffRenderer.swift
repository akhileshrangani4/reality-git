import RealityKit
import RealityGitCore
import UIKit
import Metal

@MainActor
final class DiffRenderer {
    private(set) var status = "Capturing depth shape…"
    private var red: AnchorEntity?
    private var redCloud: SplatCloud?
    private var captureStartTime: TimeInterval?
    private var lastUpdateTime: TimeInterval?
    private var redOpacity: Float = 0
    private(set) var isRevealing = false
    private(set) var captureImpact: SIMD3<Float>?
    private var green: AnchorEntity?
    private var greenCloud: SplatCloud?
    private var greenUsesBounds = false
    private var greenTimestamp: Double?
    private var referenceKey: ObservationKey?
    private var provisionalTimestamp: Double?
    private var prepared = false
    private var attached = false
    #if DEBUG
    var visibleSavedSlots: Int { redCloud?.visibleSlots ?? 0 }
    #endif

    /// Allocate GPU resources before a tap; selections only replace their measured points.
    func prepare(in view: ARView) {
        if !prepared {
            prepared = true
            do {
                let saved = try SplatCloud(points: [], position: .zero, tint: SIMD3(1, 0.15, 0.1),
                    radius: 0.006, opacity: 0.25, capacity: ReferenceCapture.maximumPointCount)
                redCloud = saved; red = saved.anchor
                let current = try SplatCloud(points: [], position: .zero, tint: SIMD3(0.1, 1, 0.25),
                    radius: 0.003, opacity: 0.045, capacity: ReferenceCapture.maximumPointCount)
                greenCloud = current; green = current.anchor
            } catch { print("Splat preallocation unavailable: \(error)") }
        }
        if !attached {
            if let red { view.scene.addAnchor(red) }
            if let green { view.scene.addAnchor(green) }
            attached = true
        }
    }
    func hide() {
        red?.isEnabled = false
        green?.isEnabled = false
        captureStartTime = nil; lastUpdateTime = nil; redOpacity = 0; isRevealing = false
    }
    func reset() {
        hide()
        // AR reset removes its anchors. Reattach the cached resources on the next update.
        red?.removeFromParent(); green?.removeFromParent(); attached = false
        if redCloud == nil { red = nil }
        if greenCloud == nil { green = nil }
        referenceKey = nil; provisionalTimestamp = nil
        captureImpact = nil
        greenUsesBounds = false; greenTimestamp = nil
    }
    func update(in view: ARView, reference: ReferenceState?, current: ReferenceCapture?,
                showRed: Bool, showGreen: Bool, reliable: Bool, time: TimeInterval, reduceMotion: Bool,
                provisional: ReferenceCapture? = nil) {
        prepare(in: view)
        guard reliable else { hide(); return }
        guard let reference else {
            green?.isEnabled = false; isRevealing = false
            guard let provisional, time >= provisional.timestamp, time - provisional.timestamp <= 0.5 else {
                red?.isEnabled = false; captureImpact = nil; return
            }
            if provisionalTimestamp != provisional.timestamp {
                redCloud?.update(points: provisional.points, position: provisional.position)
                redCloud?.setPresentation(reveal: 1, opacityScale: 0.4, radiusScale: 0.75)
                provisionalTimestamp = provisional.timestamp
            }
            red?.isEnabled = redCloud != nil
            captureImpact = provisional.position
            status = "Scanning surface…"
            return
        }
        if referenceKey != reference.captureKey {
            reset(); prepare(in: view); referenceKey = reference.captureKey
            let impactOffset = reference.points.min { simd_length_squared($0.position) < simd_length_squared($1.position) }?.position ?? .zero
            captureImpact = reference.position + impactOffset
            do {
                let cloud = try redCloud ?? SplatCloud(points: [], position: .zero,
                    tint: SIMD3(1, 0.15, 0.1), radius: 0.006, opacity: 0.25, capacity: ReferenceCapture.maximumPointCount, revealOrigin: impactOffset)
                cloud.update(points: reference.points, position: reference.position, revealOrigin: impactOffset)
                cloud.setPresentation(reveal: reduceMotion ? 1 : 0, opacityScale: 1)
                redCloud = cloud; red = cloud.anchor
                redOpacity = showRed ? 1 : 0.5
                captureStartTime = reduceMotion ? nil : time
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
        let elapsed = captureStartTime.map { max(0, time - $0) } ?? .infinity
        let reveal = reduceMotion ? 1 : Float(min(1, elapsed / 0.12))
        isRevealing = reveal < 1
        // A brief completed-capture preview flows into the normal diff display.
        let preview = reduceMotion ? 0 : Float(max(0, min(1, (1.0 - elapsed) / 0.22))) * 0.5
        let targetOpacity: Float = showRed ? 1 : preview
        let delta = min(0.1, max(0, time - (lastUpdateTime ?? time)))
        lastUpdateTime = time
        if reduceMotion { redOpacity = targetOpacity }
        else {
            redOpacity += (targetOpacity - redOpacity) * Float(1 - exp(-delta / 0.07))
            if abs(redOpacity - targetOpacity) < 0.005 { redOpacity = targetOpacity }
        }
        redCloud?.setPresentation(reveal: reveal, opacityScale: redOpacity, radiusScale: showRed ? 1 : 0.5)
        if redCloud == nil { red?.components.set(OpacityComponent(opacity: redOpacity)) }
        red?.isEnabled = redOpacity > 0.001
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
    private var revealOrigin: SIMD3<Float>
    private var activeCount = 0
    private var revealOrder: [Float] = []
    private var lastPresentation: SIMD3<Float>?
    #if DEBUG
    var visibleSlots: Int {
        var count = 0
        buffer.withUnsafeBytes { bytes in
            let values = bytes.bindMemory(to: Float.self)
            count = (0..<capacity).filter { values[$0 * 15 + 10] > 0 }.count
        }
        return count
    }
    #endif

    init(points: [CapturedPoint], position: SIMD3<Float>, tint: SIMD3<Float>, radius: Float,
         opacity: Float, capacity: Int? = nil, revealOrigin: SIMD3<Float> = .zero) throws {
        self.capacity = max(1, capacity ?? points.count)
        self.tint = tint; self.radius = radius; self.opacity = opacity
        self.revealOrigin = revealOrigin
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

    func update(points: [CapturedPoint], position: SIMD3<Float>, revealOrigin: SIMD3<Float> = .zero) {
        precondition(points.count <= capacity)
        activeCount = points.count
        self.revealOrigin = revealOrigin
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
        revealOrder = []
        lastPresentation = nil
    }

    func setPresentation(reveal: Float, opacityScale: Float, radiusScale: Float = 1) {
        let presentation = SIMD3(reveal, opacityScale, radiusScale)
        guard lastPresentation != presentation else { return }
        if revealOrder.isEmpty {
            buffer.withUnsafeBytes { bytes in
                let values = bytes.bindMemory(to: Float.self)
                let distances = (0..<activeCount).map { index in
                    simd_length(SIMD3(values[index * 15], values[index * 15 + 1], values[index * 15 + 2]) - revealOrigin)
                }
                let near = distances.min() ?? 0, far = distances.max() ?? 0
                let extent = max(0.001, far - near)
                // Points resolve out from the impact with a fixed stagger, without a flat wipe.
                revealOrder = distances.enumerated().map { index, distance in
                    let noise = sin(Float(index) * 12.9898) * 43758.5453
                    return (distance - near) / extent * 0.7 + (noise - floor(noise)) * 0.3
                }
            }
        }
        // Animate splat opacity directly: mesh material opacity does not control this resource.
        buffer.withUnsafeMutableBytes { bytes in
            let values = bytes.bindMemory(to: Float.self)
            for index in 0..<capacity {
                guard index < activeCount else { values[index * 15 + 10] = 0; continue }
                let ramp = max(0, min(1, (reveal * 1.15 - revealOrder[index]) / 0.15))
                let eased = ramp * ramp * (3 - 2 * ramp)
                values[index * 15 + 3] = radius * radiusScale
                values[index * 15 + 4] = radius * radiusScale
                values[index * 15 + 5] = radius * radiusScale
                values[index * 15 + 10] = opacity * eased * opacityScale
            }
        }
        lastPresentation = presentation
    }
}
