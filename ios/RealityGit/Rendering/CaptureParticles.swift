import RealityKit
import UIKit
import simd

/// Camera-to-surface feedback only. This never supplies tracking or diff evidence.
@MainActor
final class CaptureParticles {
    private var anchor: AnchorEntity?
    private var emitters: [Entity] = []
    private var lastEmissionTime: TimeInterval = -.infinity
    private let travelTime = 0.38

    func update(in view: ARView, camera: simd_float4x4, target: SIMD3<Float>?,
                active: Bool, reliable: Bool, reduceMotion: Bool, time: TimeInterval) {
        guard reliable, !reduceMotion else { hide(); return }
        let cameraTarget = target.map { camera.inverse * SIMD4($0, 1) }
        let onScreen = target.flatMap { view.project($0) }.map { view.bounds.contains($0) } ?? false
        let shouldEmit = active && onScreen && (cameraTarget?.z ?? 0) < -0.15
        if shouldEmit, let target {
            prepare(in: view)
            anchor?.isEnabled = true
            lastEmissionTime = time
            for (index, entity) in emitters.enumerated() {
                // Start just in front of the lens, with a little separation so
                // forward motion remains visible instead of collapsing to a dot.
                let side: Float = index == 0 ? -1 : 1
                let origin = camera * SIMD4<Float>(side * 0.075, -0.045, -0.18, 1)
                let start = SIMD3(origin.x, origin.y, origin.z)
                let phase = Float(time * 3) + Float(index) * .pi
                let destination = target + SIMD3(cos(phase) * 0.012, sin(phase) * 0.012, 0)
                let offset = destination - start
                let distance = simd_length(offset)
                guard distance > 0.03, var emitter = entity.components[ParticleEmitterComponent.self] else { continue }
                entity.position = start
                emitter.emissionDirection = offset / distance
                emitter.speed = distance / Float(travelTime)
                emitter.simulationState = .play
                emitter.isEmitting = true
                entity.components.set(emitter)
            }
        } else {
            for entity in emitters {
                guard var emitter = entity.components[ParticleEmitterComponent.self] else { continue }
                emitter.isEmitting = false
                entity.components.set(emitter)
            }
            // Let the last particles land; interruptions hide them immediately.
            if time - lastEmissionTime > travelTime { anchor?.isEnabled = false }
        }
    }

    func hide() {
        anchor?.isEnabled = false
        lastEmissionTime = -.infinity
        for entity in emitters {
            guard var emitter = entity.components[ParticleEmitterComponent.self] else { continue }
            emitter.isEmitting = false
            emitter.simulationState = .stop
            entity.components.set(emitter)
        }
    }

    func reset() {
        hide()
        anchor?.removeFromParent()
        anchor = nil
        emitters = []
    }

    private func prepare(in view: ARView) {
        guard anchor == nil else { return }
        let anchor = AnchorEntity(world: SIMD3<Float>.zero)
        for _ in 0..<2 {
            var emitter = ParticleEmitterComponent()
            emitter.emitterShape = .point
            emitter.birthDirection = .world
            emitter.particlesInheritTransform = false
            emitter.speedVariation = 0
            emitter.mainEmitter.birthRate = 75
            emitter.mainEmitter.lifeSpan = travelTime
            emitter.mainEmitter.lifeSpanVariation = 0
            emitter.mainEmitter.size = 0.004
            emitter.mainEmitter.sizeVariation = 0.001
            emitter.mainEmitter.sizeMultiplierAtEndOfLifespan = 0.35
            emitter.mainEmitter.spreadingAngle = 0.008
            emitter.mainEmitter.acceleration = .zero
            emitter.mainEmitter.dampingFactor = 0
            emitter.mainEmitter.stretchFactor = 0.012
            emitter.mainEmitter.opacityCurve = .quickFadeInOut
            emitter.mainEmitter.blendMode = .additive
            emitter.mainEmitter.isLightingEnabled = false
            emitter.mainEmitter.color = .evolving(
                start: .single(UIColor(red: 1, green: 0.85, blue: 0.7, alpha: 0.85)),
                end: .single(UIColor(red: 1, green: 0.22, blue: 0.12, alpha: 0.6)))
            let entity = Entity()
            entity.components.set(emitter)
            anchor.addChild(entity)
            emitters.append(entity)
        }
        self.anchor = anchor
        view.scene.addAnchor(anchor)
    }
}
