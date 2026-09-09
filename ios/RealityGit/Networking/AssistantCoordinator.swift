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
    @Published private(set) var message = "Sign in to start scanning"
    @Published private(set) var connectionMessage: String?
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
    private var loginTask: Task<Void, Never>?
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
            try job.source.jpeg()
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
        guard client == nil else { return }
        client = AssistantClient()
        await refreshAccount()
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
            signedIn = (try? await client.auth.hasCredentials()) ?? false
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
        if client == nil { client = AssistantClient() }
        guard let client, !isConnecting else { return }
        isConnecting = true; connectionMessage = nil
        let revision = connectionRevision
        defer { if revision == connectionRevision { isConnecting = false } }
        do {
            let value = try await client.login()
            guard revision == connectionRevision else { return }
            login = value
            loginTask?.cancel()
            loginTask = Task { [weak self] in
                let deadline = Date().addingTimeInterval(900)
                while !Task.isCancelled, let self, self.login?.loginID == value.loginID {
                    do {
                        if Date() >= deadline { throw NativeCodexError.loginExpired }
                        if try await client.pollLogin() {
                            guard self.connectionRevision == revision else { return }
                            self.login = nil
                            await self.refreshAccount()
                            return
                        }
                    } catch {
                        guard !Task.isCancelled, self.connectionRevision == revision else { return }
                        self.connectionMessage = self.connectionError(error)
                        if let failure = error as? NativeCodexError, failure != .unavailable && failure != .limited {
                            await client.cancelLogin()
                            self.login = nil
                            return
                        }
                    }
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                }
            }
        } catch {
            if revision == connectionRevision { connectionMessage = connectionError(error) }
        }
    }

    func cancelLogin() async {
        loginTask?.cancel(); loginTask = nil
        login = nil; connectionMessage = nil
        await client?.cancelLogin()
    }

    @discardableResult
    func disconnect() async -> Bool {
        connectionRevision = UUID()
        loginTask?.cancel(); loginTask = nil
        connected = false; signedIn = false; models = []; modelID = nil
        login = nil; isConnecting = false; connectionMessage = nil
        resetSelection()
        do { try await client?.signOut(); return true }
        catch { connectionMessage = "Unlock your iPhone and try signing out again."; return false }
    }

    private func connectionError(_ error: Error) -> String {
        switch error as? AssistantClient.ClientError {
        case .signedOut: return "Sign in with ChatGPT to continue."
        case .accessDenied: return "OpenAI didn't authorize this connection. Check that Codex is enabled for your account."
        case .modelUnavailable: return "Refresh models and choose an available one."
        case .limited: return "Your Codex allowance is currently unavailable. Try again later."
        case .loginUnavailable: return "Device sign-in isn't available for this account. Check your ChatGPT security settings."
        case .loginExpired: return "Your sign-in code expired. Try again."
        case .storage: return "Unlock your iPhone to access your sign-in."
        case .invalidResponse: return "Codex returned an incomplete response. Try again."
        default: return "Can't reach OpenAI. Check your internet connection and try again."
        }
    }

    func resetSelection() {
        worker.invalidate()
        objectID = UUID(); selection = nil; referenceInitialized = false
        evidence = nil; label = nil; semanticMessage = nil; isThinking = false
        lastSampleTime = -.infinity; lastAcceptedTime = -.infinity
        retryAfter = -.infinity; consecutiveFailures = 0
        message = connected ? "Tap an object to remember it" : "Sign in to start scanning"
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
            case .signedOut, .accessDenied, .modelUnavailable:
                connected = false; message = "Reconnect in Settings"
                if case .signedOut = error as? AssistantClient.ClientError { signedIn = false }
            case .limited: retryAfter = CACurrentMediaTime() + 30; message = "Codex is busy · retrying shortly"
            default: break
            }
        }
    }

}
