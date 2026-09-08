import Foundation
import simd

public enum DiffState: Sendable { case unchanged, moved, absent }
public enum VisibilityEvidence: Sendable { case unknown, occluded, visibleEmpty, visibleOccupied }
public struct DiffReducer: Sendable {
    public let referencePosition: SIMD3<Float>
    public private(set) var state: DiffState = .unchanged
    private var pending: DiffState?
    private var count = 0
    private var started: Double = 0
    private var lastEvidenceTime: Double = -.infinity
    private var lastFrame: UInt64?
    private var lastTime: Double = -.infinity
    public init(referencePosition: SIMD3<Float>) { self.referencePosition = referencePosition }
    public mutating func interruptConfirmation() { pending = nil; count = 0 }
    public mutating func observe(position: SIMD3<Float>?, identityConfirmed: Bool,
                                 visibility: VisibilityEvidence, time: Double, frameID: UInt64) {
        guard time.isFinite, time >= lastTime, lastFrame == nil || frameID > lastFrame! else { return }
        lastFrame = frameID; lastTime = time
        if time - lastEvidenceTime > 1.5 { interruptConfirmation() }
        if pending == .absent, visibility != .visibleEmpty { interruptConfirmation() }
        let desired: DiffState?
        let duration: Double
        if let position, identityConfirmed, [position.x, position.y, position.z].allSatisfy(\.isFinite) {
            let distance = simd_distance(position, referencePosition)
            if distance > 0.15 { desired = .moved }
            else if distance < 0.08 { desired = .unchanged }
            else { desired = nil; interruptConfirmation() }
            duration = 0.5
        } else if visibility == .visibleEmpty {
            desired = .absent; duration = 1
        } else { desired = nil; duration = 0.5 }
        guard let desired else {
            if time - lastEvidenceTime > 1.5 { interruptConfirmation() }
            return
        }
        lastEvidenceTime = time
        guard desired != state else { interruptConfirmation(); return }
        if pending != desired { pending = desired; count = 1; started = time }
        else { count += 1 }
        if count >= 3, time - started >= duration { state = desired; interruptConfirmation() }
    }
}

public enum CurrentScreenOverlay {
    public static func isVisible(state: DiffState, freshLocalTrack: Bool, confidence: Float,
                                 hasCurrentWorldPosition: Bool, arReliable: Bool, drawing: Bool) -> Bool {
        (state == .moved || state == .absent) && freshLocalTrack && confidence.isFinite && confidence >= 0.6 &&
            !hasCurrentWorldPosition && arReliable && !drawing
    }
}
