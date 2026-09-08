import RealityGitCore

/// Retains owned RGB/depth/calibration together for future source-frame reconciliation.
typealias FrameBuffer = SourceFrameBuffer<AssistantSample>

struct AssistantSample: Sendable {
    let frame: FrameSample
    let seed: [Double]?
}
