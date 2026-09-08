import CoreVideo
import Foundation
import RealityGitCore
import Vision
import simd

/// Selection coordinates and output rectangles use the native camera image's
/// top-left origin, normalized to 0...1. Vision receives that same image as .up.
enum ObjectSelection: Sendable {
    case point(CGPoint)
    case rectangle(CGRect)
}

struct LocalTrackingResult: Sendable {
    let rect: CGRect?
    let worldPosition: SIMD3<Float>?
    let referenceRect: CGRect?
    let confidence: Float
    let message: String
    init(rect: CGRect?, worldPosition: SIMD3<Float>?, confidence: Float, message: String,
         referenceRect: CGRect? = nil) {
        self.rect = rect; self.worldPosition = worldPosition
        self.confidence = confidence; self.message = message; self.referenceRect = referenceRect
    }
}

actor LocalObjectTracker {
    private var sequence = VNSequenceRequestHandler()
    private var tracked: VNDetectedObjectObservation?
    private var generation: UUID?
    private var recoveryPolicy = MacRecoveryPolicy()
    private var currentSampleTime: Double = 0

    func process(_ sample: FrameSample, selection: ObjectSelection?, generation: UUID, recovery: MacTrackingRecovery? = nil) -> LocalTrackingResult {
        currentSampleTime = sample.timestamp
        if self.generation != generation || selection != nil {
            tracked = nil
            sequence = VNSequenceRequestHandler()
            self.generation = generation
            recoveryPolicy = MacRecoveryPolicy()
        }
        do {
            var recovered: VNDetectedObjectObservation?
            if selection == nil, tracked == nil, let recovery {
                let admittedRect = recoveryPolicy.admit(recovery.reply, sourceTime: recovery.source.timestamp,
                    currentTime: sample.timestamp, sessionID: recovery.sessionID, objectID: recovery.objectID)
                if let rect = admittedRect {
                    recoveryDiagnostic("Mac recovery attempt \(recoveryPolicy.attempts)")
                    if let (newSequence, current) = try MacRecoveryExecutor.recover(source: recovery.source, current: sample,
                        rect: rect, makeSequence: { VNSequenceRequestHandler() },
                        seed: { (sequence: VNSequenceRequestHandler, source: FrameSample, rect: CGRect) -> VNDetectedObjectObservation? in
                            let request = VNTrackObjectRequest(detectedObjectObservation:
                                VNDetectedObjectObservation(boundingBox: ImageCoordinates.visionRect(topLeftRect: rect)))
                            request.trackingLevel = .accurate
                            try sequence.perform([request], on: source.image, orientation: .up)
                            return request.isLastFrame ? nil : request.results?.first as? VNDetectedObjectObservation
                        }, advance: { (sequence: VNSequenceRequestHandler, current: FrameSample, previous: VNDetectedObjectObservation) -> VNDetectedObjectObservation? in
                            let request = VNTrackObjectRequest(detectedObjectObservation: previous)
                            request.trackingLevel = .accurate
                            try sequence.perform([request], on: current.image, orientation: .up)
                            return request.isLastFrame ? nil : request.results?.first as? VNDetectedObjectObservation
                        }, accepts: { $0.confidence >= 0.6 }) {
                        sequence = newSequence
                        tracked = current
                        recovered = current
                        recoveryPolicy.markTracked()
                        recoveryDiagnostic("Mac recovery advanced to current source")
                    } else { recoveryDiagnostic("Mac recovery forward pass uncertain") }
                } else {
                    recoveryDiagnostic("Mac recovery withheld: \(recoveryPolicy.rejectionReason ?? "unknown") confidence=\(recovery.reply.confidence)")
                }
            }
            let result = try observe(sample, selection: selection, recovered: recovered)
            if recovered != nil {
                // Recovery can supply current mask-backed geometry, but cannot replace the reference.
                return LocalTrackingResult(rect: result.rect, worldPosition: result.worldPosition,
                    confidence: result.confidence, message: result.message, referenceRect: nil)
            }
            return result
        } catch {
            diagnostic("Vision tracking request failed")
            tracked = nil
            recoveryPolicy.markLost(at: sample.timestamp)
            return LocalTrackingResult(rect: nil, worldPosition: nil, confidence: 0,
                message: "Could not follow this object. Tap it again or draw a box.")
        }
    }

    private func observe(_ sample: FrameSample, selection: ObjectSelection?, recovered: VNDetectedObjectObservation?) throws -> LocalTrackingResult {
        var predicted = recovered.map { ImageCoordinates.topLeftRect(visionRect: $0.boundingBox) }
        var trackingConfidence: Float = recovered?.confidence ?? 1
        if selection == nil && recovered == nil {
            guard let tracked else { return lost() }
            let request = VNTrackObjectRequest(detectedObjectObservation: tracked)
            request.trackingLevel = .accurate
            try sequence.perform([request], on: sample.image, orientation: .up)
            guard let result = request.results?.first as? VNDetectedObjectObservation, !request.isLastFrame, result.confidence >= 0.6 else {
                self.tracked = nil
                return lost(reason: "tracker confidence below 0.6 or no observation")
            }
            self.tracked = result
            recoveryPolicy.markTracked()
            predicted = ImageCoordinates.topLeftRect(visionRect: result.boundingBox)
            trackingConfidence = result.confidence
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: sample.image, orientation: .up)
        let request = VNGenerateForegroundInstanceMaskRequest()
        do { try handler.perform([request]) }
        catch { return maskUnavailable(predicted, confidence: trackingConfidence, reason: "foreground request failed") }
        guard let observation = request.results?.first else {
            return maskUnavailable(predicted, confidence: trackingConfidence, reason: "no mask")
        }
        let mask = observation.instanceMask
        guard CVPixelBufferGetPixelFormatType(mask) == kCVPixelFormatType_OneComponent8 else {
            return maskUnavailable(predicted, confidence: trackingConfidence, reason: "unsupported mask format")
        }
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return maskUnavailable(predicted, confidence: trackingConfidence, reason: "no mask pixels") }
        let width = CVPixelBufferGetWidth(mask), height = CVPixelBufferGetHeight(mask)
        let stride = CVPixelBufferGetBytesPerRow(mask)
        func labelAt(_ x: Int, _ y: Int) -> UInt8 {
            base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)[x]
        }

        let label: UInt8
        if case .point(let point) = selection {
            label = labelAt(min(width - 1, max(0, Int(point.x * Double(width)))),
                            min(height - 1, max(0, Int(point.y * Double(height)))))
        } else {
            let region: CGRect
            if case .rectangle(let rect) = selection { region = rect }
            else if let predicted { region = predicted }
            else { return lost() }
            var counts: [UInt8: Int] = [:]
            for y in 0..<height {
                for x in 0..<width where region.contains(CGPoint(x: (Double(x) + 0.5) / Double(width), y: (Double(y) + 0.5) / Double(height))) {
                    let value = labelAt(x, y)
                    if value != 0 { counts[value, default: 0] += 1 }
                }
            }
            let candidates = counts.sorted { $0.value > $1.value }
            guard let best = candidates.first, best.value >= 16,
                  candidates.count == 1 || Double(best.value) > Double(candidates[1].value) * 1.5 else {
                return maskUnavailable(predicted, confidence: trackingConfidence, reason: "ambiguous or empty mask")
            }
            label = best.key
        }
        guard label != 0 else {
            tracked = nil
            return LocalTrackingResult(rect: nil, worldPosition: nil, confidence: 0,
                message: "No object at that point. Tap its center or draw a tighter box.")
        }

        var minX = width, minY = height, maxX = 0, maxY = 0
        for y in 0..<height {
            for x in 0..<width where labelAt(x, y) == label {
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard minX < maxX, minY < maxY else { return maskUnavailable(predicted, confidence: trackingConfidence, reason: "empty mask extent") }
        let rect = CGRect(x: Double(minX) / Double(width), y: Double(minY) / Double(height),
            width: Double(maxX - minX + 1) / Double(width), height: Double(maxY - minY + 1) / Double(height))
        if let predicted {
            let overlap = predicted.intersection(rect)
            let unionArea = predicted.width * predicted.height + rect.width * rect.height - overlap.width * overlap.height
            guard !overlap.isNull, unionArea > 0,
                  overlap.width * overlap.height / unionArea >= 0.3 else {
                return maskUnavailable(predicted, confidence: trackingConfidence, reason: "mask/track mismatch")
            }
        }
        if selection != nil {
            // Initialize the sequence on the exact image that produced this mask.
            // Later requests must feed back Vision's result, preserving its UUID.
            let seed = VNDetectedObjectObservation(boundingBox: ImageCoordinates.visionRect(topLeftRect: rect))
            let initialize = VNTrackObjectRequest(detectedObjectObservation: seed)
            initialize.trackingLevel = .accurate
            try sequence.perform([initialize], on: sample.image, orientation: .up)
            guard let result = initialize.results?.first as? VNDetectedObjectObservation else { return lost() }
            tracked = result
            recoveryPolicy.markTracked()
        }

        var points: [SIMD3<Float>] = []
        let imageWidth = CVPixelBufferGetWidth(sample.image)
        let imageHeight = CVPixelBufferGetHeight(sample.image)
        for y in Swift.stride(from: 0, to: sample.depthHeight, by: 2) {
            for x in Swift.stride(from: 0, to: sample.depthWidth, by: 2) {
                let mx = min(width - 1, Int((Double(x) + 0.5) / Double(sample.depthWidth) * Double(width)))
                let my = min(height - 1, Int((Double(y) + 0.5) / Double(sample.depthHeight) * Double(height)))
                // Erode the label by one mask pixel to avoid mixed foreground/background depth at edges.
                guard mx > 0, my > 0, mx < width - 1, my < height - 1,
                      labelAt(mx, my) == label, labelAt(mx - 1, my) == label,
                      labelAt(mx + 1, my) == label, labelAt(mx, my - 1) == label,
                      labelAt(mx, my + 1) == label else { continue }
                let index = y * sample.depthWidth + x
                guard sample.confidence[index] >= 1,
                      let pixel = Projection.imagePixel(depthX: x, depthY: y,
                        depthWidth: sample.depthWidth, depthHeight: sample.depthHeight,
                        imageWidth: imageWidth, imageHeight: imageHeight),
                      let point = Projection.unproject(u: pixel.x, v: pixel.y, depth: sample.depth[index],
                        fx: sample.intrinsics[0][0], fy: sample.intrinsics[1][1],
                        cx: sample.intrinsics[2][0], cy: sample.intrinsics[2][1]) else { continue }
                points.append(point)
            }
        }
        guard points.count >= 12, let center = Projection.medianPosition(points) else {
            diagnostic("insufficient depth")
            return supportedResult(predicted: predicted, maskRect: rect, position: nil, confidence: trackingConfidence,
                message: "Object selected. Move closer for a reliable depth measurement.")
        }
        let world = sample.cameraToWorld * SIMD4(center.x, center.y, center.z, 1)
        diagnostic("mask and depth available")
        return supportedResult(predicted: predicted, maskRect: rect, position: SIMD3(world.x, world.y, world.z),
            confidence: trackingConfidence, message: "Following the selected object. Move slowly around it to check stability.")
    }

    private var lastRecoveryDiagnostic: String?
    private func recoveryDiagnostic(_ reason: String) {
        #if DEBUG
        if reason != lastRecoveryDiagnostic {
            print("Local recovery: \(reason)"); lastRecoveryDiagnostic = reason
        }
        #endif
    }
    private var lastDiagnostic: String?
    private func diagnostic(_ reason: String) {
        #if DEBUG
        if reason != lastDiagnostic { print("Local tracking: \(reason)"); lastDiagnostic = reason }
        #endif
    }
    private func supportedResult(predicted: CGRect?, maskRect: CGRect?, position: SIMD3<Float>?,
                                 confidence: Float, message: String) -> LocalTrackingResult {
        let evidence = LocalTrackingEvidence(confidentTrackedRect: predicted, maskRect: maskRect, maskPosition: position)
        return LocalTrackingResult(rect: evidence.displayRect, worldPosition: evidence.worldPosition,
            confidence: confidence, message: message, referenceRect: evidence.referenceRect)
    }
    private func maskUnavailable(_ predicted: CGRect?, confidence: Float, reason: String) -> LocalTrackingResult {
        diagnostic(reason)
        let evidence = LocalTrackingEvidence(confidentTrackedRect: predicted, maskRect: nil, maskPosition: nil)
        guard evidence.preservesTrack else { return lost(reason: reason) }
        // Keep the actual VN observation from this frame. Missing segmentation cannot erase a confident temporal track.
        return supportedResult(predicted: predicted, maskRect: nil, position: nil, confidence: confidence,
            message: "Following the object. Move closer for depth.")
    }
    private func lost(reason: String = "no continuous track; reselect required") -> LocalTrackingResult {
        diagnostic(reason)
        tracked = nil
        recoveryPolicy.markLost(at: currentSampleTime)
        return LocalTrackingResult(rect: nil, worldPosition: nil, confidence: 0,
            message: "Tracking is uncertain. Tap the object again to select it.")
    }
}
