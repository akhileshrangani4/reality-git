#if DEBUG
import CoreImage
import RealityGitCore
import RealityKit
import SwiftUI

/// Physical-device CPU benchmark with deterministic camera/depth frames, not a network timing claim.
struct CaptureSpeedCheck: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> ARView { context.coordinator.view }
    func updateUIView(_ view: ARView, context: Context) {}
    static func dismantleUIView(_ view: ARView, coordinator: Coordinator) { coordinator.task?.cancel() }

    @MainActor final class Coordinator {
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        var task: Task<Void, Never>?
        private let context = CIContext(options: [.cacheIntermediates: false])
        init() {
            view.environment.background = .color(.black)
            let anchor = AnchorEntity(world: .zero)
            anchor.addChild(PerspectiveCamera()); view.scene.addAnchor(anchor)
            task = Task { await run() }
        }

        private func run() async {
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            let tracker = LocalObjectTracker(), generation = UUID(), session = UUID(), object = UUID()
            let renderer = DiffRenderer()
            renderer.prepare(in: view)
            var metrics: [String: Any] = ["fixture": "1920x1440 RGB, 256x192 depth; model delay simulated at 5.5s"]
            do {
                let source = try frame(time: 0, offset: 0)
                let reply = DetectionReply(key: .init(sessionID: session, objectID: object, frameID: 1, captureTime: 0),
                    rect: [0.25, 0.25, 0.25, 0.5], confidence: 0.99, candidateID: nil, status: .identityConfirmed,
                    semanticLabel: "marked box", semanticStatus: "ready", outline: [[0.25, 0.25], [0.5, 0.25], [0.5, 0.75], [0.25, 0.75]])
                let recovery = MacTrackingRecovery(reply: reply, source: source, sessionID: session, objectID: object)
                var costs: [Double] = [], renderCosts: [Double] = []
                var captured: ReferenceState?, successfulTracks = 0
                var minimumIoU = 1.0, isolatedPreview = true, previewSlotsValid = false
                for index in 0..<80 {
                    try Task.checkCancellation()
                    let time = Double(index) * 0.125
                    let sample = index == 0 ? source : try frame(time: time, offset: Float(index) * 0.001)
                    let start = CACurrentMediaTime()
                    let result = await tracker.process(sample, generation: generation,
                        recovery: index >= 44 ? recovery : nil, referencePosition: captured?.position,
                        selection: index == 0 ? .rectangle(CGRect(x: 0.25, y: 0.25, width: 0.25, height: 0.5)) : nil)
                    let ms = (CACurrentMediaTime() - start) * 1000
                    if index == 0 { metrics["firstDepthPreviewMS"] = ms; metrics["previewPoints"] = result.provisionalCapture?.points.count ?? 0 }
                    if index < 44 { isolatedPreview = isolatedPreview && result.referenceCapture == nil && result.currentCapture == nil && result.astraCapture == nil }
                    if index == 44 { metrics["firstConfirmedGeometryMS"] = ms }
                    if index > 44 { costs.append(ms); if result.currentCapture != nil { successfulTracks += 1 } }
                    if index > 44, let rect = result.rect {
                        let truth = CGRect(x: 0.25 + Double(index) * 0.001, y: 0.25, width: 0.25, height: 0.5)
                        let intersection = rect.intersection(truth)
                        let overlap = intersection.isNull ? 0 : intersection.width * intersection.height
                        minimumIoU = min(minimumIoU, overlap / (rect.width * rect.height + truth.width * truth.height - overlap))
                    }
                    if captured == nil, let capture = result.referenceCapture {
                        captured = ReferenceState(key: reply.key, position: capture.position, bounds: capture.bounds, points: capture.points)
                        metrics["referencePoints"] = capture.points.count
                    }
                    let rendering = CACurrentMediaTime()
                    renderer.update(in: view, reference: captured, current: result.currentCapture,
                        showRed: true, showGreen: true, reliable: true, time: time, reduceMotion: false,
                        provisional: result.provisionalCapture)
                    if index == 0 {
                        metrics["firstPreviewSubmissionMS"] = (CACurrentMediaTime() - start) * 1000
                        previewSlotsValid = renderer.visibleSavedSlots == result.provisionalCapture?.points.count
                    }
                    if index >= 44 { renderCosts.append((CACurrentMediaTime() - rendering) * 1000) }
                    await Task.yield()
                }
                func percentile(_ values: [Double]) -> Double {
                    let sorted = values.sorted()
                    return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
                }
                metrics["localTrackingP95MS"] = percentile(costs)
                metrics["rendererUpdateP95MS"] = percentile(renderCosts)
                metrics["successfulTracks"] = successfulTracks
                metrics["trackingSamples"] = costs.count
                metrics["minimumTrackingIoU"] = minimumIoU
                metrics["previewIsNotReference"] = isolatedPreview
                metrics["continuityCacheHits"] = await tracker.continuityHits
                let jpegStart = CACurrentMediaTime()
                let jpeg = try source.jpeg()
                metrics["jpegColdMS"] = (CACurrentMediaTime() - jpegStart) * 1000
                let cachedStart = CACurrentMediaTime()
                let cachedJPEG = try source.jpeg()
                metrics["jpegCachedMS"] = (CACurrentMediaTime() - cachedStart) * 1000
                let expired = await tracker.process(try frame(time: 16, offset: 0.079), generation: generation,
                    recovery: recovery, referencePosition: captured?.position)
                metrics["expiredTrackHidden"] = expired.currentCapture == nil && expired.provisionalCapture == nil
                metrics["unusedSplatSlotsInvisible"] = previewSlotsValid
                let anchorCount = view.scene.anchors.count
                renderer.reset()
                renderer.update(in: view, reference: captured, current: nil, showRed: true, showGreen: false,
                    reliable: true, time: 17, reduceMotion: true)
                let resetRendererRestored = view.scene.anchors.count == anchorCount && renderer.visibleSavedSlots == captured?.points.count
                metrics["resetRendererRestored"] = resetRendererRestored
                let pointTracker = LocalObjectTracker(), pointGeneration = UUID()
                let pointPreview = await pointTracker.process(source, generation: pointGeneration,
                    selection: .point(CGPoint(x: 0.375, y: 0.5)))
                metrics["tapPreviewPoints"] = pointPreview.provisionalCapture?.points.count ?? 0
                let rejection = DetectionReply(key: .init(sessionID: session, objectID: object, frameID: 2, captureTime: 0),
                    rect: nil, confidence: 0.99, candidateID: nil, status: .notFound)
                let revoked = await pointTracker.process(try frame(time: 0.125, offset: 0), generation: pointGeneration,
                    recovery: MacTrackingRecovery(reply: rejection, source: source, sessionID: session, objectID: object))
                metrics["uncertainPreviewRevoked"] = revoked.provisionalCapture == nil && revoked.currentCapture == nil
                let reset = await pointTracker.process(source, generation: UUID())
                metrics["newSelectionIsolated"] = reset.provisionalCapture == nil && reset.referenceCapture == nil && reset.currentCapture == nil
                // Exercise the new cadence at the same physical motion speed as the baseline.
                let fastTracker = LocalObjectTracker(), fastGeneration = UUID()
                var fastCosts: [Double] = [], fastTracks = 0, fastIoU = 1.0
                for index in 0..<120 {
                    let sample = try frame(time: Double(index) / 30, offset: Float(index) / 30 * 0.008)
                    let start = CACurrentMediaTime()
                    let result = await fastTracker.process(sample, generation: fastGeneration, recovery: recovery)
                    if index > 0 {
                        fastCosts.append((CACurrentMediaTime() - start) * 1000)
                        if result.currentCapture != nil { fastTracks += 1 }
                        if let rect = result.rect {
                            let truth = CGRect(x: 0.25 + Double(index) / 30 * 0.008, y: 0.25, width: 0.25, height: 0.5)
                            let area = rect.intersection(truth)
                            let overlap = area.isNull ? 0 : area.width * area.height
                            fastIoU = min(fastIoU, overlap / (rect.width * rect.height + truth.width * truth.height - overlap))
                        }
                    }
                }
                metrics["cadence30HzTrackingP95MS"] = percentile(fastCosts)
                metrics["cadence30HzSuccessfulTracks"] = fastTracks
                metrics["cadence30HzMinimumIoU"] = fastIoU
                metrics["passed"] = captured != nil && successfulTracks >= 28 && minimumIoU >= 0.8 && isolatedPreview
                    && jpeg == cachedJPEG && expired.currentCapture == nil && previewSlotsValid && resetRendererRestored
                    && pointPreview.provisionalCapture != nil && revoked.provisionalCapture == nil && reset.referenceCapture == nil
                    && fastTracks >= 114 && fastIoU >= 0.8
            } catch { metrics["passed"] = false }
            let name = ProcessInfo.processInfo.arguments.contains("--baseline") ? "capture-speed-baseline.json" : "capture-speed-after.json"
            if let data = try? JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL.documentsDirectory.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                print("Capture speed check \(String(data: data, encoding: .utf8) ?? "")")
            }
            print("Capture speed check finished")
        }

        private func frame(time: Double, offset: Float) throws -> FrameSample {
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
            context.render(patch.composited(over: box.composited(over: background)), to: buffer)
            var depth = [Float](repeating: 3, count: dw * dh)
            for y in 48..<144 {
                for x in Int((0.25 + offset) * Float(dw))..<Int((0.5 + offset) * Float(dw)) { depth[y * dw + x] = 1 }
            }
            return FrameSample(image: buffer, depth: depth, confidence: [UInt8](repeating: 2, count: depth.count),
                depthWidth: dw, depthHeight: dh, intrinsics: simd_float3x3(SIMD3(1200, 0, 0), SIMD3(0, 1200, 0), SIMD3(960, 720, 1)),
                cameraToWorld: matrix_identity_float4x4, timestamp: time)
        }
    }
}
#endif
