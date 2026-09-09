import Combine
import Foundation
import simd
import RealityGitCore

/// Astra's source snapshots establish changes; fresh local samples smooth the current pose.
/// The immutable reference and last observed pose survive loss of local continuity separately.
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
    private(set) var currentCapture: ReferenceCapture?
    var current: SIMD3<Float>? { currentCapture?.position }
    private(set) var lastPositionTime: Double = -.infinity
    private var lastAstraSourceTime: Double = -.infinity
    private var observed: ReferenceCapture?
    func observedPosition(now: Double) -> SIMD3<Float>? {
        observedCapture(now: now)?.position
    }
    func observedCapture(now: Double) -> ReferenceCapture? {
        guard state != .absent, let observed, now >= observed.timestamp,
              now - observed.timestamp <= AstraGeometry.authorityLifetime else { return nil }
        return observed
    }
    func reset() {
        sessionID = UUID(); objectID = UUID(); frameID = 0
        reference = nil; reconciler = nil; reducer = nil; currentCapture = nil
        lastPositionTime = -.infinity; state = .unchanged
        lastAstraSourceTime = -.infinity; observed = nil
        message = "Hold the selected object still to remember its place."
    }
    func key(for sample: FrameSample) -> ObservationKey {
        frameID &+= 1
        return ObservationKey(sessionID: sessionID, objectID: objectID, frameID: frameID, captureTime: sample.timestamp)
    }
    private var lastMetricDiagnosticTime: Double = -.infinity
    func ingest(_ result: LocalTrackingResult, key: ObservationKey, now: Double, visibility: VisibilityEvidence = .unknown) {
        #if DEBUG
        if now - lastMetricDiagnosticTime >= 1 {
            lastMetricDiagnosticTime = now
            let distance = result.worldPosition.flatMap { point in reference.map { simd_distance(point, $0.position) } }
            print("Object diff: state=\(state) metric=\(result.worldPosition != nil) referenceDistance=\(distance.map(String.init(describing:)) ?? "unknown") age=\(now-key.captureTime) confidence=\(result.confidence)")
        }
        #endif
        guard key.sessionID == sessionID, key.objectID == objectID else { return }
        if let capture = result.referenceCapture { captureReference(capture, key: key) }
        if result.astraSourceTime > lastAstraSourceTime {
            lastAstraSourceTime = result.astraSourceTime
            observed = nil
            if let capture = result.astraCapture, now >= capture.timestamp,
               now - capture.timestamp <= AstraGeometry.authorityLifetime,
               reducer?.observeAstra(position: capture.position, time: capture.timestamp) == true {
                observed = capture
                state = reducer?.state ?? .unchanged
                #if DEBUG
                print("Astra snapshot accepted age=\(now - capture.timestamp)s state=\(state) distance=\(reference.map { simd_distance(capture.position, $0.position) } ?? 0)")
                #endif
            }
        }
        guard reference != nil,
              now >= key.captureTime, now - key.captureTime <= 0.5 else { return }
        guard let capture = result.currentCapture, capture.timestamp == key.captureTime,
              result.confidence >= 0.6 else {
            currentCapture = nil
            // Empty reference depth does not establish absence while Astra still sees the object elsewhere.
            let currentVisibility: VisibilityEvidence = observedPosition(now: now) == nil ? visibility : .unknown
            reducer?.observe(position: nil, identityConfirmed: false, visibility: currentVisibility, time: key.captureTime, frameID: key.frameID)
            state = reducer?.state ?? .unchanged
            message = reference == nil ? "Capturing · hold still, or draw a box around the object." : (state == .absent ? "Absent · remembered shape marks its place." : "Looking for remembered object")
            return
        }
        let position = capture.position
        guard reconciler?.accept(PositionObservation(key: key, position: position,
            identityConfirmed: true, confidence: result.confidence)) == true else { return }
        currentCapture = capture; lastPositionTime = key.captureTime
        reducer?.observe(position: position, identityConfirmed: true, visibility: .visibleOccupied,
            time: key.captureTime, frameID: key.frameID)
        state = reducer?.state ?? .unchanged
        switch state {
        case .moved: message = "Moved · red marks the remembered place, green follows the object."
        case .absent: message = "Checking returned object…"
        case .unchanged: message = "Remembered · move the object to compare."
        }
    }
    func captureReference(_ capture: ReferenceCapture, key: ObservationKey) {
        guard key.sessionID == sessionID, key.objectID == objectID else { return }
        if reference == nil, capture.points.count >= 12,
           capture.timestamp <= key.captureTime {
            let captureKey = ObservationKey(sessionID: sessionID, objectID: objectID,
                frameID: key.frameID, captureTime: capture.timestamp)
            if let reference = ReferenceState(key: captureKey, position: capture.position, bounds: capture.bounds, points: capture.points) {
                self.reference = reference
                reconciler = Reconciler(referencePosition: reference.position, sessionID: sessionID, objectID: objectID)
                reducer = DiffReducer(referencePosition: reference.position)
            }
        }
    }
    func loseCurrent() {
        currentCapture = nil
        if reference != nil {
            let next = state == .absent ? "Absent · remembered shape marks its place." : (state == .moved ? "Moved · looking for remembered object." : "Looking for remembered object")
            if message != next { message = next }
        }
    }
    func expire(now: Double) { if now - lastPositionTime > 0.5 { loseCurrent() } }
}
