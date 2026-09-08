import Foundation
import RealityGitCore

/// Retains owned RGB/depth/calibration together for future source-frame reconciliation.
typealias FrameBuffer = SourceFrameBuffer<AssistantSample>

struct AssistantSample: Sendable {
    let frame: FrameSample
    let seed: [Double]?
}

struct MacTrackingRecovery: Sendable {
    let reply: DetectionReply
    let source: FrameSample
    let sessionID: UUID
    let objectID: UUID
}
