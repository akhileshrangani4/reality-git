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
    let confidence: Float
    let message: String
}

actor LocalObjectTracker {
    private var sequence = VNSequenceRequestHandler()
    private var tracked: VNDetectedObjectObservation?
    private var generation: UUID?

    func process(_ sample: FrameSample, selection: ObjectSelection?, generation: UUID) -> LocalTrackingResult {
        if self.generation != generation || selection != nil {
            tracked = nil
            sequence = VNSequenceRequestHandler()
            self.generation = generation
        }
        do {
            return try observe(sample, selection: selection)
        } catch {
            tracked = nil
            return LocalTrackingResult(rect: nil, worldPosition: nil, confidence: 0,
                message: "Could not follow this object. Tap it again or draw a box.")
        }
    }

    private func observe(_ sample: FrameSample, selection: ObjectSelection?) throws -> LocalTrackingResult {
        var predicted: CGRect?
        var trackingConfidence: Float = 1
        if selection == nil {
            guard let tracked else { return lost() }
            let request = VNTrackObjectRequest(detectedObjectObservation: tracked)
            request.trackingLevel = .accurate
            try sequence.perform([request], on: sample.image, orientation: .up)
            guard let result = request.results?.first as? VNDetectedObjectObservation, result.confidence >= 0.6 else {
                self.tracked = nil
                return lost()
            }
            self.tracked = result
            predicted = ImageCoordinates.topLeftRect(visionRect: result.boundingBox)
            trackingConfidence = result.confidence
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: sample.image, orientation: .up)
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let observation = request.results?.first else {
            tracked = nil
            return lost()
        }
        let mask = observation.instanceMask
        guard CVPixelBufferGetPixelFormatType(mask) == kCVPixelFormatType_OneComponent8 else {
            tracked = nil
            return lost()
        }
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return lost() }
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
                tracked = nil
                return lost()
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
        guard minX < maxX, minY < maxY else { return lost() }
        let rect = CGRect(x: Double(minX) / Double(width), y: Double(minY) / Double(height),
            width: Double(maxX - minX + 1) / Double(width), height: Double(maxY - minY + 1) / Double(height))
        if let predicted {
            let overlap = predicted.intersection(rect)
            let unionArea = predicted.width * predicted.height + rect.width * rect.height - overlap.width * overlap.height
            guard !overlap.isNull, unionArea > 0,
                  overlap.width * overlap.height / unionArea >= 0.3 else {
                tracked = nil
                return lost()
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
            return LocalTrackingResult(rect: rect, worldPosition: nil, confidence: trackingConfidence,
                message: "Object selected. Move closer for a reliable depth measurement.")
        }
        let world = sample.cameraToWorld * SIMD4(center.x, center.y, center.z, 1)
        return LocalTrackingResult(rect: rect, worldPosition: SIMD3(world.x, world.y, world.z),
            confidence: trackingConfidence, message: "Following the selected object. Move slowly around it to check stability.")
    }

    private func lost() -> LocalTrackingResult {
        tracked = nil
        return LocalTrackingResult(rect: nil, worldPosition: nil, confidence: 0,
            message: "Tracking is uncertain. Tap the object again to select it.")
    }
}
