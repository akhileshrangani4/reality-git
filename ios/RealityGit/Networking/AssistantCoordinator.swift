import Combine
import CoreImage
import Foundation
import ImageIO
import RealityGitCore
import QuartzCore

@MainActor
final class AssistantCoordinator: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var isThinking = false
    @Published private(set) var message = "Connect Astra to begin"
    @Published private(set) var semanticMessage: String?
    @Published private(set) var label: String?
    private var client: AssistantClient?
    private var sessionID = UUID()
    private var objectID = UUID()
    private var frameID: UInt64 = 0
    private var referenceInitialized = false
    private var selection: (sample: FrameSample, rect: [Double]?, point: [Double]?)?
    private var lastSampleTime: Double = -.infinity
    private var lastAcceptedTime: Double = -.infinity
    private(set) var evidence: (DetectionReply, FrameSample)?
    private struct Job: Sendable {
        let key: ObservationKey
        let source: FrameSample
        let client: AssistantClient
        let reference: Bool
        let rect: [Double]?
        let point: [Double]?
    }
    private lazy var worker = LatestAsyncWorker<Job, DetectionReply>(operation: { job in
        let jpeg = try await Task.detached(priority: .userInitiated) {
            try Self.encode(job.source, longEdge: 960)
        }.value
        try Task.checkCancellation()
        return try await job.client.submit(FrameRequest(key: job.key, jpeg: jpeg,
            seedRect: job.rect, isReference: job.reference, seedPoint: job.point))
    }, completion: { [weak self] job, result in self?.complete(job, result: result) })

    func recoveryEvidence() -> MacTrackingRecovery? {
        guard connected, let evidence else { return nil }
        return MacTrackingRecovery(reply: evidence.0, source: evidence.1, sessionID: sessionID, objectID: objectID)
    }

    @discardableResult
    func connect(address: String) -> Bool {
        guard let endpoint = AssistantPolicy.localEndpoint(address) else {
            message = "Enter your server's local address"
            return false
        }
        resetSelection()
        client = AssistantClient(endpoint: endpoint)
        connected = true
        message = "Tap an object to remember it"
        return true
    }

    func disconnect() {
        resetSelection(); client = nil; connected = false
        message = "Connect Astra to begin"
    }

    func resetSelection() {
        worker.invalidate()
        objectID = UUID(); selection = nil; referenceInitialized = false
        evidence = nil; label = nil; semanticMessage = nil; isThinking = false
        lastSampleTime = -.infinity; lastAcceptedTime = -.infinity
        message = connected ? "Tap an object to remember it" : "Connect Astra to begin"
    }

    func select(_ sample: FrameSample, selection: ObjectSelection, preserveReference: Bool) {
        if !preserveReference { resetSelection() }
        guard connected else { return }
        if !referenceInitialized {
            switch selection {
            case .point(let point): self.selection = (sample, nil, [point.x, point.y])
            case .rectangle(let rect): self.selection = (sample, [rect.minX, rect.minY, rect.width, rect.height], nil)
            }
        }
        lastSampleTime = -.infinity
        offer(sample)
    }

    func tick(now: Double) {
        if let evidence, now - evidence.0.key.captureTime > AstraGeometry.sourceLifetime { self.evidence = nil }
    }

    func wantsSample(at time: Double) -> Bool {
        connected && !isThinking && selection != nil && time - lastSampleTime >= 0.5
    }

    func offer(_ sample: FrameSample) {
        guard wantsSample(at: sample.timestamp), let client, let selection else { return }
        let source = referenceInitialized ? sample : selection.sample
        guard sample.timestamp - source.timestamp <= AstraGeometry.sourceLifetime else {
            message = "Tap the object to try again"
            return
        }
        lastSampleTime = sample.timestamp
        frameID &+= 1
        isThinking = true
        if !referenceInitialized { message = "Astra is remembering your object…" }
        let key = ObservationKey(sessionID: sessionID, objectID: objectID, frameID: frameID, captureTime: source.timestamp)
        // The active job owns its exact RGB/depth source until completion; newer frames cannot evict it.
        worker.submit(Job(key: key, source: source, client: client, reference: !referenceInitialized,
            rect: referenceInitialized ? nil : selection.rect, point: referenceInitialized ? nil : selection.point))
    }

    private func complete(_ job: Job, result: Result<DetectionReply, any Error>) {
        isThinking = false
        switch result {
        case .success(let reply):
            guard AssistantPolicy.validReply(reply, sent: job.key, now: CACurrentMediaTime(),
                lastAcceptedTime: lastAcceptedTime, sourceExists: true, maxAge: AstraGeometry.sourceLifetime) else {
                message = "Astra is catching up…"
                return
            }
            if let rect = reply.rect {
                guard let outline = reply.outline, AstraGeometry.validOutline(outline, rect: rect) else {
                    message = "Astra is checking the outline…"
                    return
                }
            }
            if reply.status == .identityConfirmed || reply.status == .tracked {
                lastAcceptedTime = job.key.captureTime
                referenceInitialized = true
                label = reply.semanticLabel
                semanticMessage = label
                message = "Following your object"
            } else { message = referenceInitialized ? "Astra is finding your object…" : "Keep the object in view" }
            evidence = (reply, job.source)
            #if DEBUG
            print("Astra observation frame=\(job.key.frameID) status=\(reply.status) age=\(CACurrentMediaTime() - job.key.captureTime)s")
            #endif
        case .failure:
            message = "Can't reach Astra · check connection"
        }
    }

    nonisolated private static func encode(_ sample: FrameSample, longEdge: Int) throws -> Data {
        let image = CIImage(cvPixelBuffer: sample.image)
        let scale = min(1, CGFloat(longEdge) / max(image.extent.width, image.extent.height))
        let resized = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let cgImage = context.createCGImage(resized, from: resized.extent) else { throw AssistantClient.ClientError.invalidResponse }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { throw AssistantClient.ClientError.invalidResponse }
        CGImageDestinationAddImage(destination, cgImage, [kCGImagePropertyOrientation: 1,
            kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AssistantClient.ClientError.invalidResponse }
        return data as Data
    }
}
