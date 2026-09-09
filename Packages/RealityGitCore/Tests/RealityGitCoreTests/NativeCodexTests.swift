import Foundation
import XCTest
@testable import RealityGitCore

private final class MemoryCredentials: CodexCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var failsSave = false
    func load() throws -> Data? { lock.withLock { data } }
    func save(_ data: Data) throws {
        try lock.withLock { if failsSave { throw NativeCodexError.storage }; self.data = data }
    }
    func remove() throws { lock.withLock { data = nil } }
    func failWrites() { lock.withLock { failsSave = true } }
}
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 2_000_000_000)
    func now() -> Date { lock.withLock { time } }
    func advance(_ seconds: Double) { lock.withLock { time.addTimeInterval(seconds) } }
}
private actor Gate {
    private var hold: CheckedContinuation<Void, Never>?
    private var arrived: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { hold = $0; arrived?.resume(); arrived = nil } }
    func entered() async { if hold == nil { await withCheckedContinuation { arrived = $0 } } }
    func release() { hold?.resume(); hold = nil }
}
private actor ScanRecorder {
    var references: [FrameRequest?] = []
    func observe(_ frame: FrameRequest, _ reference: FrameRequest?) -> AstraPerception.Observation {
        references.append(reference)
        return AstraPerception.Observation(label: "box", confidence: 0.98, rect: [0.1, 0.2, 0.3, 0.4],
            outline: [[0.1, 0.2], [0.4, 0.2], [0.4, 0.6], [0.1, 0.6]])
    }
}
private actor FakeCodex: CodexTransport {
    let clock: TestClock
    var requests: [URLRequest] = []
    var pollPending = false
    var refreshStatus = 200
    var modelStatus = 200
    var refreshCount = 0
    var exchangeGate: Gate?
    var refreshGate: Gate?
    init(clock: TestClock) { self.clock = clock }
    func configure(pending: Bool = false, refreshStatus: Int = 200, modelStatus: Int = 200, exchangeGate: Gate? = nil, refreshGate: Gate? = nil) {
        self.pollPending = pending; self.refreshStatus = refreshStatus; self.modelStatus = modelStatus
        self.exchangeGate = exchangeGate; self.refreshGate = refreshGate
    }
    func send(_ request: URLRequest, limit: Int, eventStream: Bool) async throws -> CodexHTTPReply {
        requests.append(request)
        switch request.url!.path {
        case "/api/accounts/deviceauth/usercode":
            return reply(["device_auth_id": "device-test", "user_code": "TEST-CODE", "interval": "5"])
        case "/api/accounts/deviceauth/token":
            if pollPending { return reply([:], status: 404) }
            return reply(["authorization_code": "code+&=", "code_verifier": "verifier+&=", "code_challenge": "unused"])
        case "/oauth/token":
            if request.value(forHTTPHeaderField: "Content-Type") == "application/json" {
                refreshCount += 1
                if let refreshGate { await refreshGate.wait() }
                if refreshStatus != 200 { return reply(["error": "invalid_grant"], status: refreshStatus) }
            } else if let exchangeGate { await exchangeGate.wait() }
            return reply(["access_token": jwt(expires: clock.now().addingTimeInterval(3600)),
                          "refresh_token": "refresh-\(refreshCount)", "id_token": jwt(expires: clock.now().addingTimeInterval(3600))])
        case "/backend-api/codex/models":
            return CodexHTTPReply(status: modelStatus, data: Self.catalog)
        case "/backend-api/codex/responses":
            return reply(["status": "completed", "output": [["content": [["type": "output_text", "text": Self.object]]]]])
        default: throw NativeCodexError.invalidResponse
        }
    }
    private func jwt(expires: Date) -> String {
        let payload: [String: Any] = ["exp": expires.timeIntervalSince1970, "https://api.openai.com/auth": ["chatgpt_account_id": "test-account"]]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "test.\(encoded).test"
    }
    private func reply(_ body: [String: Any], status: Int = 200) -> CodexHTTPReply {
        CodexHTTPReply(status: status, data: try! JSONSerialization.data(withJSONObject: body))
    }
    static let object = #"{"label":"red box","confidence":0.98,"rect":[0.1,0.2,0.3,0.4],"outline":[[0.1,0.2],[0.4,0.2],[0.4,0.6],[0.1,0.6]]}"#
    static let catalog = Data(#"{"models":[{"slug":"gpt-6-astra","display_name":"GPT-6 Astra","visibility":"list","input_modalities":["text","image"],"supported_reasoning_levels":[{"effort":"low"}]},{"slug":"text-only","display_name":"Text","visibility":"list","input_modalities":["text"],"supported_reasoning_levels":[{"effort":"low"}]},{"slug":"missing-capabilities","display_name":"Unknown","visibility":"list","supported_reasoning_levels":[{"effort":"low"}]},{"slug":"hidden","display_name":"Hidden","visibility":"hide","input_modalities":["image"],"supported_reasoning_levels":[{"effort":"low"}]}]}"#.utf8)
}

final class NativeCodexTests: XCTestCase {
    @MainActor
    private func signedIn() async throws -> (NativeCodexClient, MemoryCredentials, FakeCodex, TestClock) {
        let clock = TestClock(), store = MemoryCredentials()
        let transport = FakeCodex(clock: clock)
        let client = NativeCodexClient(store: store, transport: transport, now: clock.now)
        _ = try await client.beginLogin()
        let completed = try await client.pollLogin()
        XCTAssertTrue(completed)
        return (client, store, transport, clock)
    }

    @MainActor
    func testDeviceLoginStoresOnlyOnSuccessAndRestoresOnAnotherClient() async throws {
        let (client, store, transport, clock) = try await signedIn()
        let account = try await client.account()
        XCTAssertTrue(account.signedIn)
        XCTAssertEqual(account.models.map(\.id), ["gpt-6-astra"])
        let restored = NativeCodexClient(store: store, transport: transport, now: clock.now)
        let restoredAccount = try await restored.account()
        XCTAssertTrue(restoredAccount.signedIn)
        let requests = await transport.requests
        XCTAssertTrue(requests.allSatisfy { $0.url?.scheme == "https" })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "originator") == "reality_git_ios" })
        let exchange = try XCTUnwrap(requests.first { $0.url?.path == "/oauth/token" })
        let body = String(data: exchange.httpBody!, encoding: .utf8)!
        XCTAssertTrue(body.contains("code=code%2B%26%3D"))
        XCTAssertTrue(body.contains("code_verifier=verifier%2B%26%3D"))
        let models = try XCTUnwrap(requests.last)
        XCTAssertEqual(models.value(forHTTPHeaderField: "ChatGPT-Account-ID"), "test-account")
        XCTAssertTrue(models.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer test.") == true)
    }

    @MainActor
    func testPendingLoginThrottlesAndExpiresWithoutSaving() async throws {
        let clock = TestClock(), store = MemoryCredentials(), transport = FakeCodex(clock: TestClock())
        await transport.configure(pending: true)
        let client = NativeCodexClient(store: store, transport: transport, now: clock.now)
        _ = try await client.beginLogin()
        let first = try await client.pollLogin(), second = try await client.pollLogin()
        XCTAssertFalse(first); XCTAssertFalse(second)
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.url?.path == "/api/accounts/deviceauth/token" }.count, 1)
        clock.advance(901)
        do { _ = try await client.pollLogin(); XCTFail("Expected expiry") }
        catch { XCTAssertEqual(error as? NativeCodexError, .loginExpired) }
        XCTAssertNil(try store.load())
    }

    @MainActor
    func testCancelDuringExchangeCannotSaveLateTokens() async throws {
        let clock = TestClock(), store = MemoryCredentials(), gate = Gate()
        let transport = FakeCodex(clock: clock)
        await transport.configure(exchangeGate: gate)
        let client = NativeCodexClient(store: store, transport: transport, now: clock.now)
        _ = try await client.beginLogin()
        let pending = Task { try await client.pollLogin() }
        await gate.entered()
        await client.cancelLogin()
        await gate.release()
        do { _ = try await pending.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(try store.load())
    }

    @MainActor
    func testConcurrentExpiredRequestsRefreshOnceAndPersistRotatedToken() async throws {
        let (client, store, transport, clock) = try await signedIn()
        clock.advance(3601)
        let gate = Gate()
        await transport.configure(refreshGate: gate)
        let pending = Task {
            try await withThrowingTaskGroup(of: Bool.self) { group in
                for _ in 0..<12 { group.addTask { try await client.account().signedIn } }
                for try await signedIn in group { XCTAssertTrue(signedIn) }
            }
        }
        await gate.entered(); await gate.release()
        try await pending.value
        let count = await transport.refreshCount
        XCTAssertEqual(count, 1)
        let saved = try XCTUnwrap(store.load())
        XCTAssertTrue(String(data: saved, encoding: .utf8)!.contains("refresh-1"))
    }

    @MainActor
    func testCancellingTheOnlyRefreshWaiterStillSavesRotatedCredentials() async throws {
        let (client, store, transport, clock) = try await signedIn()
        clock.advance(3601)
        let gate = Gate()
        await transport.configure(refreshGate: gate)
        let pending = Task { try await client.account() }
        await gate.entered()
        pending.cancel()
        await gate.release()
        do { _ = try await pending.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let saved = try XCTUnwrap(store.load())
        XCTAssertTrue(String(data: saved, encoding: .utf8)!.contains("refresh-1"))
        let account = try await client.account()
        XCTAssertTrue(account.signedIn)
        let count = await transport.refreshCount
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testSignOutDuringRefreshDoesNotRestoreCredentials() async throws {
        let (client, store, transport, clock) = try await signedIn()
        clock.advance(3601)
        let gate = Gate()
        await transport.configure(refreshGate: gate)
        let pending = Task { try await client.account() }
        await gate.entered()
        try await client.signOut()
        await gate.release()
        do { _ = try await pending.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(try store.load())
        let account = try await client.account()
        XCTAssertFalse(account.signedIn)
    }

    @MainActor
    func testInvalidRefreshClearsCredentialsButTransientFailureKeepsThem() async throws {
        for status in [400, 503] {
            let (client, store, transport, clock) = try await signedIn()
            clock.advance(3601)
            await transport.configure(refreshStatus: status)
            do { _ = try await client.account(); XCTFail("Expected failure") }
            catch { XCTAssertEqual(error as? NativeCodexError, status == 400 ? .signedOut : .unavailable) }
            XCTAssertEqual(try store.load() == nil, status == 400)
        }
    }

    @MainActor
    func testRotatedCredentialsCannotRemainStaleWhenKeychainWriteFails() async throws {
        let (client, store, _, clock) = try await signedIn()
        clock.advance(3601); store.failWrites()
        do { _ = try await client.account(); XCTFail("Expected storage failure") }
        catch { XCTAssertEqual(error as? NativeCodexError, .storage) }
        XCTAssertNil(try store.load())
    }

    @MainActor
    func testAuthorizationRejectionRefreshesOnceAndThenSignsOut() async throws {
        let (client, store, transport, _) = try await signedIn()
        await transport.configure(modelStatus: 401)
        do { _ = try await client.account(); XCTFail("Expected sign out") }
        catch { XCTAssertEqual(error as? NativeCodexError, .signedOut) }
        let count = await transport.refreshCount
        XCTAssertEqual(count, 1)
        XCTAssertNil(try store.load())
    }

    @MainActor
    func testAccessDeniedDoesNotRetryWithAnotherClientIdentity() async throws {
        let (client, _, transport, _) = try await signedIn()
        await transport.configure(modelStatus: 403)
        do { _ = try await client.account(); XCTFail("Expected denied access") }
        catch { XCTAssertEqual(error as? NativeCodexError, .accessDenied) }
        let count = await transport.refreshCount
        XCTAssertEqual(count, 0)
    }

    @MainActor
    func testImageRequestUsesChosenModelLowEffortAndNoTools() async throws {
        let (client, _, transport, _) = try await signedIn()
        _ = try await client.account()
        let frame = FrameRequest(key: .init(sessionID: UUID(), objectID: UUID(), frameID: 1, captureTime: 10),
            jpeg: Data([1, 2, 3]), isReference: true, seedPoint: [0.2, 0.3], modelID: "gpt-6-astra")
        let observation = try await client.perceive(frame, reference: nil)
        XCTAssertTrue(observation.found)
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.last)
        XCTAssertEqual(request.url?.absoluteString, "https://chatgpt.com/backend-api/codex/responses")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gpt-6-astra")
        XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "low")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["tools"] as? [String], [])
        XCTAssertEqual(body["tool_choice"] as? String, "none")
        XCTAssertNil(body["max_output_tokens"])
        let invalid = FrameRequest(key: frame.key, jpeg: frame.jpeg, modelID: "unlisted")
        do { _ = try await client.perceive(invalid, reference: nil); XCTFail("Expected model rejection") }
        catch { XCTAssertEqual(error as? NativeCodexError, .modelUnavailable) }
    }

    func testStreamAcceptsOnlyCompletedOutputAcrossCRLFAndMultilineData() throws {
        let response = #"{"type":"response.completed","response":{"status":"completed","output":[{"content":[{"type":"output_text","text":"{\"label\":\"box\",\"confidence\":0.9,\"rect\":null,\"outline\":[]}"}]}]}}"#
        let event = ": heartbeat\r\n\r\ndata: {\"type\":\"response.output_text.delta\",\ndata: \"delta\":\"ignored\"}\n\ndata: \(response)\r\n\r\n"
        var decoder = CodexEventDecoder(), result: Data?
        for byte in event.utf8 { if let output = try decoder.append(byte) { result = output } }
        XCTAssertEqual(try AstraPerception.parse(XCTUnwrap(result)).label, "box")
    }

    func testFailedIncompleteOversizedAndTruncatedStreamsNeverProduceEvidence() throws {
        for type in ["response.failed", "response.incomplete", "error"] {
            var decoder = CodexEventDecoder()
            XCTAssertThrowsError(try Array("data: {\"type\":\"\(type)\"}\n\n".utf8).forEach { _ = try decoder.append($0) })
        }
        var decoder = CodexEventDecoder(limit: 8)
        XCTAssertThrowsError(try Array("data: abcdefgh".utf8).forEach { _ = try decoder.append($0) })
        var truncated = CodexEventDecoder()
        for byte in "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n".utf8 {
            XCTAssertNil(try truncated.append(byte))
        }
    }

    func testCodexTerminalMetadataUsesCompletedItemsButNeverPartialDeltas() throws {
        let message: [String: Any] = ["type": "response.output_item.done", "item": ["type": "message", "role": "assistant",
            "id": "message-1", "content": [["type": "output_text", "text": FakeCodex.object]]]]
        let events = [
            Data(#"{"type":"response.created","response":{"id":"r1"}}"#.utf8),
            try JSONSerialization.data(withJSONObject: message),
            Data(#"{"type":"response.completed","response":{"id":"r1","usage":{"output_tokens":50}}}"#.utf8)
        ]
        var decoder = CodexEventDecoder(), completed: Data?
        for (index, event) in events.enumerated() {
            for byte in Data("data: ".utf8) + event + Data("\n\n".utf8) {
                if let result = try decoder.append(byte) { XCTAssertEqual(index, 2); completed = result }
            }
        }
        XCTAssertTrue(try AstraPerception.parse(XCTUnwrap(completed)).found)
        for ending in [#"{"type":"response.failed","response":{"id":"r1"}}"#,
                       #"{"type":"response.completed","response":{"id":"other"}}"#] {
            var invalid = CodexEventDecoder()
            for event in events.prefix(2) {
                for byte in Data("data: ".utf8) + event + Data("\n\n".utf8) { XCTAssertNil(try invalid.append(byte)) }
            }
            XCTAssertThrowsError(try Array("data: \(ending)\n\n".utf8).forEach { _ = try invalid.append($0) })
        }
    }

    @MainActor
    func testNativeScanRetainsOriginalReferenceAndRejectsObsoleteSelection() async throws {
        let recorder = ScanRecorder()
        let scanner = NativeScanSession(validateImages: false) { frame, reference in await recorder.observe(frame, reference) }
        let session = UUID(), object = UUID()
        let first = FrameRequest(key: .init(sessionID: session, objectID: object, frameID: 1, captureTime: 10),
            jpeg: Data([1]), isReference: true, seedPoint: [0.2, 0.3])
        let selected = try await scanner.observe(first)
        XCTAssertEqual(selected.key, first.key)
        XCTAssertEqual(selected.status, .identityConfirmed)
        for index in 2...3 {
            let frame = FrameRequest(key: .init(sessionID: session, objectID: object, frameID: UInt64(index), captureTime: Double(index + 10)), jpeg: Data([UInt8(index)]))
            let moved = try await scanner.observe(frame)
            XCTAssertEqual(moved.key, frame.key)
            XCTAssertEqual(moved.status, .tracked)
        }
        let replacement = FrameRequest(key: .init(sessionID: session, objectID: UUID(), frameID: 4, captureTime: 20),
            jpeg: Data([4]), isReference: true, seedPoint: [0.2, 0.3])
        _ = try await scanner.observe(replacement)
        do { _ = try await scanner.observe(first); XCTFail("Old selection must not replace current reference") }
        catch { XCTAssertEqual(error as? NativeCodexError, .invalidResponse) }
        let references = await recorder.references
        XCTAssertEqual(references.count, 4)
        XCTAssertNil(references[0]); XCTAssertNil(references[3])
        XCTAssertEqual(references[1]?.jpeg, first.jpeg)
        XCTAssertEqual(references[2]?.jpeg, first.jpeg)
        XCTAssertEqual(references[1]?.seedRect, selected.rect)
    }

    @MainActor
    func testNativeScanCancelledCompletionCannotInitializeReference() async throws {
        let gate = Gate(), recorder = ScanRecorder()
        let scanner = NativeScanSession(validateImages: false) { frame, reference in
            if frame.key.frameID == 1 { await gate.wait() }
            return await recorder.observe(frame, reference)
        }
        let session = UUID(), object = UUID()
        let first = FrameRequest(key: .init(sessionID: session, objectID: object, frameID: 1, captureTime: 10),
            jpeg: Data([1]), isReference: true, seedPoint: [0.2, 0.3])
        let pending = Task { try await scanner.observe(first) }
        await gate.entered(); pending.cancel(); await gate.release()
        do { _ = try await pending.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        let retry = FrameRequest(key: .init(sessionID: session, objectID: object, frameID: 2, captureTime: 11),
            jpeg: Data([2]), isReference: true, seedPoint: [0.2, 0.3])
        let result = try await scanner.observe(retry)
        XCTAssertEqual(result.status, .identityConfirmed)
        let references = await recorder.references
        XCTAssertTrue(references.allSatisfy { $0 == nil })
    }
}
