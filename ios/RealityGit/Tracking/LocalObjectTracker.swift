import CoreVideo
import Foundation
import RealityGitCore
import Vision
import simd

enum ObjectSelection: Sendable {
    case point(CGPoint)
    case rectangle(CGRect)
}

struct ReferenceCapture: Sendable {
    static let maximumPointCount = 4000
    let timestamp: Double
    let position: SIMD3<Float>
    let bounds: SIMD3<Float>
    let points: [CapturedPoint]
}

struct LocalTrackingResult: Sendable {
    let rect: CGRect?
    let currentCapture: ReferenceCapture?
    var worldPosition: SIMD3<Float>? { currentCapture?.position }
    var worldBounds: SIMD3<Float>? { currentCapture?.bounds }
    let confidence: Float
    let message: String
    let referenceCapture: ReferenceCapture?
    let astraCapture: ReferenceCapture?
    let astraSourceTime: Double
    init(rect: CGRect?, currentCapture: ReferenceCapture?, confidence: Float, message: String,
         referenceCapture: ReferenceCapture? = nil,
         astraCapture: ReferenceCapture? = nil, astraSourceTime: Double = -.infinity) {
        self.rect = rect; self.currentCapture = currentCapture; self.confidence = confidence; self.message = message
        self.referenceCapture = referenceCapture
        self.astraCapture = astraCapture; self.astraSourceTime = astraSourceTime
    }
}

/// Astra supplies identity and silhouette. Vision only advances those pixels between replies;
/// depth/calibration turn them into measured world positions, without Apple semantic gates.
actor LocalObjectTracker {
    private var sequence = VNSequenceRequestHandler()
    private var tracked: VNDetectedObjectObservation?
    private var generation: UUID?
    private var lastAstraKey: ObservationKey?
    private var authorityTime: Double = -.infinity
    private var relativeOutline: [CGPoint] = []
    private var referenceCapture: ReferenceCapture?
    private var astraCapture: ReferenceCapture?
    private var recentImages: [(time: Double, image: CVPixelBuffer)] = []

    func process(_ sample: FrameSample, generation: UUID, recovery: MacTrackingRecovery? = nil,
                 referencePosition: SIMD3<Float>? = nil) -> LocalTrackingResult {
        if self.generation != generation {
            self.generation = generation
            tracked = nil; relativeOutline = []; lastAstraKey = nil
            referenceCapture = nil; recentImages = []; authorityTime = -.infinity
            astraCapture = nil
            sequence = VNSequenceRequestHandler()
        }
        // Four history images per second cover a typical Astra round trip at bounded memory.
        if recentImages.last.map({ sample.timestamp - $0.time >= 0.25 }) ?? true {
            recentImages.append((sample.timestamp, sample.image))
        }
        if recentImages.count > 24 { recentImages.removeFirst(recentImages.count - 24) }
        do {
            var advancedByAstra = false
            if let recovery, recovery.reply.key != lastAstraKey,
               recovery.reply.key.sessionID == recovery.sessionID,
               recovery.reply.key.objectID == recovery.objectID,
               recovery.reply.key.captureTime == recovery.source.timestamp,
               sample.timestamp >= recovery.source.timestamp,
               sample.timestamp - recovery.source.timestamp <= AstraGeometry.sourceLifetime {
                lastAstraKey = recovery.reply.key
                let reply = recovery.reply
                // Every new Astra answer supersedes local continuity, including uncertainty.
                tracked = nil; authorityTime = -.infinity
                astraCapture = nil
                if (reply.status == .identityConfirmed || reply.status == .tracked), reply.confidence >= 0.8,
                   let values = reply.rect, let rect = AstraGeometry.rectangle(values),
                   let outline = reply.outline, AstraGeometry.validOutline(outline, rect: values) {
                    let polygon = outline.map { CGPoint(x: $0[0], y: $0[1]) }
                    astraCapture = measure(recovery.source, polygon: polygon)
                    relativeOutline = polygon.map { CGPoint(x: ($0.x - rect.minX) / rect.width, y: ($0.y - rect.minY) / rect.height) }
                    // Build the immutable reference from the exact image/depth Astra inspected,
                    // even when its network response is older than the live overlay TTL.
                    if referencePosition == nil, referenceCapture == nil {
                        referenceCapture = astraCapture
                    }
                    authorityTime = recovery.source.timestamp
                    let newSequence = VNSequenceRequestHandler()
                    var observation = try advance(newSequence, image: recovery.source.image, observation:
                        VNDetectedObjectObservation(boundingBox: ImageCoordinates.visionRect(topLeftRect: rect)))
                    // Walk buffered images to avoid one large source-to-current jump after latency.
                    var bridge = recentImages.filter { $0.time > recovery.source.timestamp }
                    if bridge.last?.time != sample.timestamp { bridge.append((sample.timestamp, sample.image)) }
                    // Bound replay latency while always ending at the current sample.
                    let steps = min(8, bridge.count)
                    for step in 0..<steps {
                        let frame = bridge[steps == 1 ? bridge.count - 1 : step * (bridge.count - 1) / (steps - 1)]
                        guard let previous = observation else { break }
                        observation = try advance(newSequence, image: frame.image, observation: previous)
                    }
                    sequence = newSequence; tracked = observation
                    advancedByAstra = true
                }
            }
            guard sample.timestamp - authorityTime <= AstraGeometry.authorityLifetime else {
                tracked = nil
                return missing("Astra is finding your object…")
            }
            if !advancedByAstra, let tracked {
                self.tracked = try advance(sequence, image: sample.image, observation: tracked)
            }
            guard let tracked else { return missing("Astra is finding your object…") }
            let rect = ImageCoordinates.topLeftRect(visionRect: tracked.boundingBox)
            guard LocalTrackingEvidence.validSelectionRectangle(rect) != nil else { self.tracked = nil; return missing("Finding your object…") }
            let polygon = relativeOutline.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
            let geometry = measure(sample, polygon: polygon)
            if referencePosition == nil, referenceCapture == nil { referenceCapture = geometry }
            return LocalTrackingResult(rect: rect, currentCapture: geometry, confidence: tracked.confidence,
                message: geometry == nil ? "Move a little closer" : "Following your object",
                referenceCapture: referenceCapture,
                astraCapture: astraCapture, astraSourceTime: lastAstraKey?.captureTime ?? -.infinity)
        } catch {
            tracked = nil
            return missing("Astra is finding your object…")
        }
    }

    private func missing(_ message: String) -> LocalTrackingResult {
        LocalTrackingResult(rect: nil, currentCapture: nil, confidence: 0, message: message, referenceCapture: referenceCapture,
            astraCapture: astraCapture, astraSourceTime: lastAstraKey?.captureTime ?? -.infinity)
    }

    private func advance(_ sequence: VNSequenceRequestHandler, image: CVPixelBuffer,
                         observation: VNDetectedObjectObservation) throws -> VNDetectedObjectObservation? {
        let request = VNTrackObjectRequest(detectedObjectObservation: observation)
        request.trackingLevel = .accurate
        try sequence.perform([request], on: image, orientation: .up)
        guard let result = request.results?.first as? VNDetectedObjectObservation,
              !request.isLastFrame, result.confidence >= 0.6 else { return nil }
        return result
    }

    private func measure(_ sample: FrameSample, polygon: [CGPoint]) -> ReferenceCapture? {
        let pixels = AstraGeometry.depthPixels(depth: sample.depth, confidence: sample.confidence,
            width: sample.depthWidth, height: sample.depthHeight, polygon: polygon)
        guard pixels.count >= 12 else { return nil }
        var points: [SIMD3<Float>] = [], acceptedPixels: [(Int, Int)] = []
        // Bound both capture size and per-observation work for large selected objects.
        let step = max(1, Int(ceil(Double(pixels.count) / Double(ReferenceCapture.maximumPointCount))))
        for i in stride(from: 0, to: pixels.count, by: step) {
            let (x, y) = pixels[i]
            guard let pixel = Projection.imagePixel(depthX: x, depthY: y,
                depthWidth: sample.depthWidth, depthHeight: sample.depthHeight,
                imageWidth: CVPixelBufferGetWidth(sample.image), imageHeight: CVPixelBufferGetHeight(sample.image)),
                let camera = Projection.unproject(u: pixel.x, v: pixel.y, depth: sample.depth[y * sample.depthWidth + x],
                    fx: sample.intrinsics[0][0], fy: sample.intrinsics[1][1], cx: sample.intrinsics[2][0], cy: sample.intrinsics[2][1]) else { continue }
            let world = sample.cameraToWorld * SIMD4(camera.x, camera.y, camera.z, 1)
            points.append(SIMD3(world.x, world.y, world.z)); acceptedPixels.append((x, y))
        }
        guard points.count >= 12, let center = Projection.medianPosition(points) else { return nil }
        func extent(_ values: [Float]) -> Float {
            let sorted = values.sorted()
            return max(0.03, sorted[Int(Double(sorted.count - 1) * 0.95)] - sorted[Int(Double(sorted.count - 1) * 0.05)])
        }
        let bounds = SIMD3(extent(points.map(\.x)), extent(points.map(\.y)), extent(points.map(\.z)))
        let colors = sample.colors(at: acceptedPixels)
        return ReferenceCapture(timestamp: sample.timestamp, position: center, bounds: bounds,
            points: zip(points, colors).map { CapturedPoint(position: $0.0 - center, color: $0.1) })
    }
}
