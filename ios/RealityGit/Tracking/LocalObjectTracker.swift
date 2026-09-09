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
    let provisionalCapture: ReferenceCapture?
    let astraSourceTime: Double
    init(rect: CGRect?, currentCapture: ReferenceCapture?, confidence: Float, message: String,
         referenceCapture: ReferenceCapture? = nil,
         astraCapture: ReferenceCapture? = nil, astraSourceTime: Double = -.infinity,
         provisionalCapture: ReferenceCapture? = nil) {
        self.rect = rect; self.currentCapture = currentCapture; self.confidence = confidence; self.message = message
        self.referenceCapture = referenceCapture
        self.provisionalCapture = provisionalCapture
        self.astraCapture = astraCapture; self.astraSourceTime = astraSourceTime
    }
}

/// Astra supplies identity and silhouette; the phone advances pixels and measures depth.
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
    private var continuity = TraceContinuityCache()
    private var provisional = false
    private var previewStart: Double = -.infinity
    #if DEBUG
    private(set) var continuityHits = 0
    #endif

    func process(_ sample: FrameSample, generation: UUID, recovery: MacTrackingRecovery? = nil,
                 referencePosition: SIMD3<Float>? = nil, selection: ObjectSelection? = nil,
                 onReference: (@MainActor @Sendable (ReferenceCapture) -> Void)? = nil) async -> LocalTrackingResult {
        if self.generation != generation {
            self.generation = generation
            tracked = nil; relativeOutline = []; lastAstraKey = nil
            referenceCapture = nil; recentImages = []; authorityTime = -.infinity
            astraCapture = nil; provisional = false; continuity.reset()
            sequence = VNSequenceRequestHandler()
        }
        let image = sample.trackingImage()
        // Small image derivatives cover model latency without retaining full camera frames.
        if recentImages.last.map({ sample.timestamp - $0.time >= 0.25 }) ?? true {
            recentImages.append((sample.timestamp, image))
        }
        if recentImages.count > 24 { recentImages.removeFirst(recentImages.count - 24) }
        do {
            var advanced = false
            var initialPreview: ReferenceCapture?
            if let selection, referencePosition == nil, lastAstraKey == nil,
               let (capture, rect) = CaptureGeometry.preview(sample, selection: selection) {
                initialPreview = capture; provisional = true; previewStart = sample.timestamp
                tracked = VNDetectedObjectObservation(boundingBox: ImageCoordinates.visionRect(topLeftRect: rect))
                advanced = true
            }
            if let recovery, recovery.reply.key != lastAstraKey,
               recovery.reply.key.sessionID == recovery.sessionID,
               recovery.reply.key.objectID == recovery.objectID,
               recovery.reply.key.captureTime == recovery.source.timestamp,
               sample.timestamp >= recovery.source.timestamp,
               sample.timestamp - recovery.source.timestamp <= AstraGeometry.sourceLifetime {
                lastAstraKey = recovery.reply.key
                provisional = false
                let reply = recovery.reply
                astraCapture = nil
                if (reply.status == .identityConfirmed || reply.status == .tracked), reply.confidence >= 0.8,
                   let values = reply.rect, let rect = AstraGeometry.rectangle(values),
                   let outline = reply.outline, AstraGeometry.validOutline(outline, rect: values) {
                    let polygon = outline.map { CGPoint(x: $0[0], y: $0[1]) }
                    astraCapture = CaptureGeometry.measure(recovery.source, polygon: polygon)
                    // Publish the saved surface before any expensive reacquisition replay.
                    if referencePosition == nil, referenceCapture == nil, let capture = astraCapture {
                        referenceCapture = capture
                        await onReference?(capture)
                    }
                    if tracked != nil, let sourceRect = continuity.sourceRect(matching: rect,
                        time: recovery.source.timestamp, now: sample.timestamp) {
                        // Map Astra's outline through the SAME pixel box observed at its source time.
                        // No cached model answer is relabelled as a new observation.
                        relativeOutline = relative(polygon, to: sourceRect)
                        authorityTime = sample.timestamp
                        #if DEBUG
                        continuityHits += 1
                        #endif
                    } else {
                        continuity.reset()
                        relativeOutline = relative(polygon, to: rect)
                        let newSequence = VNSequenceRequestHandler()
                        var observation = try advance(newSequence, image: recovery.source.trackingImage(), observation:
                            VNDetectedObjectObservation(boundingBox: ImageCoordinates.visionRect(topLeftRect: rect)))
                        var bridge = recentImages.filter { $0.time > recovery.source.timestamp }
                        if bridge.last?.time != sample.timestamp { bridge.append((sample.timestamp, image)) }
                        let steps = min(8, bridge.count)
                        for step in 0..<steps {
                            let frame = bridge[steps == 1 ? bridge.count - 1 : step * (bridge.count - 1) / (steps - 1)]
                            guard let previous = observation else { break }
                            observation = try advance(newSequence, image: frame.image, observation: previous)
                        }
                        sequence = newSequence; tracked = observation; advanced = true
                        // Only a new Astra confirmation plus successful continuity grants a lease.
                        // Ordinary local frames can never extend semantic authority.
                        authorityTime = observation != nil && sample.timestamp - recovery.source.timestamp <= AstraGeometry.authorityLifetime
                            ? sample.timestamp : recovery.source.timestamp
                    }
                } else {
                    // Uncertainty or absence immediately revokes preview and cached continuity.
                    tracked = nil; authorityTime = -.infinity; continuity.reset()
                }
            }
            let validUntil = provisional ? previewStart : authorityTime
            guard sample.timestamp - validUntil <= AstraGeometry.authorityLifetime else {
                tracked = nil; continuity.reset()
                return missing("Astra is finding your object…")
            }
            if !advanced, let tracked {
                self.tracked = try advance(sequence, image: image, observation: tracked)
            }
            guard let tracked else { continuity.reset(); return missing("Astra is finding your object…") }
            let rect = ImageCoordinates.topLeftRect(visionRect: tracked.boundingBox)
            guard LocalTrackingEvidence.validSelectionRectangle(rect) != nil else {
                self.tracked = nil; continuity.reset(); return missing("Finding your object…")
            }
            continuity.record(rect: rect, confidence: tracked.confidence, time: sample.timestamp)
            if provisional {
                let capture = initialPreview ?? CaptureGeometry.preview(sample, selection: .rectangle(rect))?.0
                return LocalTrackingResult(rect: rect, currentCapture: nil, confidence: tracked.confidence,
                    message: "Scanning your object…", provisionalCapture: capture)
            }
            let polygon = relativeOutline.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
            let geometry = CaptureGeometry.measure(sample, polygon: polygon)
            return LocalTrackingResult(rect: rect, currentCapture: geometry, confidence: tracked.confidence,
                message: geometry == nil ? "Move a little closer" : "Following your object",
                referenceCapture: referenceCapture, astraCapture: astraCapture,
                astraSourceTime: lastAstraKey?.captureTime ?? -.infinity)
        } catch {
            tracked = nil; continuity.reset()
            return missing("Astra is finding your object…")
        }
    }

    private func relative(_ polygon: [CGPoint], to rect: CGRect) -> [CGPoint] {
        polygon.map { CGPoint(x: ($0.x - rect.minX) / rect.width, y: ($0.y - rect.minY) / rect.height) }
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
}
