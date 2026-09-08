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
    private var queue = LatestObservationQueue()
    private var frames = FrameBuffer()
    private var task: Task<Void, Never>?
    private var lastSampleTime: Double = -.infinity
    private var lastAcceptedTime: Double = -.infinity
    private var referenceInitialized = false
    // Evidence stays attached to exact source geometry; never updates local position/identity.
    private(set) var evidence: (DetectionReply, FrameSample)?

    @discardableResult
    func connect(address: String) -> Bool {
        guard let endpoint = AssistantPolicy.localEndpoint(address) else {
            message = "Use http://your-mac.local:8080 or a private IPv4 address."
            return false
        }
        cancelPending()
        client = AssistantClient(endpoint: endpoint)
        connected = true
        message = "Mac enabled · waiting for a selected frame"
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
        referenceInitialized = false
        lastSampleTime = -.infinity
        lastAcceptedTime = -.infinity
        if connected { message = "Mac connected · select an object" }
    }
    private func cancelPending() {
        task?.cancel(); task = nil
        queue.reset(); frames.reset(); evidence = nil
    }
    func tick(now: Double) {
        frames.prune(now: now)
        if let evidence, now - evidence.0.key.captureTime > 5 { self.evidence = nil }
    }
    func wantsSample(at time: Double) -> Bool {
        connected && referenceInitialized && time - lastSampleTime >= 1 / max(0.1, samplesPerSecond)
    }
    func offer(_ sample: FrameSample, rect: CGRect?) {
        guard connected, referenceInitialized || rect != nil,
              sample.timestamp - lastSampleTime >= 1 / max(0.1, samplesPerSecond) else { return }
        lastSampleTime = sample.timestamp
        frameID &+= 1
        let key = ObservationKey(sessionID: sessionID, objectID: objectID, frameID: frameID, captureTime: sample.timestamp)
        frames.insert(AssistantSample(frame: sample, seed: rect.map { [$0.minX, $0.minY, $0.width, $0.height] }), for: key, now: CACurrentMediaTime())
        if let next = queue.offer(key) { launch(next) }
    }
    private func launch(_ key: ObservationKey) {
        guard let client, let source = frames.value(for: key, now: CACurrentMediaTime()) else {
            if let next = queue.finish(key) { launch(next) }
            return
        }
        let reference = !referenceInitialized
        let edge = max(64, min(1920, longEdge))
        task = Task {
            do {
                let jpeg = try await Task.detached(priority: .utility) {
                    try Self.encode(source.frame, longEdge: edge)
                }.value
                try Task.checkCancellation()
                guard CACurrentMediaTime() - key.captureTime <= 5 else { throw CancellationError() }
                let reply = try await client.submit(FrameRequest(key: key, jpeg: jpeg,
                    seedRect: reference ? source.seed : nil, isReference: reference))
                try Task.checkCancellation()
                guard queue.inFlight == key else { return }
                let currentSource = frames.value(for: key, now: CACurrentMediaTime())
                if AssistantPolicy.validReply(reply, sent: key, now: CACurrentMediaTime(),
                    lastAcceptedTime: lastAcceptedTime, sourceExists: currentSource != nil), let currentSource {
                    lastAcceptedTime = key.captureTime
                    if reference && (reply.status == .identityConfirmed || reply.status == .tracked) { referenceInitialized = true }
                    evidence = (reply, currentSource.frame)
                    switch reply.status {
                    case .tracked: message = "Mac tracked · source frame \(key.frameID)"
                    case .candidate: message = "Mac candidate · identity unconfirmed"
                    case .identityConfirmed: message = "Mac reference initialized"
                    case .notFound: message = "Mac uncertain · local tracking continues"
                    }
                } else { message = "Mac reply discarded · stale or mismatched frame" }
            } catch {
                guard queue.inFlight == key else { return }
                message = "Mac unavailable · local tracking continues"
            }
            guard queue.inFlight == key else { return }
            task = nil
            if let next = queue.finish(key) { launch(next) }
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
            kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AssistantClient.ClientError.invalidResponse }
        return data as Data
    }
}
