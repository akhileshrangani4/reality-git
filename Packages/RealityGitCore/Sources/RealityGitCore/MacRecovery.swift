import Foundation

/// Admission is independent of the looser source retention TTL. A consumed reply is never replayed.
public struct MacRecoveryPolicy: Sendable {
    public private(set) var lostAt: Double?
    public private(set) var attempts = 0
    public private(set) var rejectionReason: String?
    private var lastAttemptSourceTime = -Double.infinity
    private var lastAttemptTime = -Double.infinity
    public init() {}
    public mutating func markLost(at time: Double) { if lostAt == nil { lostAt = time } }
    public mutating func markTracked() { lostAt = nil }
    public mutating func admit(_ reply: DetectionReply, sourceTime: Double, currentTime: Double,
                               sessionID: UUID, objectID: UUID) -> CGRect? {
        guard let lostAt else { rejectionReason = "local track is healthy"; return nil }
        guard reply.status == .tracked else { rejectionReason = "Mac status is not continuous tracking"; return nil }
        guard reply.key.sessionID == sessionID, reply.key.objectID == objectID,
              reply.key.captureTime == sourceTime else { rejectionReason = "source or selection mismatch"; return nil }
        guard sourceTime >= lostAt else { rejectionReason = "source predates local loss"; return nil }
        guard sourceTime < currentTime, currentTime - sourceTime <= 1 else {
            rejectionReason = "source is stale or not before current frame"; return nil
        }
        guard sourceTime > lastAttemptSourceTime, currentTime - lastAttemptTime >= 0.5 else {
            rejectionReason = "reply already tried or rate limited"; return nil
        }
        guard reply.confidence.isFinite, reply.confidence >= 0.6, reply.confidence <= 1 else {
            rejectionReason = "Mac confidence below recovery threshold"; return nil
        }
        guard let rect = reply.rect, rect.count == 4, rect.allSatisfy(\.isFinite),
              rect[0] >= 0, rect[1] >= 0, rect[2] > 0, rect[3] > 0,
              rect[0] + rect[2] <= 1, rect[1] + rect[3] <= 1 else {
            rejectionReason = "invalid rectangle"; return nil
        }
        rejectionReason = nil
        lastAttemptSourceTime = sourceTime
        lastAttemptTime = currentTime
        attempts += 1
        return CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3])
    }
}

/// Build a private new epoch; publish it only after confidently advancing source -> current.
public enum MacRecoveryExecutor {
    public static func recover<Frame, Sequence, Observation>(source: Frame, current: Frame, rect: CGRect,
        makeSequence: () -> Sequence,
        seed: (Sequence, Frame, CGRect) throws -> Observation?,
        advance: (Sequence, Frame, Observation) throws -> Observation?,
        accepts: (Observation) -> Bool) rethrows -> (Sequence, Observation)? {
        let sequence = makeSequence()
        guard let first = try seed(sequence, source, rect), accepts(first),
              let latest = try advance(sequence, current, first), accepts(latest) else { return nil }
        return (sequence, latest)
    }
}
