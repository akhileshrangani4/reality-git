import Foundation
import RealityGitCore
import Vapor
import XCTVapor
@testable import RealityGitServer

final class RouteTests: XCTestCase {
    func testHealthAndExactKeyEcho() throws {
        let key = testKey(frame: 42)
        let worker = VisionWorker(localizer: { request, _ in
            LocalizationResult(rect: request.seedRect, confidence: 0.8, candidateID: nil, status: .tracked)
        })
        let app = Application(.testing)
        defer { app.shutdown() }
        try configure(app, worker: worker)

        try app.test(.GET, "health") { XCTAssertEqual($0.status, .ok) }
        let request = FrameRequest(key: key, jpeg: Data([1]), seedRect: [0.2, 0.2, 0.3, 0.3], isReference: true)
        try app.test(.POST, "observe", beforeRequest: { try $0.content.encode(request) }) { response in
            XCTAssertEqual(response.status, .ok)
            XCTAssertEqual(try response.content.decode(DetectionReply.self).key, key)
        }
    }

    func testMalformedRectangleAndBodyAreRejected() throws {
        let app = Application(.testing)
        defer { app.shutdown() }
        try configure(app, worker: VisionWorker(localizer: { _, _ in fatalError("must not run") }))
        let malformed = FrameRequest(key: testKey(), jpeg: Data([1]), seedRect: [0.9, 0.9, 0.2, 0.2])
        try app.test(.POST, "observe", beforeRequest: { try $0.content.encode(malformed) }) {
            XCTAssertEqual($0.status, .badRequest)
        }
        try app.test(.POST, "observe", headers: ["content-type": "application/json"], body: ByteBuffer(string: "{")) {
            XCTAssertEqual($0.status, .badRequest)
        }
    }

    func testOversizedBodyIsRejected() throws {
        let app = Application(.testing)
        defer { app.shutdown() }
        try configure(app)
        let body = ByteBuffer(data: Data(repeating: 65, count: 4 * 1024 * 1024 + 1))
        try app.test(.POST, "observe", headers: ["content-type": "application/json"], body: body) {
            XCTAssertEqual($0.status, .payloadTooLarge)
        }
    }

    func testStaleFramesAndSessionBound() async throws {
        let worker = VisionWorker(maxSessions: 1, localizer: { _, _ in
            LocalizationResult(rect: nil, confidence: 0, candidateID: nil, status: .notFound)
        })
        _ = try await worker.observe(FrameRequest(key: testKey(frame: 2), jpeg: Data([1])))
        await XCTAssertThrowsErrorAsync { _ = try await worker.observe(FrameRequest(key: testKey(frame: 1), jpeg: Data([1]))) }
        let other = ObservationKey(sessionID: UUID(), objectID: UUID(), frameID: 1, captureTime: 0)
        await XCTAssertThrowsErrorAsync { _ = try await worker.observe(FrameRequest(key: other, jpeg: Data([1]))) }
    }

    func testPendingObservationIsReplaceable() async throws {
        let gate = Gate()
        let worker = VisionWorker(timeout: .seconds(2), localizer: { request, _ in
            if request.key.frameID == 1 { gate.wait() }
            return LocalizationResult(rect: nil, confidence: 0, candidateID: nil, status: .notFound)
        })
        let first = Task { try await worker.observe(FrameRequest(key: testKey(frame: 1), jpeg: Data([1]))) }
        gate.waitUntilEntered()
        let replaced = Task { try await worker.observe(FrameRequest(key: testKey(frame: 2), jpeg: Data([1]))) }
        while await worker.pendingFrameIDForTesting() != 2 { await Task.yield() }
        let newest = Task { try await worker.observe(FrameRequest(key: testKey(frame: 3), jpeg: Data([1]))) }
        while await worker.pendingFrameIDForTesting() != 3 { await Task.yield() }
        gate.open()
        _ = try await first.value
        await XCTAssertThrowsErrorAsync { _ = try await replaced.value }
        let newestReply = try await newest.value
        XCTAssertEqual(newestReply.key.frameID, 3)
    }

    func testReferenceIsImmutableUntilNewSelection() async throws {
        let seen = LockedValues<ObservationKey?>()
        let worker = VisionWorker(localizer: { request, reference in
            seen.append(reference?.key)
            return LocalizationResult(rect: request.seedRect, confidence: 1, candidateID: nil,
                                      status: reference == nil ? .identityConfirmed : .tracked)
        })
        let first = FrameRequest(key: testKey(frame: 1), jpeg: Data([1]), seedRect: [0.1, 0.1, 0.2, 0.2], isReference: true)
        _ = try await worker.observe(first)
        let attemptedReplacement = FrameRequest(key: testKey(frame: 2), jpeg: Data([2]), seedRect: [0.4, 0.4, 0.2, 0.2], isReference: true)
        _ = try await worker.observe(attemptedReplacement)
        let newKey = ObservationKey(sessionID: first.key.sessionID, objectID: UUID(), frameID: 1, captureTime: 3)
        _ = try await worker.observe(FrameRequest(key: newKey, jpeg: Data([3]), seedRect: [0.2, 0.2, 0.2, 0.2], isReference: true))
        let values = seen.values
        XCTAssertNil(values[0])
        XCTAssertEqual(values[1], first.key)
        XCTAssertNil(values[2])
    }

    func testTimedOutPendingWorkNeverRuns() async throws {
        let gate = Gate()
        let calls = LockedValues<UInt64>()
        let worker = VisionWorker(timeout: .milliseconds(50), localizer: { request, _ in
            calls.append(request.key.frameID)
            if request.key.frameID == 1 { gate.wait() }
            return LocalizationResult(rect: nil, confidence: 0, candidateID: nil, status: .notFound)
        })
        let active = Task { try await worker.observe(FrameRequest(key: testKey(frame: 1), jpeg: Data([1]))) }
        gate.waitUntilEntered()
        let pending = Task { try await worker.observe(FrameRequest(key: testKey(frame: 2), jpeg: Data([1]))) }
        while await worker.pendingFrameIDForTesting() != 2 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(80))
        gate.open()
        await XCTAssertThrowsErrorAsync { _ = try await active.value }
        await XCTAssertThrowsErrorAsync { _ = try await pending.value }
        XCTAssertEqual(calls.values, [1])
    }

    func testFailedReferenceDoesNotBecomeImmutableReference() async throws {
        let calls = LockedValues<Bool>()
        let worker = VisionWorker(localizer: { _, reference in
            calls.append(reference != nil)
            if calls.values.count == 1 { throw ObservationError.invalidJPEG }
            return LocalizationResult(rect: nil, confidence: 1, candidateID: nil, status: .identityConfirmed)
        })
        let request = FrameRequest(key: testKey(), jpeg: Data([1]), seedRect: [0.1, 0.1, 0.2, 0.2], isReference: true)
        await XCTAssertThrowsErrorAsync { _ = try await worker.observe(request) }
        let retry = FrameRequest(key: testKey(frame: 2), jpeg: Data([2]), seedRect: request.seedRect, isReference: true)
        _ = try await worker.observe(retry)
        XCTAssertEqual(calls.values, [false, false])
    }

}

private func testKey(frame: UInt64 = 1) -> ObservationKey {
    ObservationKey(sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                   objectID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                   frameID: frame, captureTime: Double(frame))
}

private final class Gate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let entered = DispatchSemaphore(value: 0)
    func wait() { entered.signal(); semaphore.wait() }
    func waitUntilEntered() { entered.wait() }
    func open() { semaphore.signal() }
}

private final class LockedValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []
    func append(_ value: Value) { lock.withLock { storage.append(value) } }
    var values: [Value] { lock.withLock { storage } }
}

private func XCTAssertThrowsErrorAsync(_ expression: () async throws -> Void,
                                       file: StaticString = #filePath, line: UInt = #line) async {
    do { try await expression(); XCTFail("Expected error", file: file, line: line) }
    catch { }
}
