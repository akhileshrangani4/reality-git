#if DEBUG
import RealityKit
import RealityGitCore
import SwiftUI

/// Deterministic rendering fixture: launch with --capture-preview. No camera or model calls.
struct CaptureEffectsPreview: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> ARView { context.coordinator.view }
    func updateUIView(_ view: ARView, context: Context) {}
    static func dismantleUIView(_ view: ARView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor
    final class Coordinator: NSObject {
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        private let particles = CaptureParticles()
        private let renderer = DiffRenderer()
        private let object = ModelEntity(mesh: .generateBox(size: SIMD3(0.22, 0.3, 0.12)),
            materials: [UnlitMaterial(color: UIColor(white: 0.3, alpha: 1))])
        private var reference: ReferenceState!
        private var displayLink: CADisplayLink?
        private var start = CACurrentMediaTime()
        private var previousTime: Double = 0
        private var snapshots: Set<Int> = []
        private var updateCosts: [Double] = []
        private var displayIntervals: [Double] = []
        private var previousDisplayTime: Double?
        private var reportedPerformance = false

        override init() {
            super.init()
            view.environment.background = .color(UIColor(white: 0.025, alpha: 1))
            let anchor = AnchorEntity(world: SIMD3<Float>.zero)
            let camera = PerspectiveCamera()
            camera.camera.fieldOfViewInDegrees = 55
            anchor.addChild(camera)
            object.position = SIMD3(0, 0, -0.85)
            anchor.addChild(object)
            view.scene.addAnchor(anchor)
            let points = (0..<1800).map { index in
                CapturedPoint(position: SIMD3(Float(index % 36) / 35 * 0.22 - 0.11,
                    Float(index / 36) / 49 * 0.3 - 0.15, 0), color: SIMD3(repeating: 0.3))
            }
            reference = ReferenceState(key: ObservationKey(sessionID: UUID(), objectID: UUID(), frameID: 1, captureTime: 0),
                position: object.position + SIMD3(0, 0, 0.061), bounds: SIMD3(0.22, 0.3, 0.12), points: points)!
            displayLink = CADisplayLink(target: self, selector: #selector(tick))
            displayLink?.add(to: .main, forMode: .common)
        }

        @objc private func tick() {
            let tickStart = CACurrentMediaTime()
            let time = (tickStart - start).truncatingRemainder(dividingBy: 8)
            if time < previousTime { renderer.reset(); particles.reset() }
            previousTime = time
            let reduced = UIAccessibility.isReduceMotionEnabled || ProcessInfo.processInfo.arguments.contains("--capture-reduce-motion")
            object.position.x = time >= 5 ? 0.26 : 0
            renderer.update(in: view, reference: time >= 3 ? reference : nil, current: nil,
                showRed: time >= 5, showGreen: false, reliable: true, time: time, reduceMotion: reduced)
            particles.update(in: view, camera: matrix_identity_float4x4, target: renderer.captureImpact ?? reference.position,
                active: time < 3 || renderer.isRevealing, reliable: true, reduceMotion: reduced, time: time)
            if !reportedPerformance, time > 0.5, time < 2.8 {
                updateCosts.append(CACurrentMediaTime() - tickStart)
                if let previousDisplayTime { displayIntervals.append(tickStart - previousDisplayTime) }
                previousDisplayTime = tickStart
            } else if !reportedPerformance, time >= 2.8, !updateCosts.isEmpty {
                reportedPerformance = true
                let costs = updateCosts.sorted()
                let p95 = costs[min(costs.count - 1, Int(Double(costs.count) * 0.95))] * 1000
                let fps = Double(displayIntervals.count) / max(0.001, displayIntervals.reduce(0, +))
                print(String(format: "Capture preview performance: %.1f display callbacks/s, %.2f ms p95 CPU update (%d samples)", fps, p95, costs.count))
            }
            for (index, instant) in [1.5, 3.25, 4.25, 5.75].enumerated() where time >= instant && !snapshots.contains(index) {
                snapshots.insert(index)
                let name = "capture-preview-\(reduced ? "reduced" : "motion")-\(index).png"
                view.snapshot(saveToHDR: false) { image in
                    let url = URL.documentsDirectory.appending(path: name)
                    try? image?.pngData()?.write(to: url)
                    print("Capture preview saved: \(name)")
                }
            }
        }

        func stop() {
            displayLink?.invalidate(); displayLink = nil
            particles.reset(); renderer.reset()
        }
    }
}
#endif
