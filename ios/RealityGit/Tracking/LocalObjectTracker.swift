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
    let capturedPoints: [CapturedPoint]
    let worldPosition: SIMD3<Float>?
    let referenceRect: CGRect?
    let initializationRect: CGRect?
    let worldBounds: SIMD3<Float>?
    let confidence: Float
    let message: String
    init(rect: CGRect?, worldPosition: SIMD3<Float>?, confidence: Float, message: String,
         referenceRect: CGRect? = nil, worldBounds: SIMD3<Float>? = nil, initializationRect: CGRect? = nil, capturedPoints: [CapturedPoint] = []) {
        self.capturedPoints = capturedPoints
        self.rect = rect; self.worldPosition = worldPosition
        self.confidence = confidence; self.message = message; self.referenceRect = referenceRect; self.worldBounds = worldBounds; self.initializationRect = initializationRect
    }
}

actor LocalObjectTracker {
    private var sequence = VNSequenceRequestHandler()
    private var tracked: VNDetectedObjectObservation?
    private var generation: UUID?
    private var recoveryPolicy = MacRecoveryPolicy()
    private var support: [(Float, Float)] = []
    private var lastSupportedWorld: SIMD3<Float>?
    private var explicitDepthSelection = false
    private var lastMaskAttempt: Double = -.infinity
    private var supportTime: Double = -.infinity
    private var activeSelection: ObjectSelection?
    private var activeSample: FrameSample?
    private var currentSampleTime: Double = 0

    func process(_ sample: FrameSample, selection: ObjectSelection?, generation: UUID, recovery: MacTrackingRecovery? = nil) -> LocalTrackingResult {
        activeSelection = selection
        activeSample = sample
        currentSampleTime = sample.timestamp
        if self.generation != generation || selection != nil {
            tracked = nil
            support = []
            lastSupportedWorld = nil
            if case .rectangle = selection { explicitDepthSelection = true } else { explicitDepthSelection = false }
            sequence = VNSequenceRequestHandler()
            self.generation = generation
            recoveryPolicy = MacRecoveryPolicy()
        }
        do {
            var explicitSeed: CGRect?
            var initialized: VNDetectedObjectObservation?
            if case .rectangle(let box) = selection,
               let box = LocalTrackingEvidence.validSelectionRectangle(box) {
                explicitSeed = box
                let request = VNTrackObjectRequest(detectedObjectObservation:
                    VNDetectedObjectObservation(boundingBox: ImageCoordinates.visionRect(topLeftRect: box)))
                request.trackingLevel = .accurate
                try sequence.perform([request], on: sample.image, orientation: .up)
                if let result = request.results?.first as? VNDetectedObjectObservation,
                   !request.isLastFrame, result.confidence >= 0.6 {
                    tracked = result; initialized = result
                    recoveryPolicy.markTracked()
                }
            }
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
            let result = try observe(sample, selection: selection, recovered: recovered ?? initialized)
            if recovered != nil {
                // Recovery can supply current mask-backed geometry, but cannot replace the reference.
                return LocalTrackingResult(rect: result.rect, worldPosition: result.worldPosition,
                    confidence: result.confidence, message: result.message, referenceRect: nil, worldBounds: result.worldBounds, capturedPoints: result.capturedPoints)
            }
            if let explicitSeed {
                return LocalTrackingResult(rect: result.rect, worldPosition: result.worldPosition,
                    confidence: result.confidence, message: result.message, referenceRect: result.referenceRect,
                    worldBounds: result.worldBounds, initializationRect: explicitSeed, capturedPoints: result.capturedPoints)
            }
            return result
        } catch {
            diagnostic("Vision tracking request failed")
            tracked = nil
            recoveryPolicy.markLost(at: sample.timestamp)
            return LocalTrackingResult(rect: nil, worldPosition: nil, confidence: 0,
                message: "Looking for remembered object. Tap it to help reconnect.")
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

        if selection == nil, let predicted, !support.isEmpty, sample.timestamp - lastMaskAttempt < 0.8 {
            let quick = maskUnavailable(predicted, confidence: trackingConfidence, reason: "checking captured foreground depth")
            if quick.worldPosition != nil { return quick }
        }
        lastMaskAttempt = sample.timestamp
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
        if case .point = selection {
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
        var pixels: [(Int, Int)] = []
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
                pixels.append((x, y))
            }
        }
        guard points.count >= 12, let center = Projection.medianPosition(points) else {
            diagnostic("insufficient depth")
            return supportedResult(predicted: predicted, maskRect: rect, position: nil, confidence: trackingConfidence,
                message: "Object selected. Move closer for a reliable depth measurement.")
        }
        support = pixels.map { (Float((Double($0.0) + 0.5) / Double(sample.depthWidth) - rect.minX) / Float(rect.width), Float((Double($0.1) + 0.5) / Double(sample.depthHeight) - rect.minY) / Float(rect.height)) }
        supportTime = sample.timestamp
        let colors = sample.colors(at: pixels)
        let world = sample.cameraToWorld * SIMD4(center.x, center.y, center.z, 1)
        lastSupportedWorld = SIMD3(world.x, world.y, world.z)
        let worldPoints = points.map { point in
            let value = sample.cameraToWorld * SIMD4(point.x, point.y, point.z, 1)
            return SIMD3(value.x, value.y, value.z)
        }
        func extent(_ values: [Float]) -> Float {
            let sorted = values.sorted()
            return max(0.03, sorted[Int(Double(sorted.count - 1) * 0.95)] - sorted[Int(Double(sorted.count - 1) * 0.05)])
        }
        let bounds = SIMD3(extent(worldPoints.map(\.x)), extent(worldPoints.map(\.y)), extent(worldPoints.map(\.z)))
        diagnostic("mask and depth available")
        return supportedResult(predicted: predicted, maskRect: rect, position: SIMD3(world.x, world.y, world.z),
            confidence: trackingConfidence, message: "Following the selected object. Move slowly around it to check stability.", bounds: bounds, capturedPoints: zip(worldPoints, colors).map { CapturedPoint(position: $0.0 - SIMD3(world.x, world.y, world.z), color: $0.1) })
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
                                 confidence: Float, message: String, bounds: SIMD3<Float>? = nil, capturedPoints: [CapturedPoint] = []) -> LocalTrackingResult {
        let evidence = LocalTrackingEvidence(confidentTrackedRect: predicted, maskRect: maskRect, maskPosition: position)
        return LocalTrackingResult(rect: evidence.displayRect, worldPosition: evidence.worldPosition,
            confidence: confidence, message: message, referenceRect: evidence.referenceRect, worldBounds: bounds, capturedPoints: capturedPoints)
    }
    private func maskUnavailable(_ predicted: CGRect?, confidence: Float, reason: String) -> LocalTrackingResult {
        diagnostic(reason)
        let depthRegion: CGRect?
        if case .rectangle(let rect) = activeSelection { depthRegion = predicted == nil ? nil : rect }
        else { depthRegion = (explicitDepthSelection || !support.isEmpty) && confidence >= 0.8 ? predicted : nil }
        if let sample = activeSample, let rect = depthRegion {
            let indices = ForegroundDepth.indices(depth: sample.depth, confidence: sample.confidence, width: sample.depthWidth, height: sample.depthHeight, rect: rect)
            var cameraPoints: [SIMD3<Float>] = []
            var pixels: [(Int, Int)] = []
            for i in indices {
                let x = i % sample.depthWidth, y = i / sample.depthWidth
                guard let pixel = Projection.imagePixel(depthX: x, depthY: y, depthWidth: sample.depthWidth, depthHeight: sample.depthHeight, imageWidth: CVPixelBufferGetWidth(sample.image), imageHeight: CVPixelBufferGetHeight(sample.image)), let p = Projection.unproject(u: pixel.x, v: pixel.y, depth: sample.depth[i], fx: sample.intrinsics[0][0], fy: sample.intrinsics[1][1], cx: sample.intrinsics[2][0], cy: sample.intrinsics[2][1]) else { continue }
                cameraPoints.append(p); pixels.append((x,y))
            }
            if let center = Projection.medianPosition(cameraPoints), cameraPoints.count >= 12, fallbackDepthIsVisible(center, sample: sample) {
                let w = sample.cameraToWorld * SIMD4(center.x, center.y, center.z, 1)
                let position = SIMD3(w.x,w.y,w.z)
                if lastSupportedWorld == nil { lastSupportedWorld = position }
                let worldPoints = cameraPoints.map { p in
                    let w = sample.cameraToWorld * SIMD4(p.x,p.y,p.z,1)
                    return SIMD3(w.x,w.y,w.z)
                }
                let colors = sample.colors(at: pixels)
                support = pixels.map { (Float((Double($0.0)+0.5)/Double(sample.depthWidth)-rect.minX)/Float(rect.width), Float((Double($0.1)+0.5)/Double(sample.depthHeight)-rect.minY)/Float(rect.height)) }
                supportTime = sample.timestamp
                var low = worldPoints[0], high = low
                for p in worldPoints { low = simd_min(low,p); high = simd_max(high,p) }
                return LocalTrackingResult(rect: predicted ?? rect, worldPosition: position, confidence: confidence, message: "Remembered depth shape", referenceRect: rect, worldBounds: simd_max(high-low,SIMD3(repeating:0.03)), capturedPoints: zip(worldPoints,colors).map { CapturedPoint(position:$0.0-position,color:$0.1) })
            }
        }
        if let predicted, confidence >= 0.8, let sample = activeSample, sample.timestamp - supportTime <= 1.5, support.count >= 12 {
            var points: [SIMD3<Float>] = []
            for uv in support {
                let x = Int((predicted.minX + Double(uv.0) * predicted.width) * Double(sample.depthWidth))
                let y = Int((predicted.minY + Double(uv.1) * predicted.height) * Double(sample.depthHeight))
                guard x >= 0, y >= 0, x < sample.depthWidth, y < sample.depthHeight else { continue }
                let i = y * sample.depthWidth + x
                guard sample.confidence[i] >= 2, let pixel = Projection.imagePixel(depthX: x, depthY: y, depthWidth: sample.depthWidth, depthHeight: sample.depthHeight, imageWidth: CVPixelBufferGetWidth(sample.image), imageHeight: CVPixelBufferGetHeight(sample.image)), let p = Projection.unproject(u: pixel.x, v: pixel.y, depth: sample.depth[i], fx: sample.intrinsics[0][0], fy: sample.intrinsics[1][1], cx: sample.intrinsics[2][0], cy: sample.intrinsics[2][1]) else { continue }
                points.append(p)
            }
            if points.count >= max(12, support.count / 2), let center = Projection.medianPosition(points) {
                let coherent = points.filter { abs($0.z - center.z) < 0.08 }
                if coherent.count * 10 >= points.count * 8, fallbackDepthIsVisible(center, sample: sample) {
                    let world = sample.cameraToWorld * SIMD4(center.x, center.y, center.z, 1)
                    return LocalTrackingResult(rect: predicted, worldPosition: SIMD3(world.x, world.y, world.z), confidence: confidence, message: "Following remembered object", worldBounds: SIMD3(repeating: 0.1))
                }
            }
        }
        let evidence = LocalTrackingEvidence(confidentTrackedRect: predicted, maskRect: nil, maskPosition: nil)
        guard evidence.preservesTrack else { return lost(reason: reason) }
        // Keep the actual VN observation from this frame. Missing segmentation cannot erase a confident temporal track.
        return supportedResult(predicted: predicted, maskRect: nil, position: nil, confidence: confidence,
            message: "Following the object. For capture, draw a box with a little background around it.")
    }
    private func fallbackDepthIsVisible(_ center: SIMD3<Float>, sample: FrameSample) -> Bool {
        guard let lastSupportedWorld else { return true }
        return ForegroundDepth.allowsFallback(measuredDepth: -center.z, supportedWorld: lastSupportedWorld, cameraToWorld: sample.cameraToWorld)
    }

    private func lost(reason: String = "no continuous track; reselect required") -> LocalTrackingResult {
        diagnostic(reason)
        tracked = nil
        recoveryPolicy.markLost(at: currentSampleTime)
        return LocalTrackingResult(rect: nil, worldPosition: nil, confidence: 0,
            message: "Looking for remembered object. Tap it to help reconnect.")
    }
}
