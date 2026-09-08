import Combine
import CoreImage
import Foundation
import ImageIO
import RealityGitCore
import QuartzCore

@MainActor
final class AssistantCoordinator: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var message = "Mac assistance off"
    var samplesPerSecond: Double = 2
    var longEdge: Int = 640
    private var client: AssistantClient?
    private var sessionID = UUID()
    private var objectID = UUID()
    private var frameID: UInt64 = 0
    private var connection = AssistantConnectionState()
    private var frames = FrameBuffer()
    private struct Job: Sendable {
        let key: ObservationKey
        let source: AssistantSample
        let client: AssistantClient
        let reference: Bool
        let edge: Int
    }
    private lazy var worker = LatestAsyncWorker<Job, DetectionReply>(operation: { job in
        let jpeg: Data
        do {
            jpeg = try await Task.detached(priority: .utility) {
                try Self.encode(job.source.frame, longEdge: job.edge)
            }.value
        } catch {
            Self.logFailure(error, stage: "encode")
            throw error
        }
        try Task.checkCancellation()
        guard CACurrentMediaTime() - job.key.captureTime <= 5 else {
            Self.logFailure(CancellationError(), stage: "source expired before network")
            throw CancellationError()
        }
        do {
            return try await job.client.submit(FrameRequest(key: job.key, jpeg: jpeg,
                seedRect: job.reference ? job.source.seed : nil, isReference: job.reference))
        } catch {
            Self.logFailure(error, stage: "network")
            throw error
        }
    }, completion: { [weak self] job, result in self?.complete(job, result: result) })
    private var lastSampleTime: Double = -.infinity
    private var lastAcceptedTime: Double = -.infinity

    // Evidence stays attached to exact source geometry; never updates local position/identity.
    private(set) var evidence: (DetectionReply, FrameSample)?

    func recoveryEvidence() -> MacTrackingRecovery? {
        guard connected, !connection.requiresReselection, connection.referenceInitialized,
              let evidence, evidence.0.key.sessionID == sessionID,
              evidence.0.key.objectID == objectID else { return nil }
        return MacTrackingRecovery(reply: evidence.0, source: evidence.1, sessionID: sessionID, objectID: objectID)
    }

    @discardableResult
    func connect(address: String) -> Bool {
        guard let endpoint = AssistantPolicy.localEndpoint(address) else {
            message = "Use http://your-mac.local:8080 or a private IPv4 address."
            return false
        }
        cancelPending()
        connection.connect(to: endpoint)
        client = AssistantClient(endpoint: endpoint)
        connected = true
        message = connection.requiresReselection ? "Mac changed · select your object again" : "Mac enabled · waiting for a selected frame"
        return true
    }
    func disconnect() {
        cancelPending()
        client = nil
        connected = false
        message = "Mac assistance off · local tracking continues"
    }
    func resetSelection() {
        cancelPending()
        objectID = UUID()
        connection.selectNewObject()
        lastSampleTime = -.infinity
        lastAcceptedTime = -.infinity
        if connected { message = "Mac connected · select an object" }
    }
    private func cancelPending() {
        worker.invalidate()
        frames.reset(); evidence = nil
    }
    func tick(now: Double) {
        frames.prune(now: now)
        if let evidence, now - evidence.0.key.captureTime > 5 { self.evidence = nil }
    }
    func wantsSample(at time: Double) -> Bool {
        connected && !connection.requiresReselection && connection.referenceInitialized && time - lastSampleTime >= 1 / max(0.1, samplesPerSecond)
    }
    func offer(_ sample: FrameSample, rect: CGRect?) {
        guard connected, !connection.requiresReselection, connection.referenceInitialized || rect != nil,
              sample.timestamp - lastSampleTime >= 1 / max(0.1, samplesPerSecond) else { return }
        lastSampleTime = sample.timestamp
        frameID &+= 1
        let key = ObservationKey(sessionID: sessionID, objectID: objectID, frameID: frameID, captureTime: sample.timestamp)
        frames.insert(AssistantSample(frame: sample, seed: rect.map { [$0.minX, $0.minY, $0.width, $0.height] }), for: key, now: CACurrentMediaTime())
        guard let client, let source = frames.value(for: key, now: CACurrentMediaTime()) else { return }
        worker.submit(Job(key: key, source: source, client: client,
            reference: !connection.referenceInitialized, edge: max(64, min(1920, longEdge))))
    }
    private func complete(_ job: Job, result: Result<DetectionReply, any Error>) {
        switch result {
        case .success(let reply):
            let now = CACurrentMediaTime()
            let source = frames.value(for: job.key, now: now)
            guard AssistantPolicy.validReply(reply, sent: job.key, now: now,
                lastAcceptedTime: lastAcceptedTime, sourceExists: source != nil), let source else {
                message = "Mac reply discarded · stale or mismatched frame"
                return
            }
            lastAcceptedTime = job.key.captureTime
            if job.reference && (reply.status == .identityConfirmed || reply.status == .tracked) {
                connection.acknowledgeReference()
            }
            evidence = (reply, source.frame)
            switch reply.status {
            case .tracked: message = "Mac tracking active"
            case .candidate: message = "Mac candidate · identity unconfirmed"
            case .identityConfirmed: message = "Mac reference initialized"
            case .notFound: message = "Mac uncertain · local tracking continues"
            }
            #if DEBUG
            print("Mac reply frame=\(job.key.frameID) status=\(reply.status)")
            #endif
        case .failure:
            message = "Mac unavailable · local tracking continues"
        }
    }
    nonisolated private static func logFailure(_ error: any Error, stage: String) {
        #if DEBUG
        let failure = error as NSError
        // Do not log descriptions/userInfo: they may include URLs or payloads.
        print("Mac failure stage=\(stage) domain=\(failure.domain) code=\(failure.code)")
        #endif
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
            kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AssistantClient.ClientError.invalidResponse }
        return data as Data
    }
}
