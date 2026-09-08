import CoreImage
import Foundation
import RealityGitCore
import Vapor
import Vision

enum ObservationError: Error, Equatable {
    case invalidJPEG, invalidRectangle, obsolete, sessionLimit, timedOut

    var abort: Abort {
        switch self {
        case .invalidJPEG, .invalidRectangle: Abort(.badRequest, reason: "Invalid image or seed rectangle")
        case .obsolete: Abort(.conflict, reason: "Observation is stale or was superseded")
        case .sessionLimit: Abort(.serviceUnavailable, reason: "Observation session capacity reached")
        case .timedOut: Abort(.gatewayTimeout, reason: "Observation timed out")
        }
    }
}

struct LocalizationResult: Sendable {
    let rect: [Double]?
    let confidence: Double
    let candidateID: String?
    let status: DetectionStatus
}

actor VisionWorker {
    typealias Localizer = @Sendable (FrameRequest, FrameRequest?) throws -> LocalizationResult

    private final class Submission: @unchecked Sendable {
        let request: FrameRequest
        let generation: UInt64
        var continuation: CheckedContinuation<DetectionReply, Error>?
        var completed = false
        init(_ request: FrameRequest, generation: UInt64, _ continuation: CheckedContinuation<DetectionReply, Error>) {
            self.request = request; self.generation = generation; self.continuation = continuation
        }
    }

    private let localizer: Localizer
    private struct StreamKey: Hashable { let sessionID: UUID; let objectID: UUID }
    private let timeoutNanoseconds: UInt64
    private let maxSessions: Int
    private var active: Submission?
    private var pending: Submission?
    private var reference: FrameRequest?
    private var currentScope: StreamKey?
    private var generation: UInt64 = 0
    private var latestFrames: [StreamKey: UInt64] = [:]
    private var admittedAt: [StreamKey: ContinuousClock.Instant] = [:]

    init(timeout: Duration = .seconds(3), maxSessions: Int = 12, localizer: Localizer? = nil) {
        let engine = VisionLocalizer()
        self.localizer = localizer ?? engine.localize
        let parts = timeout.components
        self.timeoutNanoseconds = UInt64(max(0, parts.seconds)) * 1_000_000_000
            + UInt64(max(0, parts.attoseconds / 1_000_000_000))
        self.maxSessions = maxSessions
    }

    func observe(_ request: FrameRequest) async throws -> DetectionReply {
        try validate(request)
        expireAdmissions()
        let stream = StreamKey(sessionID: request.key.sessionID, objectID: request.key.objectID)
        if request.isReference, stream != currentScope {
            generation &+= 1
            currentScope = stream
            reference = nil
            if let pending { finish(pending, .failure(ObservationError.obsolete)); self.pending = nil }
        } else if let currentScope, stream != currentScope {
            throw ObservationError.obsolete
        }
        if let latest = latestFrames[stream], request.key.frameID <= latest { throw ObservationError.obsolete }
        if latestFrames[stream] == nil && latestFrames.count >= maxSessions { throw ObservationError.sessionLimit }
        latestFrames[stream] = request.key.frameID
        admittedAt[stream] = .now

        return try await withCheckedThrowingContinuation { continuation in
            let submission = Submission(request, generation: generation, continuation)
            if active == nil {
                active = submission
                launch(submission)
            } else {
                if let old = pending { finish(old, .failure(ObservationError.obsolete)) }
                pending = submission
            }
            scheduleTimeout(submission)
        }
    }

    private func validate(_ request: FrameRequest) throws {
        guard !request.jpeg.isEmpty, request.jpeg.count <= 4 * 1024 * 1024 else { throw ObservationError.invalidJPEG }
        if let rect = request.seedRect {
            guard rect.count == 4, rect.allSatisfy(\.isFinite), rect.allSatisfy({ $0 >= 0 && $0 <= 1 }),
                  rect[2] > 0, rect[3] > 0, rect[0] + rect[2] <= 1, rect[1] + rect[3] <= 1 else {
                throw ObservationError.invalidRectangle
            }
        }
        if request.isReference && request.seedRect == nil { throw ObservationError.invalidRectangle }
    }

    private func launch(_ submission: Submission) {
        let localizer = self.localizer
        let immutableReference = reference
        Task.detached(priority: .userInitiated) {
            let result = Result { try localizer(submission.request, immutableReference) }
            await self.processingFinished(submission, result)
        }
    }

    private func processingFinished(_ submission: Submission, _ result: Result<LocalizationResult, Error>) {
        guard submission.generation == generation else {
            finish(submission, .failure(ObservationError.obsolete))
            if active === submission {
                active = pending; pending = nil
                if let active { launch(active) }
            }
            return
        }
        if reference == nil, submission.request.isReference, case .success = result {
            reference = submission.request
        }
        finish(submission, result.map { result in
            DetectionReply(key: submission.request.key, rect: result.rect, confidence: result.confidence,
                           candidateID: result.candidateID, status: result.status)
        })
        if active === submission {
            active = pending; pending = nil
            if let active { launch(active) }
        }
    }

    private func scheduleTimeout(_ submission: Submission) {
        let delay = timeoutNanoseconds
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            await self?.timeOut(submission)
        }
    }

    private func timeOut(_ submission: Submission) {
        if pending === submission { pending = nil }
        finish(submission, .failure(ObservationError.timedOut))
    }

    private func finish(_ submission: Submission, _ result: Result<DetectionReply, Error>) {
        guard !submission.completed else { return }
        submission.completed = true
        let continuation = submission.continuation
        submission.continuation = nil
        continuation?.resume(with: result)
    }

    private func expireAdmissions() {
        let cutoff = ContinuousClock.now - .seconds(5)
        for (key, time) in admittedAt where time < cutoff {
            // Expire retained payload accounting, but keep the frame high-water mark so
            // an old frame cannot be replayed after the five-second window.
            admittedAt.removeValue(forKey: key)
        }
    }

    func pendingFrameIDForTesting() -> UInt64? { pending?.request.key.frameID }
}

private final class VisionLocalizer: @unchecked Sendable {
    private var referencePrint: VNFeaturePrintObservation?
    private var trackedRect: CGRect?
    private var sequence = VNSequenceRequestHandler()

    func localize(_ request: FrameRequest, _ reference: FrameRequest?) throws -> LocalizationResult {
        guard let image = CIImage(data: request.jpeg) else { throw ObservationError.invalidJPEG }
        let handler = VNImageRequestHandler(ciImage: image, orientation: .up)

        if reference == nil, request.isReference, let seed = request.seedRect {
            sequence = VNSequenceRequestHandler()
            let visionRect = CGRect(x: seed[0], y: 1 - seed[1] - seed[3], width: seed[2], height: seed[3])
            trackedRect = visionRect
            referencePrint = try featurePrint(image.cropped(to: pixelRect(visionRect, image.extent)))
            let initialize = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: visionRect))
            try sequence.perform([initialize], on: image, orientation: .up)
            return LocalizationResult(rect: seed, confidence: 1, candidateID: nil, status: .identityConfirmed)
        }

        if let visionRect = trackedRect {
            let observation = VNDetectedObjectObservation(boundingBox: visionRect)
            let tracking = VNTrackObjectRequest(detectedObjectObservation: observation)
            tracking.trackingLevel = .accurate
            try sequence.perform([tracking], on: image, orientation: .up)
            if let result = tracking.results?.first as? VNDetectedObjectObservation, !tracking.isLastFrame,
               result.confidence >= 0.35 {
                let rect = result.boundingBox
                trackedRect = rect
                return LocalizationResult(rect: [rect.minX, 1 - rect.maxY, rect.width, rect.height],
                                          confidence: Double(result.confidence), candidateID: nil,
                                          status: .tracked)
            }
            trackedRect = nil
        }

        guard let referencePrint else {
            return LocalizationResult(rect: nil, confidence: 0, candidateID: nil, status: .notFound)
        }
        let saliency = VNGenerateObjectnessBasedSaliencyImageRequest()
        try handler.perform([saliency])
        let candidates = saliency.results?.first?.salientObjects ?? []
        var best: (VNRectangleObservation, Float)?
        for candidate in candidates.prefix(8) {
            let crop = image.cropped(to: pixelRect(candidate.boundingBox, image.extent))
            let print = try featurePrint(crop)
            var distance: Float = 0
            try referencePrint.computeDistance(&distance, to: print)
            if best == nil || distance < best!.1 { best = (candidate, distance) }
        }
        if let (candidate, distance) = best {
            let rect = candidate.boundingBox
            return LocalizationResult(rect: [rect.minX, 1 - rect.maxY, rect.width, rect.height],
                                      confidence: max(0, 1 - Double(distance)),
                                      candidateID: UUID().uuidString, status: .candidate)
        }
        return LocalizationResult(rect: nil, confidence: 0, candidateID: nil, status: .notFound)
    }

    private func featurePrint(_ image: CIImage) throws -> VNFeaturePrintObservation {
        let request = VNGenerateImageFeaturePrintRequest()
        try VNImageRequestHandler(ciImage: image, orientation: .up).perform([request])
        guard let result = request.results?.first as? VNFeaturePrintObservation else {
            throw ObservationError.invalidJPEG
        }
        return result
    }

    private func pixelRect(_ normalized: CGRect, _ extent: CGRect) -> CGRect {
        CGRect(x: extent.minX + normalized.minX * extent.width,
               y: extent.minY + normalized.minY * extent.height,
               width: normalized.width * extent.width,
               height: normalized.height * extent.height)
    }
}
