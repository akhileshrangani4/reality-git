import ARKit
import AVFoundation
import Combine
import RealityKit
import RealityGitCore
import UIKit

enum CaptureStage {
    case idle, scanning, forming
}

@MainActor
final class ARSessionController: NSObject, ObservableObject {
    let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)

    @Published private(set) var status: TrackingStatus = .idle
    @Published var previewReference = false
    @Published private(set) var ghostStatus = "Capturing depth shape…"
    @Published private(set) var hasDepth = false
    @Published private(set) var canReset = false
    @Published private(set) var captureStage: CaptureStage = .idle

    @Published private(set) var hasSelection = false
    @Published private(set) var selectionMessage = "Tap an object, or draw a box around it."
    @Published private(set) var selectionRect: CGRect?
    @Published private(set) var selectedPosition: SIMD3<Float>?
    @Published private(set) var localTrackConfidence: Float = 0
    @Published var dragRect: CGRect?

    var currentScreenOverlay: CGRect? {
        let fresh = arView.session.currentFrame.map { overlayIsFresh(in: $0) } ?? false
        guard CurrentScreenOverlay.isVisible(state: objectSession.state,
            freshLocalTrack: fresh && selectionRect != nil, confidence: localTrackConfidence,
            hasCurrentWorldPosition: objectSession.current != nil, arReliable: status.isReady,
            drawing: dragRect != nil) else { return nil }
        return selectionRect
    }

    let assistant = AssistantCoordinator()
    let objectSession = SessionCoordinator()
    private let diffRenderer = DiffRenderer()
    private let captureParticles = CaptureParticles()
    private var captureAim: SIMD3<Float>?
    private let tracker = LocalObjectTracker()
    private var trackingGeneration = UUID()
    private var workerBusy = false
    private var pendingSelection: (FrameSample, ObjectSelection)?
    private var lastSampleTime: TimeInterval = 0
    private var imageRect: CGRect?
    private var lastInferenceDiagnosticTime: TimeInterval = -.infinity
    private var lastInferenceMessage = ""
    private var lastResultTime: TimeInterval = 0
    private var resultCameraPose: simd_float4x4?
    private var wantsRunning = false
    private var isRunning = false
    private var isStarting = false
    private var configuration: ARWorldTrackingConfiguration?

    override init() {
        super.init()
        // Delegate methods are isolated to the main actor below. ARKit must
        // deliver them on this queue; future image processing belongs elsewhere.
        arView.session.delegateQueue = .main
        arView.session.delegate = self
    }

    func start() async {
        wantsRunning = true
        guard !isRunning, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        let permitted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permitted = true
        case .notDetermined:
            status = .requestingCamera
            permitted = await AVCaptureDevice.requestAccess(for: .video)
        default:
            permitted = false
        }
        guard wantsRunning else { return }
        guard permitted else {
            status = .cameraDenied
            canReset = false
            return
        }
        guard ARWorldTrackingConfiguration.isSupported,
              ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {
            status = .unsupported
            canReset = false
            return
        }

        let config = configuration ?? ARWorldTrackingConfiguration()
        config.frameSemantics.insert(.sceneDepth)
        configuration = config
        canReset = true
        status = .scanning
        isRunning = true
        // Resuming must preserve the original AR coordinate system.
        arView.session.run(config)
    }

    func pause() {
        wantsRunning = false
        suspendSelection()
        guard isRunning else { return }
        arView.session.pause()
        isRunning = false
        hasDepth = false
        status = .paused
    }

    func reset() {
        previewReference = false
        #if DEBUG
        print("AR explicit reset")
        #endif
        guard wantsRunning, let configuration else { return }
        invalidateSelection()
        hasDepth = false
        status = .scanning
        isRunning = true
        arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    private func update(from frame: ARFrame) {
        guard wantsRunning, isRunning else { return }
        assistant.tick(now: frame.timestamp)
        objectSession.expire(now: frame.timestamp)
        let depthAvailable = frame.sceneDepth != nil
        if hasDepth != depthAvailable { hasDepth = depthAvailable }

        let next: TrackingStatus
        switch frame.camera.trackingState {
        case .normal:
            next = depthAvailable ? .ready : .waitingForDepth
        case .notAvailable:
            next = .limited("Camera tracking is unavailable. Look around the same area.")
        case .limited(let reason):
            switch reason {
            case .initializing:
                next = .scanning
            case .excessiveMotion:
                next = .limited("Slow down your phone so the camera can find its position.")
            case .insufficientFeatures:
                next = .limited("Point toward a well-lit area with texture, such as a desk or bookshelf.")
            case .relocalizing:
                next = .limited("Look around the area you scanned. Move slowly to recover tracking.")
            @unknown default:
                next = .limited("Move slowly around the same area to recover tracking.")
            }
        }
        if status != next {
            #if DEBUG
            print("AR status changed: \(status) -> \(next)")
            #endif
            status = next
        }
        if next.isReady, hasSelection {
            if !overlayIsFresh(in: frame) {
                selectionRect = nil
                selectedPosition = nil
            } else if let imageRect {
                selectionRect = screenRect(imageRect, frame: frame)
            }
            let localDue = !workerBusy && frame.timestamp - lastSampleTime >= 0.125
            let assistantDue = assistant.wantsSample(at: frame.timestamp)
            if (localDue || assistantDue), let sample = FrameSample(frame: frame) {
                if assistantDue { assistant.offer(sample) }
                if localDue {
                    lastSampleTime = frame.timestamp
                    submit(sample, selection: nil)
                }
            }
        } else {
            selectionRect = nil
            selectedPosition = nil
            objectSession.loseCurrent()
        }
        // Green uses the measured surface and pose from the same observation.
        // When local advancement fails, use Astra's last measured surface.
        // Historical image rectangles are never projected directly onto the current screen.
        let displayCapture = objectSession.currentCapture ?? (selectionRect == nil ? objectSession.observedCapture(now: frame.timestamp) : nil)
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        diffRenderer.update(in: arView, reference: objectSession.reference, current: displayCapture,
            showRed: previewReference || objectSession.state == .moved || objectSession.state == .absent, showGreen: objectSession.state.showsCurrentOverlay,
            reliable: next.isReady, time: frame.timestamp, reduceMotion: reduceMotion)
        let confirmedReply = assistant.evidence.map { $0.0.status == .tracked || $0.0.status == .identityConfirmed } ?? false
        let capturing = objectSession.reference == nil && (assistant.isThinking || (workerBusy && confirmedReply))
        let nextStage: CaptureStage = !next.isReady || !hasSelection || !assistant.connected ? .idle
            : (diffRenderer.isRevealing ? .forming : (capturing ? .scanning : .idle))
        if captureStage != nextStage { captureStage = nextStage }
        captureParticles.update(in: arView, camera: frame.camera.transform,
            target: diffRenderer.captureImpact ?? captureAim,
            active: nextStage != .idle, reliable: next.isReady, reduceMotion: reduceMotion, time: frame.timestamp)
        if ghostStatus != diffRenderer.status { ghostStatus = diffRenderer.status }
    }

    func select(point: CGPoint) {
        guard let frame = arView.session.currentFrame, status.isReady, assistant.connected else { return }
        let transform = frame.displayTransform(viewRotationAngle: viewRotationAngle, viewportSize: arView.bounds.size)
        guard let imagePoint = ImageCoordinates.imagePoint(viewPoint: point,
            viewport: arView.bounds.size, displayTransform: transform) else { return }
        beginSelection(.point(imagePoint), frame: frame)
    }

    func select(rect: CGRect) {
        guard let frame = arView.session.currentFrame, status.isReady, assistant.connected else { return }
        let transform = frame.displayTransform(viewRotationAngle: viewRotationAngle, viewportSize: arView.bounds.size)
        let points = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                      CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
            .compactMap { ImageCoordinates.imagePoint(viewPoint: $0, viewport: arView.bounds.size, displayTransform: transform) }
        guard points.count == 4,
              let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return }
        beginSelection(.rectangle(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)), frame: frame)
    }

    private var viewRotationAngle: CGFloat {
        if let angle = arView.session.viewRotationAngle { return angle }
        switch arView.window?.windowScene?.effectiveGeometry.interfaceOrientation {
        case .landscapeRight: return 0
        case .landscapeLeft: return 180
        case .portraitUpsideDown: return 270
        default: return 90
        }
    }

    private func overlayIsFresh(in frame: ARFrame) -> Bool {
        guard let pose = resultCameraPose else { return false }
        let current = frame.camera.transform
        let translation = simd_distance(SIMD3(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z),
            SIMD3(current.columns.3.x, current.columns.3.y, current.columns.3.z))
        let a = simd_quatf(pose), b = simd_quatf(current)
        let rotation = 2 * acos(min(1, abs(simd_dot(a.vector, b.vector))))
        return AssistantPolicy.overlayIsFresh(age: frame.timestamp - lastResultTime,
            translation: Double(translation), rotationRadians: Double(rotation))
    }

    private func screenRect(_ imageRect: CGRect, frame: ARFrame) -> CGRect {
        let transform = frame.displayTransform(viewRotationAngle: viewRotationAngle, viewportSize: arView.bounds.size)
        let normalized = imageRect.applying(transform)
        return CGRect(x: normalized.minX * arView.bounds.width, y: normalized.minY * arView.bounds.height,
            width: normalized.width * arView.bounds.width, height: normalized.height * arView.bounds.height)
    }

    private func beginSelection(_ selection: ObjectSelection, frame: ARFrame) {
        guard let sample = FrameSample(frame: frame) else {
            selectionMessage = "Wait for depth, then select the object again."
            return
        }
        if objectSession.reference == nil {
            assistant.resetSelection()
            objectSession.reset()
            diffRenderer.reset()
        }
        captureParticles.reset()
        switch selection {
        case .point(let point): captureAim = sample.captureAim(at: point)
        case .rectangle(let rect): captureAim = sample.captureAim(at: CGPoint(x: rect.midX, y: rect.midY))
        }
        resultCameraPose = nil
        trackingGeneration = UUID()
        #if DEBUG
        print("Selection generation invalidated/replaced: \(trackingGeneration)")
        #endif
        hasSelection = true
        imageRect = nil
        selectionRect = nil
        selectedPosition = nil
        selectionMessage = "Finding the selected object…"
        assistant.select(sample, selection: selection, preserveReference: objectSession.reference != nil)
        if workerBusy {
            // Keep only the newest selection, with the exact image it refers to.
            pendingSelection = (sample, selection)
        } else {
            submit(sample, selection: selection)
        }
    }

    private func suspendSelection() {
        localTrackConfidence = 0
        diffRenderer.hide()
        captureParticles.hide()
        captureStage = .idle
        trackingGeneration = UUID()
        pendingSelection = nil
        resultCameraPose = nil
        selectionRect = nil
        selectedPosition = nil
        objectSession.loseCurrent()
    }

    private func referenceVisibility(sample: FrameSample, trackedRect: CGRect?) -> VisibilityEvidence {
        guard let reference = objectSession.reference else { return .unknown }
        let inverse = sample.cameraToWorld.inverse
        let width = Float(CVPixelBufferGetWidth(sample.image)), height = Float(CVPixelBufferGetHeight(sample.image))
        var comparisons: [Float] = []
        var projected = 0
        for point in reference.points {
            let world = reference.position + point.position
            let p = inverse * SIMD4(world.x, world.y, world.z, 1)
            guard p.z < -0.1 else { continue }
            let u = (sample.intrinsics[0][0] * p.x / -p.z + sample.intrinsics[2][0]) / width
            let v = (sample.intrinsics[1][1] * -p.y / -p.z + sample.intrinsics[2][1]) / height
            guard u > 0, u < 1, v > 0, v < 1 else { continue }
            projected += 1
            if let trackedRect, trackedRect.contains(CGPoint(x: Double(u), y: Double(v))) { return .visibleOccupied }
            let x = min(sample.depthWidth - 1, Int(u * Float(sample.depthWidth)))
            let y = min(sample.depthHeight - 1, Int(v * Float(sample.depthHeight)))
            let i = y * sample.depthWidth + x
            if sample.confidence[i] >= 2, sample.depth[i].isFinite, sample.depth[i] > 0 {
                comparisons.append(sample.depth[i] + p.z)
            }
        }
        return ReferenceVisibility.classify(differences: comparisons, projectedCount: projected, totalCount: reference.points.count)
    }

    private func invalidateSelection() {
        localTrackConfidence = 0
        assistant.resetSelection()
        objectSession.reset()
        diffRenderer.reset()
        captureParticles.reset()
        captureAim = nil
        captureStage = .idle
        resultCameraPose = nil
        trackingGeneration = UUID()
        #if DEBUG
        print("Selection generation invalidated/replaced: \(trackingGeneration)")
        #endif
        pendingSelection = nil
        hasSelection = false
        imageRect = nil
        selectionRect = nil
        selectedPosition = nil
        dragRect = nil
        selectionMessage = "Tap an object, or draw a box around it."
    }

    private func submit(_ sample: FrameSample, selection: ObjectSelection?) {
        workerBusy = true
        let generation = trackingGeneration
        let recovery = assistant.recoveryEvidence()
        let key = objectSession.key(for: sample)
        let referencePosition = objectSession.reference?.position
        Task {
            let result = await tracker.process(sample, generation: generation, recovery: recovery, referencePosition: referencePosition)
            workerBusy = false
            #if DEBUG
            let shouldLogInference = result.message != lastInferenceMessage || sample.timestamp - lastInferenceDiagnosticTime >= 1
            if shouldLogInference {
                lastInferenceDiagnosticTime = sample.timestamp
                lastInferenceMessage = result.message
                print("Local Vision completed age=\((arView.session.currentFrame?.timestamp ?? sample.timestamp) - sample.timestamp)s currentGeneration=\(generation == trackingGeneration) confidence=\(result.confidence) result=\(result.message)")
            }
            #endif
            if generation == trackingGeneration, wantsRunning, isRunning, status.isReady,
               let latest = arView.session.currentFrame {
                objectSession.ingest(result, key: key, now: latest.timestamp, visibility: referenceVisibility(sample: sample, trackedRect: ReferenceVisibility.occupiedRect(trackedRect: result.rect, position: result.worldPosition, bounds: result.worldBounds, confidence: result.confidence)))
                lastResultTime = sample.timestamp
                resultCameraPose = sample.cameraToWorld
                localTrackConfidence = result.confidence
                imageRect = result.rect
                selectedPosition = overlayIsFresh(in: latest) ? result.worldPosition : nil
                selectionMessage = result.message
                selectionRect = overlayIsFresh(in: latest) ? result.rect.map { screenRect($0, frame: latest) } : nil
                #if DEBUG
                if shouldLogInference {
                    print("Astra geometry overlay=\(selectionRect != nil) metric=\(selectedPosition != nil) reference=\(result.referenceCapture != nil)")
                }
                #endif
            }
            if wantsRunning, let pendingSelection {
                self.pendingSelection = nil
                submit(pendingSelection.0, selection: pendingSelection.1)
            }
        }
    }
}

extension ARSessionController: @preconcurrency ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        update(from: frame)
    }

    func sessionWasInterrupted(_ session: ARSession) {
        #if DEBUG
        print("AR interrupted")
        #endif
        guard wantsRunning else { return }
        suspendSelection()
        hasDepth = false
        status = .interrupted
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        guard wantsRunning, let configuration else { return }
        status = .scanning
        session.run(configuration)
    }

    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { true }

    func session(_ session: ARSession, didFailWithError error: any Error) {
        guard wantsRunning else { return }
        isRunning = false
        suspendSelection()
        hasDepth = false
        status = .failed(error.localizedDescription)
    }
}
