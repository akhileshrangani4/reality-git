import Foundation
import ImageIO
import RealityGitCore
import UniformTypeIdentifiers

/// A bounded Astra request at a time. No Apple proposal or comparison backoff gates perception.
actor AstraWorker {
    private let provider: AstraObserver.Provider
    private let validateImages: Bool
    private var reference: FrameRequest?
    private var scope: (session: UUID, object: UUID)?
    private var selectionTime: Double = -.infinity
    private var lastFrame: UInt64?
    private var generation: UInt64 = 0
    private var active: (id: UUID, task: Task<AstraObserver.Observation, Error>)?

    init(validateImages: Bool = true, provider: @escaping AstraObserver.Provider = AstraObserver.observe) {
        self.validateImages = validateImages; self.provider = provider
    }

    func observe(_ request: FrameRequest) async throws -> DetectionReply {
        try validate(request)
        let sameScope = scope?.session == request.key.sessionID && scope?.object == request.key.objectID
        if !sameScope {
            guard request.isReference, request.key.captureTime > selectionTime else { throw ObservationError.obsolete }
            generation &+= 1
            scope = (request.key.sessionID, request.key.objectID)
            selectionTime = request.key.captureTime
            reference = nil; lastFrame = nil
            active?.task.cancel()
        }
        // Cancellation does not release the physical slot until the provider returns.
        guard active == nil else { throw ObservationError.obsolete }
        guard lastFrame.map({ request.key.frameID > $0 }) ?? true else { throw ObservationError.obsolete }
        guard request.isReference || reference != nil else { throw ObservationError.obsolete }
        lastFrame = request.key.frameID
        let capturedGeneration = generation, id = UUID()
        let reference = self.reference, provider = self.provider
        let task = Task { try await provider(request, reference) }
        active = (id, task)
        defer { if active?.id == id { active = nil } }
        let observation = try await task.value
        guard capturedGeneration == generation else { throw ObservationError.obsolete }
        guard observation.confidence.isFinite, (0...1).contains(observation.confidence),
              observation.rect.map({ AstraGeometry.validOutline(observation.outline, rect: $0) }) ?? observation.outline.isEmpty else {
            throw AstraLabeler.Failure.invalidResponse
        }
        let isFirst = self.reference == nil
        if isFirst, observation.found {
            self.reference = FrameRequest(key: request.key, jpeg: request.jpeg,
                seedRect: observation.rect, isReference: true)
        }
        return DetectionReply(key: request.key, rect: observation.found ? observation.rect : nil,
            confidence: observation.confidence, candidateID: nil,
            status: observation.found ? (isFirst ? .identityConfirmed : .tracked) : .notFound,
            semanticLabel: observation.label, semanticStatus: "ready",
            outline: observation.found ? observation.outline : nil)
    }

    private func validate(_ request: FrameRequest) throws {
        guard request.key.captureTime.isFinite, !request.jpeg.isEmpty, request.jpeg.count <= 4 * 1024 * 1024 else {
            throw ObservationError.invalidJPEG
        }
        if let rect = request.seedRect, AstraGeometry.rectangle(rect) == nil { throw ObservationError.invalidRectangle }
        if let point = request.seedPoint,
           point.count != 2 || !point.allSatisfy({ $0.isFinite && (0...1).contains($0) }) { throw ObservationError.invalidRectangle }
        if request.isReference, request.seedRect == nil && request.seedPoint == nil { throw ObservationError.invalidRectangle }
        if validateImages {
            guard request.jpeg.starts(with: [0xff, 0xd8]),
                  let source = CGImageSourceCreateWithData(request.jpeg as CFData, nil), CGImageSourceGetCount(source) == 1,
                  let type = CGImageSourceGetType(source), UTType(type as String) == .jpeg,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = properties[kCGImagePropertyPixelWidth] as? Int,
                  let h = properties[kCGImagePropertyPixelHeight] as? Int,
                  w > 0, h > 0, w <= 1920, h <= 1920 else { throw ObservationError.invalidJPEG }
        }
    }
}
