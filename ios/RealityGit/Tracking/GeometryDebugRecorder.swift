#if DEBUG
import Foundation
import CoreVideo
import RealityGitCore
import simd

struct GeometryDebugCapture: Codable {
    let source: String
    let key: ObservationKey?
    let timestamp: Double
    let cameraToWorld: [[Float]]
    let intrinsics: [[Float]]
    let imageSize: [Int]
    let depthSize: [Int]
    let trackedRect: CGRect?
    let extractionRect: CGRect
    let inputs: DepthDebugInputs

    init(source: String, key: ObservationKey?, sample: FrameSample, trackedRect: CGRect?, extractionRect: CGRect, inputs: DepthDebugInputs) {
        self.source = source; self.key = key; timestamp = sample.timestamp
        cameraToWorld = (0..<4).map { column in (0..<4).map { sample.cameraToWorld[column][$0] } }
        intrinsics = (0..<3).map { column in (0..<3).map { sample.intrinsics[column][$0] } }
        imageSize = [CVPixelBufferGetWidth(sample.image), CVPixelBufferGetHeight(sample.image)]
        depthSize = [sample.depthWidth, sample.depthHeight]
        self.trackedRect = trackedRect; self.extractionRect = extractionRect; self.inputs = inputs
    }
}

final class GeometryDebugRecorder {
    var baseline: GeometryDebugCapture?
    private var sessionID: UUID?
    private var recorded: Set<String> = []
    func begin(sessionID: UUID?) {
        if self.sessionID != sessionID { self.sessionID = sessionID; recorded = [] }
    }
    func record(candidate: GeometryDebugCapture, reason: String, confidence: Float, referencePosition: SIMD3<Float>?) {
        guard let baseline, let baselineSignature = baseline.inputs.signature, let candidateSignature = candidate.inputs.signature, recorded.count < 3 else { return }
        let values = baselineSignature.comparisonValues(candidateSignature)
        let distinct = reason + ":" + String(Int((values["widthRatio"] ?? 0) * 10)) + ":" + String(Int((values["heightRatio"] ?? 0) * 10))
        guard !recorded.contains(distinct) else { return }
        struct Case: Codable {
            let version: Int
            let baseline: GeometryDebugCapture
            let candidate: GeometryDebugCapture
            let reason: String
            let confidence: Float
            let referencePosition: SIMD3<Float>?
            let comparison: [String: Float]
        }
        recorded.insert(distinct)
        do {
            let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("RealityGitDebug", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("case-\(recorded.count).json")
            let data = try JSONEncoder().encode(Case(version: 1, baseline: baseline, candidate: candidate, reason: reason, confidence: confidence, referencePosition: referencePosition, comparison: values))
            try data.write(to: url, options: .atomic)
            print("Geometry replay saved: \(url.lastPathComponent) bytes=\(data.count) reason=\(reason) values=\(values)")
        } catch { print("Geometry replay save failed: \(error.localizedDescription)") }
    }
}
#endif
