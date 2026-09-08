import CoreGraphics
import Foundation
import ImageIO
import RealityGitCore
import Vapor
import XCTVapor
import UniformTypeIdentifiers
@testable import RealityGitServer

final class RouteTests: XCTestCase {
    func testAstraRouteAcceptsTapAndReturnsModelOutlineWithoutVisionInitialization() throws {
        let worker = AstraWorker(validateImages: false, provider: { request, reference in
            XCTAssertEqual(request.seedPoint, [0.4, 0.5])
            XCTAssertNil(reference)
            return .init(label: "mug", confidence: 0.95, rect: [0.2, 0.3, 0.3, 0.4],
                outline: [[0.2, 0.3], [0.5, 0.3], [0.5, 0.7], [0.2, 0.7]])
        })
        let app = Application(.testing)
        defer { app.shutdown() }
        try configure(app, astra: worker)
        let frame = FrameRequest(key: testKey(), jpeg: Data([1]), isReference: true, seedPoint: [0.4, 0.5])
        try app.test(.POST, "observe", beforeRequest: { try $0.content.encode(frame) }) { response in
            XCTAssertEqual(response.status, .ok)
            let reply = try response.content.decode(DetectionReply.self)
            XCTAssertEqual(reply.status, .identityConfirmed)
            XCTAssertEqual(reply.semanticLabel, "mug")
            XCTAssertEqual(reply.outline?.count, 4)
        }
    }

    func testHealthAndExactKeyEcho() throws {
        let key = testKey(frame: 42)
        let worker = VisionWorker(validateImageMetadata: false, localizer: { request, _ in
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
        try configure(app, worker: VisionWorker(validateImageMetadata: false, localizer: { _, _ in fatalError("must not run") }))
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

    func testStaleFramesAndSequentialSelections() async throws {
        let worker = VisionWorker(validateImageMetadata: false, localizer: { _, _ in
            LocalizationResult(rect: nil, confidence: 0, candidateID: nil, status: .notFound)
        })
        _ = try await worker.observe(FrameRequest(key: testKey(frame: 2), jpeg: Data([1])))
        await XCTAssertThrowsErrorAsync { _ = try await worker.observe(FrameRequest(key: testKey(frame: 1), jpeg: Data([1]))) }
        for index in 3...15 {
            let key = testKey(object: UInt8(index), frame: UInt64(index), captureTime: Double(index))
            _ = try await worker.observe(FrameRequest(key: key, jpeg: Data([1]), seedRect: [0.1, 0.1, 0.2, 0.2], isReference: true))
        }
    }

    func testPendingObservationIsReplaceable() async throws {
        let gate = Gate()
        let worker = VisionWorker(timeout: .seconds(2), validateImageMetadata: false, localizer: { request, _ in
            if request.key.frameID == 2 { gate.wait() }
            return LocalizationResult(rect: nil, confidence: 0, candidateID: nil, status: .notFound)
        })
        _ = try await worker.observe(FrameRequest(key: testKey(frame: 1), jpeg: Data([1]),
                                                  seedRect: [0.1, 0.1, 0.2, 0.2], isReference: true))
        let first = Task { try await worker.observe(FrameRequest(key: testKey(frame: 2), jpeg: Data([1]))) }
        gate.waitUntilEntered()
        let replaced = Task { try await worker.observe(FrameRequest(key: testKey(frame: 3), jpeg: Data([1]))) }
        while await worker.pendingFrameIDForTesting() != 3 { await Task.yield() }
        let newest = Task { try await worker.observe(FrameRequest(key: testKey(frame: 4), jpeg: Data([1]))) }
        while await worker.pendingFrameIDForTesting() != 4 { await Task.yield() }
        gate.open()
        _ = try await first.value
        await XCTAssertThrowsErrorAsync { _ = try await replaced.value }
        let newestReply = try await newest.value
        XCTAssertEqual(newestReply.key.frameID, 4)
    }

    func testReferenceIsImmutableUntilNewSelection() async throws {
        let seen = LockedValues<ObservationKey?>()
        let worker = VisionWorker(validateImageMetadata: false, localizer: { request, reference in
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
        let worker = VisionWorker(timeout: .milliseconds(50), validateImageMetadata: false, localizer: { request, _ in
            calls.append(request.key.frameID)
            if request.key.frameID == 2 { gate.wait() }
            return LocalizationResult(rect: nil, confidence: 0, candidateID: nil, status: .notFound)
        })
        _ = try await worker.observe(FrameRequest(key: testKey(frame: 1), jpeg: Data([1]),
                                                  seedRect: [0.1, 0.1, 0.2, 0.2], isReference: true))
        let active = Task { try await worker.observe(FrameRequest(key: testKey(frame: 2), jpeg: Data([1]))) }
        gate.waitUntilEntered()
        let pending = Task { try await worker.observe(FrameRequest(key: testKey(frame: 3), jpeg: Data([1]))) }
        while await worker.pendingFrameIDForTesting() != 3 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(80))
        gate.open()
        await XCTAssertThrowsErrorAsync { _ = try await active.value }
        await XCTAssertThrowsErrorAsync { _ = try await pending.value }
        XCTAssertEqual(calls.values, [1, 2])
    }

    func testFailedReferenceDoesNotBecomeImmutableReference() async throws {
        let calls = LockedValues<Bool>()
        let worker = VisionWorker(validateImageMetadata: false, localizer: { _, reference in
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

    func testRetiredReferencesCannotReplaceCurrentSelection() async throws {
        let worker = VisionWorker(validateImageMetadata: false, localizer: { _, _ in
            LocalizationResult(rect: nil, confidence: 1, candidateID: nil, status: .identityConfirmed)
        })
        let seed = [0.1, 0.1, 0.2, 0.2]
        let a = FrameRequest(key: testKey(object: 2, frame: 1, captureTime: 1), jpeg: Data([1]), seedRect: seed, isReference: true)
        let b = FrameRequest(key: testKey(object: 3, frame: 2, captureTime: 2), jpeg: Data([1]), seedRect: seed, isReference: true)
        _ = try await worker.observe(a)
        _ = try await worker.observe(b)
        await XCTAssertThrowsErrorAsync { _ = try await worker.observe(a) }
        let delayedA = FrameRequest(key: testKey(object: 2, frame: 99, captureTime: 1.5), jpeg: Data([1]), seedRect: seed, isReference: true)
        await XCTAssertThrowsErrorAsync { _ = try await worker.observe(delayedA) }
        _ = try await worker.observe(FrameRequest(key: testKey(object: 3, frame: 3, captureTime: 3), jpeg: Data([1])))
    }

    func testRejectedCandidateRetiresAndTemporarilySkipsOnlyItsRegion() throws {
        let jpeg = try candidateFixtureJPEG()
        let engine = VisionLocalizer()
        let reference = FrameRequest(key: testKey(frame: 1, captureTime: 1), jpeg: jpeg, seedRect: [0.2, 0.2, 0.4, 0.4], isReference: true)
        _ = try engine.localize(reference, nil)
        let rect = CGRect(x: 0.2, y: 0.4, width: 0.4, height: 0.4)
        let candidate = try engine.initializeCandidateForTesting(reference, rect: rect)
        let id = try XCTUnwrap(candidate.candidateID)
        let rejected = try engine.localize(FrameRequest(key: testKey(frame: 2, captureTime: 1.2), jpeg: jpeg), reference, rejectedCandidateID: id)
        XCTAssertNotEqual(rejected.candidateID, id)
        XCTAssertNotEqual(rejected.status, .tracked)
        XCTAssertFalse(engine.proposalAllowed(rect, at: 1.3))
        XCTAssertTrue(engine.proposalAllowed(CGRect(x: 0.8, y: 0.8, width: 0.1, height: 0.1), at: 1.3))
        XCTAssertTrue(engine.proposalAllowed(rect, at: 3.21))
    }

    func testCandidateVisionContinuityPromotionAndGapRetirement() throws {
        let jpeg = try candidateFixtureJPEG()
        let engine = VisionLocalizer()
        let reference = FrameRequest(key: testKey(frame: 1, captureTime: 1), jpeg: jpeg, seedRect: [0.2, 0.2, 0.4, 0.4], isReference: true)
        _ = try engine.localize(reference, nil)
        let proposal = try engine.initializeCandidateForTesting(reference, rect: CGRect(x: 0.2, y: 0.4, width: 0.4, height: 0.4))
        let id = try XCTUnwrap(proposal.candidateID)
        let unconfirmed = try engine.localize(FrameRequest(key: testKey(frame: 2, captureTime: 1.2), jpeg: jpeg), reference, authorizedCandidateID: "wrong")
        XCTAssertEqual(unconfirmed.status, .candidate)
        XCTAssertEqual(unconfirmed.candidateID, id)
        let promoted = try engine.localize(FrameRequest(key: testKey(frame: 3, captureTime: 1.4), jpeg: jpeg), reference, authorizedCandidateID: id)
        XCTAssertEqual(promoted.status, .tracked)
        XCTAssertNil(promoted.candidateID)
        XCTAssertNotNil(engine.trackedObservationIDForTesting())
        let second = try engine.initializeCandidateForTesting(reference, rect: CGRect(x: 0.2, y: 0.4, width: 0.4, height: 0.4))
        let expiredID = try XCTUnwrap(second.candidateID)
        let expired = try engine.localize(FrameRequest(key: testKey(frame: 4, captureTime: 2.01), jpeg: jpeg), reference, authorizedCandidateID: expiredID)
        XCTAssertNotEqual(expired.status, .tracked)
        XCTAssertNotEqual(expired.candidateID, expiredID)
    }

    func testProductionJPEGValidationAndVisionSequence() throws {
        let jpeg = try fixtureJPEG(width: 64, height: 64)
        let engine = VisionLocalizer()
        let reference = FrameRequest(key: testKey(), jpeg: jpeg, seedRect: [0.2, 0.2, 0.4, 0.4], isReference: true)
        let initialized = try engine.localize(reference, nil)
        XCTAssertEqual(initialized.status, .identityConfirmed)
        let firstObservation = try XCTUnwrap(engine.trackedObservationIDForTesting())
        let next = FrameRequest(key: testKey(frame: 2), jpeg: jpeg)
        _ = try engine.localize(next, reference)
        XCTAssertEqual(engine.lastTrackingInputIDForTesting(), firstObservation)

        XCTAssertThrowsError(try engine.localize(
            FrameRequest(key: testKey(object: 3, frame: 3, captureTime: 3), jpeg: Data([1]),
                         seedRect: reference.seedRect, isReference: true), nil))
        XCTAssertNil(engine.trackedObservationIDForTesting())
    }

    func testRejectsNonJPEGAndExcessiveDecodedDimensionsBeforeLocalization() async throws {
        let calls = LockedValues<Bool>()
        let worker = VisionWorker(localizer: { _, _ in
            calls.append(true)
            return LocalizationResult(rect: nil, confidence: 0, candidateID: nil, status: .notFound)
        })
        let pngLike = Data([0x89, 0x50, 0x4E, 0x47])
        await XCTAssertThrowsErrorAsync { _ = try await worker.observe(FrameRequest(key: testKey(), jpeg: pngLike)) }
        let valid = try fixtureJPEG(width: 32, height: 32)
        let infinite = ObservationKey(sessionID: testKey().sessionID, objectID: testKey().objectID,
                                      frameID: 2, captureTime: .infinity)
        await XCTAssertThrowsErrorAsync { _ = try await worker.observe(FrameRequest(key: infinite, jpeg: valid)) }
        let oversized = try fixtureJPEG(width: 1_921, height: 1)
        await XCTAssertThrowsErrorAsync { _ = try await worker.observe(FrameRequest(key: testKey(frame: 2), jpeg: oversized)) }
        XCTAssertTrue(calls.values.isEmpty)
    }

    func testInvalidNewSelectionDoesNotMutateCurrentSelection() async throws {
        let worker = VisionWorker(localizer: { request, _ in
            LocalizationResult(rect: request.seedRect, confidence: 1, candidateID: nil,
                               status: request.isReference ? .identityConfirmed : .notFound)
        })
        let jpeg = try fixtureJPEG(width: 32, height: 32)
        let seed = [0.1, 0.1, 0.2, 0.2]
        _ = try await worker.observe(FrameRequest(key: testKey(frame: 1, captureTime: 1), jpeg: jpeg,
                                                  seedRect: seed, isReference: true))
        let badNew = FrameRequest(key: testKey(object: 3, frame: 2, captureTime: 2), jpeg: Data([1]),
                                  seedRect: seed, isReference: true)
        await XCTAssertThrowsErrorAsync { _ = try await worker.observe(badNew) }
        _ = try await worker.observe(FrameRequest(key: testKey(frame: 2, captureTime: 3), jpeg: jpeg))
    }

    func testNonReferenceCannotUseOldEngineWhenPendingReferenceTimesOut() async throws {
        let gate = Gate()
        let calls = LockedValues<(UInt8, UInt64)>()
        let worker = VisionWorker(timeout: .milliseconds(50), validateImageMetadata: false, localizer: { request, _ in
            let object = request.key.objectID.uuidString.hasSuffix("000002") ? UInt8(2) : UInt8(3)
            calls.append((object, request.key.frameID))
            if object == 2, request.key.frameID == 2 { gate.wait() }
            return LocalizationResult(rect: request.seedRect, confidence: 1, candidateID: nil,
                                      status: request.isReference ? .identityConfirmed : .tracked)
        })
        let seed = [0.1, 0.1, 0.2, 0.2]
        _ = try await worker.observe(FrameRequest(key: testKey(object: 2, frame: 1, captureTime: 1),
                                                  jpeg: Data([1]), seedRect: seed, isReference: true))
        let oldActive = Task { try await worker.observe(FrameRequest(
            key: testKey(object: 2, frame: 2, captureTime: 2), jpeg: Data([1]))) }
        gate.waitUntilEntered()
        let newReference = Task { try await worker.observe(FrameRequest(
            key: testKey(object: 3, frame: 3, captureTime: 3), jpeg: Data([1]),
            seedRect: seed, isReference: true)) }
        while await worker.pendingFrameIDForTesting() != 3 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(80))
        let newObservation = Task { try await worker.observe(FrameRequest(
            key: testKey(object: 3, frame: 4, captureTime: 4), jpeg: Data([1]))) }
        while await worker.pendingFrameIDForTesting() != 4 { await Task.yield() }
        gate.open()

        await XCTAssertThrowsErrorAsync { _ = try await oldActive.value }
        await XCTAssertThrowsErrorAsync { _ = try await newReference.value }
        let reply = try await newObservation.value
        XCTAssertEqual(reply.status, .notFound)
        XCTAssertEqual(calls.values.map(\.1), [1, 2])
    }

}

private func testKey(object: UInt8 = 2, frame: UInt64 = 1, captureTime: Double? = nil) -> ObservationKey {
    ObservationKey(sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                   objectID: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", object))!,
                   frameID: frame, captureTime: captureTime ?? Double(frame))
}

private func fixtureJPEG(width: Int, height: Int) throws -> Data {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for index in stride(from: 0, to: pixels.count, by: 4) {
        let checker = ((index / 4) % max(width, 1) + (index / 4) / max(width, 1)) % 2 == 0
        pixels[index] = checker ? 240 : 20
        pixels[index + 1] = checker ? 40 : 210
        pixels[index + 2] = 90
        pixels[index + 3] = 255
    }
    let data = Data(pixels)
    let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
    let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let output = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.2] as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return output as Data
}

private func candidateFixtureJPEG() throws -> Data {
    let width = 256, height = 256
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let offset = (y * width + x) * 4
            let value = ((x / 8) * 73 ^ (y / 8) * 137) % 230
            pixels[offset] = UInt8(value)
            pixels[offset + 1] = UInt8((value * 3 + 40) % 255)
            pixels[offset + 2] = UInt8((value * 7 + 70) % 255)
        }
    }
    let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
    let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let output = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return output as Data
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
