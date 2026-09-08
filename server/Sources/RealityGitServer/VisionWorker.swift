import CoreImage
import Foundation
import ImageIO
import RealityGitCore
import UniformTypeIdentifiers
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
        let id = UUID()
        let request: FrameRequest
        let generation: UInt64
        var continuation: CheckedContinuation<DetectionReply, Error>?
        var completed = false
        init(_ request: FrameRequest, generation: UInt64, _ continuation: CheckedContinuation<DetectionReply, Error>) {
            self.request = request; self.generation = generation; self.continuation = continuation
        }
    }

    private let semanticProvider: AstraLabeler.Provider
    private var semanticActive = false
    private var semanticPending: FrameRequest?
    private var semanticLabel: String?
    private var semanticStatus: String?
    typealias AuthorizedLocalizer = @Sendable (FrameRequest, FrameRequest?, String?) throws -> LocalizationResult
    private let comparator: AstraLabeler.Comparator
    private let now: @Sendable () -> Double
    private var candidateID: String?
    private var authorizedCandidateID: String?
    private var comparisonPending: FrameRequest?
    private var comparedCandidateID: String?
    private var lastComparisonTime = -Double.infinity
    private let localizer: AuthorizedLocalizer
    private struct StreamKey: Hashable { let sessionID: UUID; let objectID: UUID }
    private let timeoutNanoseconds: UInt64
    private let validateImageMetadata: Bool
    private var active: Submission?
    private var pending: Submission?
    private var reference: FrameRequest?
    private var currentScope: StreamKey?
    private var selectionCaptureTime: Double?
    private var generation: UInt64 = 0
    private var latestFrameID: UInt64?

    init(timeout: Duration = .seconds(3), validateImageMetadata: Bool = true, localizer: Localizer? = nil, semanticProvider: @escaping AstraLabeler.Provider = AstraLabeler.label,
         comparator: @escaping AstraLabeler.Comparator = AstraLabeler.compare,
         authorizedLocalizer: AuthorizedLocalizer? = nil,
         now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.comparator = comparator
        self.now = now
        self.semanticProvider = semanticProvider
        let engine = VisionLocalizer()
        if let authorizedLocalizer { self.localizer = authorizedLocalizer }
        else if let localizer { self.localizer = { request, reference, _ in try localizer(request, reference) } }
        else { self.localizer = { request, reference, authorization in try engine.localize(request, reference, authorizedCandidateID: authorization) } }
        let parts = timeout.components
        self.timeoutNanoseconds = UInt64(max(0, parts.seconds)) * 1_000_000_000
            + UInt64(max(0, parts.attoseconds / 1_000_000_000))
        self.validateImageMetadata = validateImageMetadata
    }

    func observe(_ request: FrameRequest) async throws -> DetectionReply {
        try validate(request)
        let stream = StreamKey(sessionID: request.key.sessionID, objectID: request.key.objectID)
        let startsNewSelection = request.isReference && stream != currentScope
        if startsNewSelection {
            if let selectionCaptureTime, request.key.captureTime <= selectionCaptureTime {
                throw ObservationError.obsolete
            }
        } else if let currentScope, stream != currentScope {
            throw ObservationError.obsolete
        }
        if !startsNewSelection, let latestFrameID, request.key.frameID <= latestFrameID {
            throw ObservationError.obsolete
        }

        // The phone supplies monotonically increasing captureTime across selections.
        // Only a reference captured after the current selection may retire it.
        if request.isReference, stream != currentScope {
            generation &+= 1
            currentScope = stream
            selectionCaptureTime = request.key.captureTime
            latestFrameID = request.key.frameID
            reference = nil
            semanticLabel = nil
            semanticStatus = nil
            semanticPending = nil
            candidateID = nil
            authorizedCandidateID = nil
            comparisonPending = nil
            comparedCandidateID = nil
            if let pending { finish(pending, .failure(ObservationError.obsolete)); self.pending = nil }
        } else {
            latestFrameID = request.key.frameID
        }

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
        guard request.key.captureTime.isFinite, !request.jpeg.isEmpty,
              request.jpeg.count <= 4 * 1024 * 1024 else { throw ObservationError.invalidJPEG }
        if let rect = request.seedRect {
            guard rect.count == 4, rect.allSatisfy(\.isFinite), rect.allSatisfy({ $0 >= 0 && $0 <= 1 }),
                  rect[2] > 0, rect[3] > 0, rect[0] + rect[2] <= 1, rect[1] + rect[3] <= 1 else {
                throw ObservationError.invalidRectangle
            }
        }
        if request.isReference && request.seedRect == nil { throw ObservationError.invalidRectangle }
        if validateImageMetadata { try validateJPEGMetadata(request.jpeg) }
    }

    private func validateJPEGMetadata(_ data: Data) throws {
        guard data.starts(with: [0xFF, 0xD8]),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source), UTType(type as String) == .jpeg,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, max(width, height) <= 1_920,
              width.multipliedReportingOverflow(by: height).overflow == false,
              width * height <= 1_920 * 1_920 else { throw ObservationError.invalidJPEG }
    }

    private func launch(_ submission: Submission) {
        let localizer = self.localizer
        let immutableReference = reference
        guard submission.request.isReference || immutableReference != nil else {
            processingFinished(submission, .success(LocalizationResult(
                rect: nil, confidence: 0, candidateID: nil, status: .notFound
            )))
            return
        }
        let authorization = authorizedCandidateID
        Task.detached(priority: .userInitiated) {
            let result = Result { try localizer(submission.request, immutableReference, authorization) }
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
            semanticStatus = "labeling"
            semanticPending = submission.request
            launchSemanticIfIdle()
        }
        if case .success(let localization) = result {
            if localization.status == .candidate, let id = localization.candidateID,
               localization.confidence >= 0.6, let rect = localization.rect {
                if candidateID != id {
                    candidateID = id
                    authorizedCandidateID = nil
                    comparedCandidateID = nil
                }
                if comparedCandidateID != id {
                    comparisonPending = FrameRequest(key: submission.request.key, jpeg: submission.request.jpeg, seedRect: rect)
                }
            } else {
                candidateID = nil
                authorizedCandidateID = nil
                comparisonPending = nil
                comparedCandidateID = nil
            }
        } else {
            candidateID = nil
            authorizedCandidateID = nil
            comparisonPending = nil
            comparedCandidateID = nil
        }
        launchSemanticIfIdle()
        finish(submission, result.map { result in
            DetectionReply(key: submission.request.key, rect: result.rect, confidence: result.confidence,
                           candidateID: result.candidateID, status: result.status,
                           semanticLabel: semanticLabel, semanticStatus: semanticStatus)
        })
        if active === submission {
            active = pending; pending = nil
            if let active { launch(active) }
        }
    }

    private func launchSemanticIfIdle() {
        guard !semanticActive else { return }
        if let request = semanticPending {
            semanticActive = true
            semanticPending = nil
            let scopeGeneration = generation
            let provider = semanticProvider
            Task.detached(priority: .utility) {
                let result: Result<String, Error>
                do { result = .success(try await provider(request)) }
                catch { result = .failure(error) }
                await self.semanticFinished(result, generation: scopeGeneration)
            }
            return
        }
        guard let candidate = comparisonPending, let reference, let id = candidateID,
              comparedCandidateID != id, now() - lastComparisonTime >= 5 else { return }
        comparisonPending = nil
        comparedCandidateID = id
        lastComparisonTime = now()
        semanticActive = true
        let scopeGeneration = generation
        let comparator = comparator
        Task.detached(priority: .utility) {
            let result: Result<AstraLabeler.Comparison, Error>
            do { result = .success(try await comparator(reference, candidate)) }
            catch { result = .failure(error) }
            await self.comparisonFinished(result, generation: scopeGeneration, candidateID: id)
        }
    }

    private func comparisonFinished(_ result: Result<AstraLabeler.Comparison, Error>, generation: UInt64, candidateID: String) {
        semanticActive = false
        #if DEBUG
        if generation == self.generation, self.candidateID == candidateID {
            switch result {
            case .success(let decision): print("Astra comparison candidate=\(candidateID) verdict=\(decision.verdict.rawValue) confidence=\(decision.confidence)")
            case .failure: print("Astra comparison candidate=\(candidateID) unavailable")
            }
        } else { print("Astra comparison discarded: stale scope or candidate") }
        #endif
        if generation == self.generation, self.candidateID == candidateID,
           case .success(let decision) = result, decision.authorizes {
            authorizedCandidateID = candidateID
        }
        launchSemanticIfIdle()
    }

    private func semanticFinished(_ result: Result<String, Error>, generation: UInt64) {
        semanticActive = false
        if generation == self.generation {
            switch result {
            case .success(let label):
                semanticLabel = label; semanticStatus = "ready"
                #if DEBUG
                print("Astra reference label ready generation=\(generation)")
                #endif
            case .failure:
                semanticLabel = nil; semanticStatus = "unavailable"
                #if DEBUG
                print("Astra reference label unavailable generation=\(generation)")
                #endif
            }
        }
        launchSemanticIfIdle()
    }

    private func scheduleTimeout(_ submission: Submission) {
        let delay = timeoutNanoseconds
        let id = submission.id
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            await self?.timeOut(id: id)
        }
    }

    private func timeOut(id: UUID) {
        if let pending, pending.id == id {
            self.pending = nil
            finish(pending, .failure(ObservationError.timedOut))
        } else if let active, active.id == id {
            finish(active, .failure(ObservationError.timedOut))
        }
    }

    private func finish(_ submission: Submission, _ result: Result<DetectionReply, Error>) {
        guard !submission.completed else { return }
        submission.completed = true
        let continuation = submission.continuation
        submission.continuation = nil
        continuation?.resume(with: result)
    }

    func pendingFrameIDForTesting() -> UInt64? { pending?.request.key.frameID }
}

final class VisionLocalizer: @unchecked Sendable {
    private var referencePrint: VNFeaturePrintObservation?
    private var trackedObservation: VNDetectedObjectObservation?
    private var lastTrackingInputID: ObjectIdentifier?
    private var sequence = VNSequenceRequestHandler()
    private var candidateObservation: VNDetectedObjectObservation?
    private var candidateSequence = VNSequenceRequestHandler()
    private var candidateID: String?
    private var candidateTime: Double?


    func localize(_ request: FrameRequest, _ reference: FrameRequest?, authorizedCandidateID: String? = nil) throws -> LocalizationResult {
        do { return try localizeFrame(request, reference, authorizedCandidateID: authorizedCandidateID) }
        catch { clearCandidate(); throw error }
    }

    private func localizeFrame(_ request: FrameRequest, _ reference: FrameRequest?, authorizedCandidateID: String?) throws -> LocalizationResult {
        if reference == nil, request.isReference { reset() }
        guard let image = CIImage(data: request.jpeg) else { throw ObservationError.invalidJPEG }
        let handler = VNImageRequestHandler(ciImage: image, orientation: .up)

        if reference == nil, request.isReference, let seed = request.seedRect {
            let visionRect = CGRect(x: seed[0], y: 1 - seed[1] - seed[3], width: seed[2], height: seed[3])
            let newPrint = try featurePrint(image.cropped(to: pixelRect(visionRect, image.extent)))
            let initialize = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: visionRect))
            initialize.trackingLevel = .accurate
            try sequence.perform([initialize], on: image, orientation: .up)
            guard let initialized = initialize.results?.first as? VNDetectedObjectObservation else {
                throw ObservationError.invalidJPEG
            }
            referencePrint = newPrint
            trackedObservation = initialized
            return LocalizationResult(rect: seed, confidence: 1, candidateID: nil, status: .identityConfirmed)
        }

        if let trackedObservation {
            lastTrackingInputID = ObjectIdentifier(trackedObservation)
            let tracking = VNTrackObjectRequest(detectedObjectObservation: trackedObservation)
            tracking.trackingLevel = .accurate
            try sequence.perform([tracking], on: image, orientation: .up)
            if let result = tracking.results?.first as? VNDetectedObjectObservation, !tracking.isLastFrame,
               result.confidence >= 0.35 {
                let rect = result.boundingBox
                self.trackedObservation = result
                return LocalizationResult(rect: [rect.minX, 1 - rect.maxY, rect.width, rect.height],
                                          confidence: Double(result.confidence), candidateID: nil,
                                          status: .tracked)
            }
            self.trackedObservation = nil
        }

        if let candidateObservation, let id = candidateID, let candidateTime {
            if request.key.captureTime > candidateTime, request.key.captureTime - candidateTime <= 1 {
                let tracking = VNTrackObjectRequest(detectedObjectObservation: candidateObservation)
                tracking.trackingLevel = .accurate
                do {
                    try candidateSequence.perform([tracking], on: image, orientation: .up)
                    if let current = tracking.results?.first as? VNDetectedObjectObservation,
                       !tracking.isLastFrame, current.confidence >= 0.6 {
                        self.candidateObservation = current
                        self.candidateTime = request.key.captureTime
                        let rect = current.boundingBox
                        let promoted = authorizedCandidateID == id
                        if promoted {
                            trackedObservation = current
                            sequence = candidateSequence
                            clearCandidate()
                        }
                        return LocalizationResult(rect: [rect.minX, 1 - rect.maxY, rect.width, rect.height],
                            confidence: Double(current.confidence), candidateID: promoted ? nil : id,
                            status: promoted ? .tracked : .candidate)
                    }
                } catch { /* A failed advance retires continuity before proposing anew. */ }
            }
            clearCandidate()
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
        if let (candidate, _) = best {
            return try initializeCandidate(image: image, rect: candidate.boundingBox, time: request.key.captureTime)
        }
        clearCandidate()
        return LocalizationResult(rect: nil, confidence: 0, candidateID: nil, status: .notFound)
    }

    private func initializeCandidate(image: CIImage, rect: CGRect, time: Double) throws -> LocalizationResult {
        clearCandidate()
        let initialize = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: rect))
        initialize.trackingLevel = .accurate
        try candidateSequence.perform([initialize], on: image, orientation: .up)
        guard let initialized = initialize.results?.first as? VNDetectedObjectObservation, initialized.confidence >= 0.6 else {
            return LocalizationResult(rect: nil, confidence: 0, candidateID: nil, status: .notFound)
        }
        let id = UUID().uuidString
        candidateID = id
        candidateObservation = initialized
        candidateTime = time
        let bounds = initialized.boundingBox
        return LocalizationResult(rect: [bounds.minX, 1 - bounds.maxY, bounds.width, bounds.height],
            confidence: Double(initialized.confidence), candidateID: id, status: .candidate)
    }

    // Inject a deterministic proposal while exercising the production Vision candidate sequence.
    func initializeCandidateForTesting(_ request: FrameRequest, rect: CGRect) throws -> LocalizationResult {
        guard let image = CIImage(data: request.jpeg) else { throw ObservationError.invalidJPEG }
        trackedObservation = nil
        return try initializeCandidate(image: image, rect: rect, time: request.key.captureTime)
    }

    private func clearCandidate() {
        candidateID = nil
        candidateObservation = nil
        candidateTime = nil
        candidateSequence = VNSequenceRequestHandler()
    }

    private func reset() {
        clearCandidate()
        referencePrint = nil
        trackedObservation = nil
        sequence = VNSequenceRequestHandler()
        lastTrackingInputID = nil
    }

    func trackedObservationIDForTesting() -> ObjectIdentifier? {
        trackedObservation.map(ObjectIdentifier.init)
    }

    func lastTrackingInputIDForTesting() -> ObjectIdentifier? { lastTrackingInputID }

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
