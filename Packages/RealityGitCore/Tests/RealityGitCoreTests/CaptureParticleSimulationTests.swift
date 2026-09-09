import XCTest
import simd
@testable import RealityGitCore

final class CaptureParticleSimulationTests: XCTestCase {
    private let emitter = SIMD3<Float>(0, -0.08, -0.16)
    private let target = SIMD3<Float>(0, 0, -0.8)

    private func run(hz: Int, seconds: Int = 2) -> CaptureParticleSimulation {
        var simulation = CaptureParticleSimulation()
        for _ in 0..<(hz * seconds) {
            simulation.advance(delta: 1 / Double(hz), emitter: emitter, target: target, emitting: true)
        }
        return simulation
    }

    func testFixedStepMatchesAt30And120Hz() {
        let slow = run(hz: 30), fast = run(hz: 120)
        XCTAssertEqual(slow.emittedCount, fast.emittedCount)
        XCTAssertEqual(slow.arrivalCount, fast.arrivalCount)
        XCTAssertEqual(slow.flights.count, fast.flights.count)
        for (a, b) in zip(slow.flights, fast.flights) {
            XCTAssertLessThan(simd_distance(a.position, b.position), 0.00001)
            XCTAssertLessThan(simd_distance(a.velocity, b.velocity), 0.00001)
        }
    }

    func testScatteredSprayStillReachesTarget() {
        let simulation = run(hz: 60)
        let forward = simd_normalize(target - emitter)
        let middle = simulation.flights.filter {
            let along = simd_dot($0.position - emitter, forward) / simd_distance(emitter, target)
            return along > 0.2 && along < 0.75
        }
        let widths = middle.map { particle in
            let p = particle.position - emitter
            return simd_length(p - forward * simd_dot(p, forward))
        }
        XCTAssertGreaterThan(middle.count, 15)
        XCTAssertGreaterThan(widths.max() ?? 0, 0.04, "Spray should visibly spread beyond the old 14 mm braid")
        XCTAssertGreaterThan(simulation.arrivalCount, 50, "Turbulence must not keep particles orbiting forever")
        XCTAssertLessThanOrEqual(simulation.flights.count, CaptureParticleSimulation.flightCapacity)
    }

    func testSlowerParticlesTakeTimeToArriveAndStoppingDrains() {
        var simulation = CaptureParticleSimulation()
        simulation.advance(delta: 1 / 60, emitter: emitter, target: target, emitting: true)
        XCTAssertFalse(simulation.flights.isEmpty)
        XCTAssertEqual(simulation.arrivalCount, 0)
        let emitted = simulation.emittedCount
        for _ in 0..<60 {
            simulation.advance(delta: 1 / 120, emitter: emitter, target: target, emitting: false)
        }
        XCTAssertEqual(simulation.arrivalCount, 0, "The spray should take more than half a second to travel")
        for _ in 0..<300 {
            simulation.advance(delta: 1 / 120, emitter: emitter, target: target, emitting: false)
        }
        XCTAssertEqual(simulation.emittedCount, emitted)
        XCTAssertGreaterThan(simulation.arrivalCount, 0)
        XCTAssertTrue(simulation.isEmpty)
    }

    func testCameraMovementDoesNotTeleportExistingParticles() {
        var simulation = run(hz: 60, seconds: 1)
        let before = simulation.flights.map(\.position)
        simulation.advance(delta: 0, emitter: emitter + SIMD3(0.4, 0, 0), target: target, emitting: false)
        XCTAssertEqual(simulation.flights.map(\.position), before)
    }

    func testLongPauseAndInvalidInputsClearStaleParticles() {
        for delta: Double in [3, .infinity, .nan, -1] {
            var simulation = run(hz: 60)
            simulation.advance(delta: delta, emitter: emitter, target: target, emitting: true)
            XCTAssertTrue(simulation.isEmpty)
            XCTAssertEqual(simulation.emittedCount, 0)
        }
        var simulation = run(hz: 60)
        simulation.advance(delta: 1 / 60, emitter: emitter, target: SIMD3(.nan, 0, 0), emitting: true)
        XCTAssertTrue(simulation.isEmpty)
    }

    func testMovingTargetStaysFiniteAndBounded() {
        var simulation = CaptureParticleSimulation()
        for frame in 0..<600 {
            let time = Float(frame) / 60
            let moving = target + SIMD3(sin(time * 3) * 0.3, cos(time * 2) * 0.15, 0)
            simulation.advance(delta: 1 / 60, emitter: emitter, target: moving, emitting: true)
            XCTAssertLessThanOrEqual(simulation.flights.count, CaptureParticleSimulation.flightCapacity)
            for particle in simulation.flights {
                XCTAssertTrue(particle.position.x.isFinite && particle.position.y.isFinite && particle.position.z.isFinite)
                XCTAssertLessThan(simd_distance(particle.position, emitter), 3)
            }
        }
    }

    func testCurlFieldHasNegligibleDivergence() {
        let h: Float = 0.0001
        for index in 0..<20 {
            let p = SIMD3<Float>(Float(index) * 0.071, 0.13, -0.28)
            var divergence: Float = 0
            for axis in 0..<3 {
                var offset = SIMD3<Float>.zero
                offset[axis] = h
                let a = CaptureParticleSimulation.curlFlow(at: p + offset, time: 0.7)
                let b = CaptureParticleSimulation.curlFlow(at: p - offset, time: 0.7)
                divergence += (a[axis] - b[axis]) / (2 * h)
            }
            XCTAssertEqual(divergence, 0, accuracy: 0.02)
        }
    }
}
