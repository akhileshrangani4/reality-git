import Foundation
import simd

/// Visual feedback only. None of this synthetic geometry is used for capture or identity.
public struct CaptureParticleSimulation {
    public struct Particle {
        public fileprivate(set) var position: SIMD3<Float>
        public fileprivate(set) var velocity: SIMD3<Float>
        public fileprivate(set) var age: Float = 0
        public let lifetime: Float
        public let radius: Float
        fileprivate let cruiseSpeed: Float
    }

    public static let flightCapacity = 168
    public private(set) var flights: [Particle] = []
    public private(set) var arrivalCount = 0
    public private(set) var emittedCount = 0
    private var accumulator: Double = 0
    private var emission: Float = 0
    private var elapsed: Float = 0
    private var randomState: UInt64 = 0xA57A_2026
    private static let step = 1.0 / 120

    public init() {
        flights.reserveCapacity(Self.flightCapacity)
    }

    public var isEmpty: Bool { flights.isEmpty }

    public mutating func reset() {
        flights.removeAll(keepingCapacity: true)
        accumulator = 0; emission = 0; elapsed = 0
        arrivalCount = 0; emittedCount = 0; randomState = 0xA57A_2026
    }

    /// Fixed substeps make trajectories independent of display refresh rate. A long pause
    /// clears stale particles instead of replaying a burst of missed emissions on resume.
    public mutating func advance(delta: Double, emitter: SIMD3<Float>, target: SIMD3<Float>, emitting: Bool) {
        guard delta.isFinite, delta >= 0, Self.finite(emitter), Self.finite(target), delta <= 0.25 else {
            reset(); return
        }
        accumulator += min(delta, 0.1)
        while accumulator + 1e-9 >= Self.step {
            integrate(dt: Float(Self.step), emitter: emitter, target: target, emitting: emitting)
            accumulator = max(0, accumulator - Self.step)
        }
    }

    private mutating func integrate(dt: Float, emitter: SIMD3<Float>, target: SIMD3<Float>, emitting: Bool) {
        elapsed += dt
        let axis = target - emitter
        let distance = simd_length(axis)
        guard distance > 0.03, distance < 12 else { reset(); return }
        let forward = axis / distance
        let basis = abs(forward.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
        let right = simd_normalize(simd_cross(forward, basis))
        let up = simd_cross(forward, right)

        // A disk aperture and varied launch angles create a broad, irregular spray.
        // Randomness is sampled at birth, never used to teleport particles each frame.
        if emitting {
            emission += dt * 140
            while emission >= 1 {
                emission -= 1
                guard flights.count < Self.flightCapacity else { continue }
                let angle = random() * 2 * .pi
                let radial = right * cos(angle) + up * sin(angle)
                let aperture = sqrt(random()) * min(0.018, distance * 0.045)
                let spread = 0.25 + random() * 0.65
                let speed = min(6, max(0.32, distance * (0.82 + random() * 0.48)))
                let heading = simd_normalize(forward + radial * spread)
                let radius = 0.0004 + pow(random(), 2) * 0.0005
                flights.append(Particle(position: emitter + radial * aperture, velocity: heading * speed,
                    lifetime: 2.4, radius: radius, cruiseSpeed: speed))
                emittedCount += 1
            }
        } else { emission = 0 }

        for index in flights.indices.reversed() {
            var particle = flights[index]
            particle.age += dt
            guard particle.age < particle.lifetime else { flights.remove(at: index); continue }
            let offset = target - particle.position
            let remaining = simd_length(offset)
            let toward = offset / max(remaining, 0.00001)
            let near = min(1, remaining / max(0.09, distance * 0.22))
            let desired = toward * particle.cruiseSpeed * min(1, remaining / 0.085)
            // Reynolds-style velocity steering preserves momentum. Stronger damping near
            // the target gathers the spray without forcing flight onto a prescribed curve.
            let response = 0.09 + near * 0.38
            let flow = Self.curlFlow(at: particle.position, time: elapsed * 0.5)
            let turbulentVelocity = flow * particle.cruiseSpeed * 0.32 * near
            let acceleration = Self.limited((desired + turbulentVelocity - particle.velocity) / response,
                                            to: particle.cruiseSpeed * 16)
            let previous = particle.position
            particle.velocity = Self.limited(particle.velocity + acceleration * dt, to: particle.cruiseSpeed * 1.35)
            particle.position += particle.velocity * dt

            // Swept segment/sphere contact prevents fast particles stepping through the
            // small visual impact region around the measured point.
            let segment = particle.position - previous
            let t = min(1, max(0, simd_dot(target - previous, segment) / max(1e-10, simd_length_squared(segment))))
            if simd_distance(previous + segment * t, target) < 0.009 {
                flights.remove(at: index)
                arrivalCount += 1
            } else { flights[index] = particle }
        }
    }

    /// Analytic curl of a smooth vector potential at three spatial scales, inspired by
    /// Bridson et al. (2007). Trigonometric modes replace Perlin noise to keep the mobile
    /// effect cheap. This field is divergence-free; the added target attraction is not.
    static func curlFlow(at position: SIMD3<Float>, time: Float) -> SIMD3<Float> {
        var result = SIMD3<Float>.zero
        for octave in 0..<3 {
            let frequency: Float = [18, 39, 83][octave]
            let amplitude: Float = [0.55, 0.28, 0.14][octave]
            let phase = Float(octave) * 7.13
            let p = position * frequency + SIMD3(time * 0.7 + phase, -time * 0.51 + phase * 1.7, time * 0.43 - phase)
            let s = SIMD3(sin(p.x), sin(p.y), sin(p.z))
            let c = SIMD3(cos(p.x), cos(p.y), cos(p.z))
            result += SIMD3(s.x * (c.y - c.z), s.y * (c.z - c.x), s.z * (c.x - c.y)) * amplitude
        }
        return result
    }

    private mutating func random() -> Float {
        randomState = randomState &* 6364136223846793005 &+ 1442695040888963407
        return Float(UInt32(truncatingIfNeeded: randomState >> 40)) / 16_777_216
    }

    private static func limited(_ vector: SIMD3<Float>, to maximum: Float) -> SIMD3<Float> {
        vector * min(1, maximum / max(0.00001, simd_length(vector)))
    }

    private static func finite(_ vector: SIMD3<Float>) -> Bool {
        vector.x.isFinite && vector.y.isFinite && vector.z.isFinite
    }
}
