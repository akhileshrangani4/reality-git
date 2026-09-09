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
    @Published private(set) var message = "Connect to start scanning"
    @Published private(set) var connectionMessage: String?
    @Published private(set) var connectionHost: String?
    @Published private(set) var signedIn = false
    @Published private(set) var isConnecting = false
    @Published private(set) var models: [ScanModel] = []
    @Published private(set) var modelID: String?
    @Published private(set) var login: CodexLogin?
    var modelName: String { models.first { $0.id == modelID }?.name ?? "Codex" }
    @Published private(set) var semanticMessage: String?
    @Published private(set) var label: String?
    private var client: AssistantClient?
    private var connectionRevision = UUID()
    private var retryAfter: Double = -.infinity
    private var consecutiveFailures = 0
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
        let modelID: String
    }
    private lazy var worker = LatestAsyncWorker<Job, DetectionReply>(operation: Self.perform,
        completion: { [weak self] job, result in self?.complete(job, result: result) })

    nonisolated private static func perform(_ job: Job) async throws -> DetectionReply {
        let jpeg = try await Task.detached(priority: .userInitiated) {
            try Self.encode(job.source, longEdge: 960)
        }.value
        try Task.checkCancellation()
        let request = FrameRequest(key: job.key, jpeg: jpeg,
            seedRect: job.rect, isReference: job.reference, seedPoint: job.point, modelID: job.modelID)
        return try await job.client.submit(request)
    }

    func recoveryEvidence() -> MacTrackingRecovery? {
        guard connected, let evidence else { return nil }
        return MacTrackingRecovery(reply: evidence.0, source: evidence.1, sessionID: sessionID, objectID: objectID)
    }

    func restoreConnection() async {
        guard client == nil, !isConnecting else { return }
        do {
            #if DEBUG
            try CompanionCredentials.importIfRequested()
            #endif
            guard let connection = try CompanionCredentials.load() else { return }
            client = AssistantClient(connection: connection)
            connectionHost = connection.endpoint.host
            await refreshAccount()
        } catch { connectionMessage = "Unlock your iPhone to reconnect." }
    }

    @discardableResult
    func connect(link: String) async -> Bool {
        guard !isConnecting else { return false }
        guard let connection = CompanionConnection(link: link) else {
            connectionMessage = "Paste the connection link from Reality Git on your Mac."
            return false
        }
        isConnecting = true; connectionMessage = nil
        let revision = UUID(); connectionRevision = revision
        defer { if connectionRevision == revision { isConnecting = false } }
        let candidate = AssistantClient(connection: connection)
        do {
            let account = try await candidate.account()
            guard revision == connectionRevision else { return false }
            try CompanionCredentials.save(connection)
            client = candidate; connectionHost = connection.endpoint.host
            login = nil; resetSelection(); apply(account)
            return true
        } catch {
            guard revision == connectionRevision else { return false }
            connectionMessage = connectionError(error)
            return false
        }
    }

    func refreshAccount() async {
        guard let client, !isConnecting else { return }
        isConnecting = true
        let revision = connectionRevision
        defer { if revision == connectionRevision { isConnecting = false } }
        do {
            let account = try await client.account()
            guard revision == connectionRevision else { return }
            apply(account)
        } catch {
            guard revision == connectionRevision else { return }
            connected = false; connectionMessage = connectionError(error)
            message = "Reconnect in Settings"
        }
    }

    private func apply(_ account: CodexAccountStatus) {
        let wasConnected = connected
        signedIn = account.signedIn; models = account.models
        let previous = modelID
        let preferred = modelID ?? UserDefaults.standard.string(forKey: "scanModelID")
        modelID = models.first { $0.id == preferred }?.id
            ?? models.first { $0.id == "gpt-6-astra" }?.id ?? models.first?.id
        connected = signedIn && modelID != nil
        connectionMessage = signedIn && models.isEmpty ? "No image models with low effort are available on this account." : nil
        if signedIn { login = nil }
        if previous != modelID || (!wasConnected && connected) { resetSelection() }
        if !connected { message = signedIn ? "Choose an available model" : "Sign in to start scanning" }
        else if selection == nil { message = "Tap an object to remember it" }
    }

    func chooseModel(_ id: String) {
        guard id != modelID, models.contains(where: { $0.id == id }), signedIn else { return }
        modelID = id; UserDefaults.standard.set(id, forKey: "scanModelID")
        connected = true; resetSelection()
    }

    func beginLogin() async {
        guard let client, !isConnecting else { return }
        isConnecting = true; connectionMessage = nil
        let revision = connectionRevision
        defer { if revision == connectionRevision { isConnecting = false } }
        do {
            let value = try await client.login()
            guard revision == connectionRevision else { return }
            login = value
        } catch {
            if revision == connectionRevision { connectionMessage = connectionError(error) }
        }
    }

    func cancelLogin() async {
        guard let client, login != nil, !isConnecting else { return }
        isConnecting = true
        let revision = connectionRevision
        defer { if revision == connectionRevision { isConnecting = false } }
        do {
            try await client.cancelLogin()
            if revision == connectionRevision { login = nil; connectionMessage = nil }
        } catch { if revision == connectionRevision { connectionMessage = connectionError(error) } }
    }

    @discardableResult
    func disconnect() -> Bool {
        do { try CompanionCredentials.remove() }
        catch { connectionMessage = "Couldn't remove the connection. Try again."; return false }
        connectionRevision = UUID(); client = nil; connected = false; signedIn = false
        models = []; modelID = nil; connectionHost = nil; login = nil; isConnecting = false; connectionMessage = nil
        resetSelection()
        return true
    }

    private func connectionError(_ error: Error) -> String {
        switch error as? AssistantClient.ClientError {
        case .pairing: return "This connection link has expired. Scan the code on your Mac again."
        case .signedOut: return "Sign in to ChatGPT to continue."
        case .modelUnavailable: return "Refresh models and choose an available one."
        case .limited: return "Codex couldn't complete this scan. Check your usage in Codex and retry."
        case .loginUnavailable: return "Sign in to Codex on your Mac, then tap Reconnect."
        default: return "Can't reach Codex. Keep the companion running and both devices on the same Wi-Fi."
        }
    }

    func resetSelection() {
        worker.invalidate()
        objectID = UUID(); selection = nil; referenceInitialized = false
        evidence = nil; label = nil; semanticMessage = nil; isThinking = false
        lastSampleTime = -.infinity; lastAcceptedTime = -.infinity
        retryAfter = -.infinity; consecutiveFailures = 0
        message = connected ? "Tap an object to remember it" : "Connect to start scanning"
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
        connected && !isThinking && selection != nil && time >= retryAfter && time - lastSampleTime >= 0.5
    }

    func offer(_ sample: FrameSample) {
        guard wantsSample(at: sample.timestamp), let client, let selection, let modelID else { return }
        let source = referenceInitialized ? sample : selection.sample
        guard sample.timestamp - source.timestamp <= AstraGeometry.sourceLifetime else {
            message = "Tap the object to try again"
            return
        }
        lastSampleTime = sample.timestamp
        frameID &+= 1
        isThinking = true
        if !referenceInitialized { message = "Remembering your object…" }
        let key = ObservationKey(sessionID: sessionID, objectID: objectID, frameID: frameID, captureTime: source.timestamp)
        // The active job owns its exact RGB/depth source until completion; newer frames cannot evict it.
        worker.submit(Job(key: key, source: source, client: client, reference: !referenceInitialized,
            rect: referenceInitialized ? nil : selection.rect, point: referenceInitialized ? nil : selection.point, modelID: modelID))
    }

    private func complete(_ job: Job, result: Result<DetectionReply, any Error>) {
        isThinking = false
        switch result {
        case .success(let reply):
            consecutiveFailures = 0; retryAfter = -.infinity
            guard AssistantPolicy.validReply(reply, sent: job.key, now: CACurrentMediaTime(),
                lastAcceptedTime: lastAcceptedTime, sourceExists: true, maxAge: AstraGeometry.sourceLifetime) else {
                message = "Catching up…"
                return
            }
            if let rect = reply.rect {
                guard let outline = reply.outline, AstraGeometry.validOutline(outline, rect: rect) else {
                    message = "Checking the outline…"
                    return
                }
            }
            if reply.status == .identityConfirmed || reply.status == .tracked {
                lastAcceptedTime = job.key.captureTime
                referenceInitialized = true
                label = reply.semanticLabel
                semanticMessage = label
                message = "Following your object"
            } else { message = referenceInitialized ? "Finding your object…" : "Keep the object in view" }
            evidence = (reply, job.source)
            #if DEBUG
            print("Astra observation frame=\(job.key.frameID) status=\(reply.status) age=\(CACurrentMediaTime() - job.key.captureTime)s")
            #endif
        case .failure(let error):
            consecutiveFailures += 1
            retryAfter = CACurrentMediaTime() + min(16, pow(2, Double(min(consecutiveFailures, 4))))
            message = "Scan interrupted · retrying shortly"
            connectionMessage = connectionError(error)
            switch error as? AssistantClient.ClientError {
            case .pairing, .signedOut, .modelUnavailable:
                connected = false; message = "Reconnect in Settings"
                if case .signedOut = error as? AssistantClient.ClientError { signedIn = false }
            case .limited: retryAfter = CACurrentMediaTime() + 30; message = "Codex is busy · retrying shortly"
            default: break
            }
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
