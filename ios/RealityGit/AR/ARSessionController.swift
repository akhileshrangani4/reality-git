import ARKit
import AVFoundation
import Combine
import RealityKit
import UIKit

@MainActor
final class ARSessionController: NSObject, ObservableObject {
    let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)

    @Published private(set) var status: TrackingStatus = .idle
    @Published private(set) var hasDepth = false
    @Published private(set) var canReset = false

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
        guard isRunning else { return }
        arView.session.pause()
        isRunning = false
        marker?.isEnabled = false
        hasDepth = false
        status = .paused
    }

    func reset() {
        guard wantsRunning, let configuration else { return }
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
            if marker == nil, depthAvailable { placeMarker(in: frame) }
            marker?.isEnabled = true
            next = marker == nil ? .waitingForDepth : .ready
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
    }
}

extension ARSessionController: @preconcurrency ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        update(from: frame)
    }

    func sessionWasInterrupted(_ session: ARSession) {
        guard wantsRunning else { return }
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
        marker?.isEnabled = false
        hasDepth = false
        status = .failed(error.localizedDescription)
    }
}
