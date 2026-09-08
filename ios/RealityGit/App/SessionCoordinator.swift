import Combine
import Foundation
import RealityGitCore

/// Metric keys are local samples, independent of upload scheduling. Mac recovery becomes
/// a local metric sample only after advancing and masking that exact current image.
@MainActor
final class SessionCoordinator: ObservableObject {
    @Published private(set) var reference: ReferenceState?
    @Published private(set) var state: DiffState = .unchanged
    @Published private(set) var message = "Select an object to remember its place."
    private var sessionID = UUID()
    private var objectID = UUID()
    private var frameID: UInt64 = 0
    private var reconciler: Reconciler?
    private var reducer: DiffReducer?
    private(set) var current: SIMD3<Float>?
    private(set) var lastPositionTime: Double = -.infinity
    func reset() {
        sessionID = UUID(); objectID = UUID(); frameID = 0
        reference = nil; reconciler = nil; reducer = nil; current = nil
        lastPositionTime = -.infinity; state = .unchanged
        message = "Hold the selected object still to remember its place."
    }
    func key(for sample: FrameSample) -> ObservationKey {
        frameID &+= 1
        return ObservationKey(sessionID: sessionID, objectID: objectID, frameID: frameID, captureTime: sample.timestamp)
    }
    func ingest(_ result: LocalTrackingResult, key: ObservationKey, now: Double, visibility: VisibilityEvidence = .unknown) {
        guard key.sessionID == sessionID, key.objectID == objectID,
              now >= key.captureTime, now - key.captureTime <= 0.5 else { return }
        guard let position = result.worldPosition, let bounds = result.worldBounds,
              result.confidence >= 0.6 else {
            current = nil
            reducer?.observe(position: nil, identityConfirmed: false, visibility: visibility, time: key.captureTime, frameID: key.frameID)
            state = reducer?.state ?? .unchanged
            message = reference == nil ? "Capturing · hold still, or draw a box around the object." : (state == .absent ? "Absent · remembered shape marks its place." : "Looking for remembered object")
            return
        }
        if reference == nil {
            // Freeze the first supported depth surface; later observations cannot replace it.
            guard result.referenceRect != nil, result.capturedPoints.count >= 12,
                  let reference = ReferenceState(key: key, position: position, bounds: bounds, points: result.capturedPoints) else { return }
            self.reference = reference
            reconciler = Reconciler(referencePosition: position, sessionID: sessionID, objectID: objectID)
            reducer = DiffReducer(referencePosition: position)
        }
        guard reconciler?.accept(PositionObservation(key: key, position: position,
            identityConfirmed: true, confidence: result.confidence)) == true else { return }
        current = position; lastPositionTime = key.captureTime
        reducer?.observe(position: position, identityConfirmed: true, visibility: .visibleOccupied,
            time: key.captureTime, frameID: key.frameID)
        state = reducer?.state ?? .unchanged
        switch state {
        case .moved: message = "Moved · red marks the remembered place, green follows the object."
        case .absent: message = "Checking returned object…"
        case .unchanged: message = "Remembered · move the object to compare."
        }
    }
    func loseCurrent() {
        current = nil
        if reference != nil {
            let next = state == .absent ? "Absent · remembered shape marks its place." : (state == .moved ? "Moved · looking for remembered object." : "Looking for remembered object")
            if message != next { message = next }
        }
    }
    func expire(now: Double) { if now - lastPositionTime > 0.5 { loseCurrent() } }
}
