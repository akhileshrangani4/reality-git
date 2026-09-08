import ARKit
import AVFoundation
import Combine
import RealityKit
import RealityGitCore
import UIKit

@MainActor
final class ARSessionController: NSObject, ObservableObject {
    let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)

    @Published private(set) var status: TrackingStatus = .idle
    @Published private(set) var hasDepth = false
    @Published private(set) var canReset = false

    @Published private(set) var hasSelection = false
    @Published private(set) var selectionMessage = "Tap an object, or draw a box around it."
    @Published private(set) var selectionRect: CGRect?
    @Published private(set) var selectedPosition: SIMD3<Float>?
    @Published var dragRect: CGRect?

    private let tracker = LocalObjectTracker()
    private var trackingGeneration = UUID()
    private var workerBusy = false
    private var pendingSelection: (FrameSample, ObjectSelection)?
    private var lastSampleTime: TimeInterval = 0
    private var imageRect: CGRect?
    private var lastResultTime: TimeInterval = 0
    private var marker: AnchorEntity?
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
        invalidateSelection()
        guard isRunning else { return }
        arView.session.pause()
        isRunning = false
        marker?.isEnabled = false
        hasDepth = false
        status = .paused
    }

    func reset() {
        guard wantsRunning, let configuration else { return }
        invalidateSelection()
        marker?.removeFromParent()
        marker = nil
        hasDepth = false
        status = .scanning
        isRunning = true
        arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    private func placeMarker(in frame: ARFrame) {
        var offset = matrix_identity_float4x4
        offset.columns.3.z = -1
        let anchor = AnchorEntity(world: frame.camera.transform * offset)
        let material = UnlitMaterial(color: .systemMint)
        let cube = ModelEntity(mesh: .generateBox(size: 0.08, cornerRadius: 0.008), materials: [material])
        anchor.addChild(cube)
        arView.scene.addAnchor(anchor)
        marker = anchor
    }

    private func update(from frame: ARFrame) {
        guard wantsRunning, isRunning else { return }
        let depthAvailable = frame.sceneDepth != nil
        if hasDepth != depthAvailable { hasDepth = depthAvailable }

        let next: TrackingStatus
        switch frame.camera.trackingState {
        case .normal:
            if marker == nil, !hasSelection, depthAvailable { placeMarker(in: frame) }
            marker?.isEnabled = true
            next = marker == nil && !hasSelection ? .waitingForDepth : .ready
        case .notAvailable:
            marker?.isEnabled = false
            next = .limited("Camera tracking is unavailable. Look around the same area, or place a new marker.")
        case .limited(let reason):
            marker?.isEnabled = false
            switch reason {
            case .initializing:
                next = .scanning
            case .excessiveMotion:
                next = .limited("Slow down your phone so the camera can find its position.")
            case .insufficientFeatures:
                next = .limited("Point toward a well-lit area with texture, such as a desk or bookshelf.")
            case .relocalizing:
                next = .limited("Look around the area you scanned. If the marker cannot recover, place a new one.")
            @unknown default:
                next = .limited("Move slowly around the same area to recover tracking.")
            }
        }
        if status != next { status = next }
        if next.isReady, hasSelection {
            if frame.timestamp - lastResultTime > 1 {
                selectionRect = nil
                selectedPosition = nil
            } else if let imageRect {
                selectionRect = screenRect(imageRect, frame: frame)
            }
            if !workerBusy, frame.timestamp - lastSampleTime >= 0.2,
               let sample = FrameSample(frame: frame) {
                lastSampleTime = frame.timestamp
                submit(sample, selection: nil)
            }
        } else {
            selectionRect = nil
            selectedPosition = nil
        }
    }

    func select(point: CGPoint) {
        guard let frame = arView.session.currentFrame, status.isReady else { return }
        let transform = frame.displayTransform(viewRotationAngle: viewRotationAngle, viewportSize: arView.bounds.size)
        guard let imagePoint = ImageCoordinates.imagePoint(viewPoint: point,
            viewport: arView.bounds.size, displayTransform: transform) else { return }
        beginSelection(.point(imagePoint), frame: frame)
    }

    func select(rect: CGRect) {
        guard let frame = arView.session.currentFrame, status.isReady else { return }
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
        trackingGeneration = UUID()
        hasSelection = true
        imageRect = nil
        selectionRect = nil
        selectedPosition = nil
        selectionMessage = "Finding the selected object…"
        marker?.removeFromParent()
        marker = nil
        if workerBusy {
            // Keep only the newest selection, with the exact image it refers to.
            pendingSelection = (sample, selection)
        } else {
            submit(sample, selection: selection)
        }
    }

    private func invalidateSelection() {
        trackingGeneration = UUID()
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
        Task {
            let result = await tracker.process(sample, selection: selection, generation: generation)
            workerBusy = false
            if generation == trackingGeneration, wantsRunning, isRunning, status.isReady,
               let latest = arView.session.currentFrame, latest.timestamp - sample.timestamp <= 1 {
                lastResultTime = sample.timestamp
                imageRect = result.rect
                selectedPosition = result.worldPosition
                selectionMessage = result.message
                selectionRect = result.rect.map { screenRect($0, frame: latest) }
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
        guard wantsRunning else { return }
        invalidateSelection()
        marker?.isEnabled = false
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
        invalidateSelection()
        marker?.isEnabled = false
        hasDepth = false
        status = .failed(error.localizedDescription)
    }
}
