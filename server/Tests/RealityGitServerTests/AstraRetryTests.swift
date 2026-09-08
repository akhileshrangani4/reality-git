import Foundation
import RealityGitCore
import XCTest
@testable import RealityGitServer

final class AstraRetryTests: XCTestCase {
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Double = 0
        func get() -> Double { lock.withLock { value } }
        func set(_ value: Double) { lock.withLock { self.value = value } }
    }
    actor Provider {
        var frames: [UInt64] = []
        let alwaysUncertain: Bool
        init(alwaysUncertain: Bool = false) { self.alwaysUncertain = alwaysUncertain }
        func compare(_ reference: FrameRequest, _ candidate: FrameRequest) throws -> AstraLabeler.Comparison {
            frames.append(candidate.key.frameID)
            XCTAssertEqual(candidate.jpeg, Data([UInt8(candidate.key.frameID)]))
            if alwaysUncertain { return .init(verdict: .uncertain, confidence: 1) }
            if frames.count == 1 { throw AstraLabeler.Failure.unavailable }
            return .init(verdict: .same, confidence: 0.95)
        }
    }
    private let session = UUID(), object = UUID()
    private func frame(_ id: UInt64) -> FrameRequest {
        FrameRequest(key: ObservationKey(sessionID: session, objectID: object, frameID: id, captureTime: Double(id) / 10), jpeg: Data([UInt8(id)]), seedRect: id == 1 ? [0, 0, 1, 1] : nil, isReference: id == 1)
    }
    private func worker(_ clock: Clock, _ provider: Provider) -> VisionWorker {
        VisionWorker(validateImageMetadata: false, semanticProvider: { _ in "mug" }, comparator: { try await provider.compare($0, $1) }, authorizedLocalizer: { request, _, authorization in
            LocalizationResult(rect: [0, 0, 0.5, 0.5], confidence: 0.9, candidateID: request.isReference || authorization == "A" ? nil : "A", status: request.isReference ? .identityConfirmed : authorization == "A" ? .tracked : .candidate)
        }, now: { clock.get() })
    }
    private func waitForRetry(_ worker: VisionWorker, at time: Double) async throws {
        for _ in 0..<200 {
            if await worker.comparisonStateForTesting().retryAt == time { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("retry was not scheduled")
    }
    func testUnavailableRetriesFreshestFrameAfterBackoffAndPromotesCurrentFrame() async throws {
        let clock = Clock(), provider = Provider(), subject = worker(clock, provider)
        _ = try await subject.observe(frame(1))
        _ = try await subject.observe(frame(2))
        try await waitForRetry(subject, at: 5)
        for id in 3...10 { _ = try await subject.observe(frame(UInt64(id))) }
        let state = await subject.comparisonStateForTesting()
        XCTAssertEqual(state.pendingFrame, 10)
        XCTAssertFalse(state.active)
        let before = await provider.frames
        XCTAssertEqual(before, [2])
        clock.set(4.99)
        _ = try await subject.observe(frame(11))
        let early = await provider.frames
        XCTAssertEqual(early, [2])
        clock.set(5)
        _ = try await subject.observe(frame(12))
        var reply: DetectionReply?
        for id in 13...100 {
            try await Task.sleep(for: .milliseconds(1))
            reply = try await subject.observe(frame(UInt64(id)))
            if reply?.status == .tracked { break }
        }
        XCTAssertEqual(reply?.status, .tracked)
        let calls = await provider.frames
        XCTAssertEqual(calls, [2, 12])
    }
    func testUncertaintyBackoffPersistsAcrossFramesAndCapsAtThirtySeconds() async throws {
        let clock = Clock(), provider = Provider(alwaysUncertain: true), subject = worker(clock, provider)
        _ = try await subject.observe(frame(1))
        _ = try await subject.observe(frame(2))
        try await waitForRetry(subject, at: 5)
        var id: UInt64 = 3
        for (due, next) in [(5.0, 15.0), (15, 35), (35, 65), (65, 95)] {
            clock.set(due - 0.1)
            _ = try await subject.observe(frame(id)); id += 1
            let before = await provider.frames.count
            clock.set(due)
            _ = try await subject.observe(frame(id)); id += 1
            try await waitForRetry(subject, at: next)
            let after = await provider.frames.count
            XCTAssertEqual(after, before + 1)
        }
    }
}
