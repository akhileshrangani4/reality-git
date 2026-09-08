import Foundation

enum TrackingStatus: Equatable {
    case idle
    case requestingCamera
    case cameraDenied
    case unsupported
    case scanning
    case waitingForDepth
    case ready
    case limited(String)
    case interrupted
    case paused
    case failed(String)

    var isReady: Bool { self == .ready }

    var title: String {
        switch self {
        case .idle, .requestingCamera: "Getting ready"
        case .cameraDenied: "Allow camera access"
        case .unsupported: "LiDAR is required"
        case .scanning: "Look around the room"
        case .waitingForDepth: "Finding depth"
        case .ready: "Ready"
        case .limited: "Finding our place"
        case .interrupted: "Camera interrupted"
        case .paused: "Scan paused"
        case .failed: "Scan stopped"
        }
    }

    var message: String {
        switch self {
        case .idle, .requestingCamera:
            "Use your camera to establish a position in the room."
        case .cameraDenied:
            "Enable Camera for Reality Git in Settings, then return here."
        case .unsupported:
            "This prototype needs a LiDAR-equipped iPhone, such as iPhone 15 Pro."
        case .scanning:
            "Move your phone slowly to find its place."
        case .waitingForDepth:
            "Point toward a well-lit surface while the depth camera gets ready."
        case .ready:
            "Tap an object to remember it."
        case .limited(let reason):
            reason
        case .interrupted:
            "Return to the camera and look around the same area to recover tracking."
        case .paused:
            "Return to the app to continue scanning."
        case .failed(let message):
            "The scan could not continue. Restart the camera in Settings. \(message)"
        }
    }
}
