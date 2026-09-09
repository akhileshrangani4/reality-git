import Metal
import RealityGitCore
import RealityKit
import UIKit
import simd

/// A turbulent camera-to-object spray. Synthetic particles never become capture geometry.
@MainActor
final class CaptureParticles {
    private var anchor: AnchorEntity?
    private var glow: EnergyBuffer?
    private var glowUnavailable = false
    private var lastTime: TimeInterval?
    private var simulation = CaptureParticleSimulation()
    private var visibility: Float = 0
    private var start = SIMD3<Float>.zero
    private var tip = SIMD3<Float>.zero

    func update(in view: ARView, camera: simd_float4x4, target: SIMD3<Float>?,
                active: Bool, reliable: Bool, reduceMotion: Bool, time: TimeInterval) {
        guard reliable, !reduceMotion else { hide(); return }
        let cameraTarget = target.map { camera.inverse * SIMD4($0, 1) }
        let onScreen = target.flatMap { view.project($0) }.map { view.bounds.contains($0) } ?? false
        var emitting = active && onScreen && (cameraTarget?.z ?? 0) < -0.2
        guard emitting || !simulation.isEmpty else { lastTime = nil; return }
        let delta = max(0, time - (lastTime ?? time - 1 / 60))
        lastTime = time

        if emitting, let target,
           let ray = view.ray(through: CGPoint(x: view.bounds.midX, y: view.bounds.maxY * 1.05)) {
            let firstEmission = anchor == nil || simulation.isEmpty
            prepare(in: view)
            // The lens-side origin stays just outside the lower edge in any phone orientation.
            start = ray.origin + simd_normalize(ray.direction) * 0.18
            tip = firstEmission ? target : tip + (target - tip) * Float(1 - exp(-delta / 0.06))
        } else { emitting = false }
        guard let anchor else { return }
        visibility += ((emitting ? 1 : 0) - visibility) * Float(1 - exp(-delta / 0.08))
        if !emitting, visibility < 0.02 { hide(); return }
        simulation.advance(delta: delta, emitter: start, target: tip, emitting: emitting)

        var splats: [EnergySplat] = []
        splats.reserveCapacity(336)
        let cameraPosition = SIMD3(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
        for particle in simulation.flights {
            let speed = simd_length(particle.velocity)
            let heading = particle.velocity / max(0.00001, speed)
            let orientation = simd_quatf(from: SIMD3<Float>(0, 0, 1), to: heading)
            let lifeFade = min(1, particle.age / 0.08) * min(1, (particle.lifetime - particle.age) / 0.2)
            // Absorb softly before the contact point. No flash or outward burst obscures
            // the object's surface or the red capture forming there.
            let contactFade = min(1, max(0, (simd_distance(particle.position, tip) - 0.009) / 0.055))
            let fade = lifeFade * contactFade * visibility
            // Velocity-aligned streaks give fast particles weight; tiny, varied heads
            // remain legible as a scattered volume instead of a continuous tube.
            let streak = min(0.008, max(0.0015, speed * 0.0028))
            let radius = particle.radius * min(1, simd_distance(particle.position, cameraPosition) / 0.4)
            splats.append(EnergySplat(position: particle.position,
                scale: SIMD3(radius, radius, streak * 0.45), rotation: orientation,
                color: AppPalette.controlRGB, opacity: 0.82 * fade))
            splats.append(EnergySplat(position: particle.position - heading * streak,
                scale: SIMD3(radius * 1.3, radius * 1.3, streak), rotation: orientation,
                color: AppPalette.controlRGB, opacity: 0.16 * fade))
        }
        if let glow { glow.update(splats, origin: tip) }
        else if !splats.isEmpty, !glowUnavailable {
            do {
                // Build native bounds from populated geometry, never an empty cloud at the camera.
                let glow = try EnergyBuffer(splats: splats, origin: tip)
                anchor.addChild(glow.entity)
                self.glow = glow
            } catch {
                glowUnavailable = true
                print("Capture particles unavailable: \(error)")
            }
        }
        anchor.isEnabled = !simulation.isEmpty
    }

    func hide() {
        anchor?.isEnabled = false
        lastTime = nil; visibility = 0; simulation.reset()
    }

    func reset() {
        hide()
        anchor?.removeFromParent()
        anchor = nil; glow = nil; glowUnavailable = false
    }

    private func prepare(in view: ARView) {
        guard anchor == nil else { return }
        let anchor = AnchorEntity(world: SIMD3<Float>.zero)
        self.anchor = anchor
        view.scene.addAnchor(anchor)
    }
}

private struct EnergySplat {
    let position: SIMD3<Float>
    let scale: SIMD3<Float>
    var rotation = simd_quatf(real: 1, imag: .zero)
    let color: SIMD3<Float>
    let opacity: Float
}

/// One reusable native buffer renders the scattered spray and trails (at most 336 splats).
@MainActor
private final class EnergyBuffer {
    let entity = Entity()
    private let capacity = 352
    private let buffer: LowLevelBuffer

    init(splats: [EnergySplat], origin: SIMD3<Float>) throws {
        buffer = try LowLevelBuffer(descriptor: .init(capacity: 352 * 60, sizeMultiple: 16))
        update(splats, origin: origin)
        buffer.bytesUsed = capacity * 60
        func descriptor(_ format: MTLAttributeFormat, _ offset: Int) -> GaussianSplatResource.BufferDescriptor {
            .init(buffer: buffer, format: format, stride: 60, offset: offset)
        }
        let resource = GaussianSplatResource(try .init(count: capacity,
            position: descriptor(.float3, 0), scale: descriptor(.float3, 12), rotation: descriptor(.float4, 24),
            opacity: descriptor(.float, 40), sphericalHarmonics: (descriptor(.float3, 44), .zero)))
        resource.scaleActivation = .identity; resource.opacityActivation = .identity
        entity.components.set(GaussianSplatComponent(resource))
    }

    func update(_ splats: [EnergySplat], origin: SIMD3<Float>) {
        precondition(splats.count <= capacity)
        buffer.replaceUnsafeMutableBytes { bytes in
            let values = bytes.bindMemory(to: Float.self)
            for index in 0..<capacity {
                let base = index * 15
                for field in 0..<15 { values[base + field] = 0 }
                values[base + 3] = 0.001; values[base + 4] = 0.001; values[base + 5] = 0.001
                values[base + 6] = 1
                guard index < splats.count else { continue }
                let s = splats[index], q = splats[index].rotation
                let local = s.position - origin
                let data: [Float] = [local.x, local.y, local.z, s.scale.x, s.scale.y, s.scale.z,
                    q.real, q.imag.x, q.imag.y, q.imag.z, s.opacity,
                    (s.color.x - 0.5) / 0.2820948, (s.color.y - 0.5) / 0.2820948, (s.color.z - 0.5) / 0.2820948, 0]
                for field in 0..<15 { values[base + field] = data[field] }
            }
        }
        entity.position = origin
    }
}
