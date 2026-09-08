import Foundation
import RealityGitCore
import XCTest
@testable import RealityGitServer

final class AstraComparisonTests: XCTestCase {
    actor Gate {
        var calls = 0
        var continuation: CheckedContinuation<AstraLabeler.Comparison, Error>?
        func compare(_ original: FrameRequest, _ candidate: FrameRequest) async throws -> AstraLabeler.Comparison {
            calls += 1
            XCTAssertEqual(original.jpeg, Data([1]))
            XCTAssertEqual(candidate.jpeg, Data([2]))
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        func release(_ verdict: AstraLabeler.Comparison.Verdict = .same, confidence: Double = 0.95) {
            continuation?.resume(returning: .init(verdict: verdict, confidence: confidence)); continuation = nil
        }
    }
    private let session = UUID(), object = UUID()
    private func frame(_ id: UInt64) -> FrameRequest {
        FrameRequest(key: ObservationKey(sessionID: session, objectID: object, frameID: id, captureTime: Double(id) * 0.2), jpeg: Data([id == 1 ? 1 : 2]), seedRect: id == 1 ? [0, 0, 1, 1] : nil, isReference: id == 1)
    }
    private func waitForCall(_ gate: Gate) async throws {
        for _ in 0..<200 {
            if await gate.calls > 0 { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("comparison did not start")
    }
    private func worker(_ gate: Gate, lossAt: UInt64? = nil, replaceAt: UInt64? = nil) -> VisionWorker {
        VisionWorker(validateImageMetadata: false, semanticProvider: { _ in "mug" }, comparator: { try await gate.compare($0, $1) }, authorizedLocalizer: { request, _, authorization in
            if request.isReference { return LocalizationResult(rect: request.seedRect, confidence: 1, candidateID: nil, status: .identityConfirmed) }
            if let lossAt, request.key.frameID >= lossAt { return LocalizationResult(rect: nil, confidence: 0, candidateID: nil, status: .notFound) }
            let id = replaceAt.map { request.key.frameID >= $0 ? "B" : "A" } ?? "A"
            let promoted = authorization == id
            // Geometry comes from this frame, not from the semantic comparison's frame.
            return LocalizationResult(rect: [Double(request.key.frameID) / 1000, 0.2, 0.1, 0.1], confidence: 0.9, candidateID: promoted ? nil : id, status: promoted ? .tracked : .candidate)
        })
    }
    func testDelayedMatchPromotesOnlyNextCurrentFrame() async throws {
        let gate = Gate()
        let subject = self.worker(gate)
        _ = try await subject.observe(frame(1))
        let first = try await subject.observe(frame(2))
        XCTAssertEqual(first.status, .candidate)
        try await waitForCall(gate)
        let delayed = try await subject.observe(frame(3))
        XCTAssertEqual(delayed.status, .candidate)
        let activeState = await subject.comparisonStateForTesting()
        XCTAssertTrue(activeState.active)
        XCTAssertEqual(activeState.pendingFrame, 3)
        await gate.release()
        var reply = delayed
        for id in 4...100 {
            try await Task.sleep(for: .milliseconds(1))
            reply = try await subject.observe(frame(UInt64(id)))
            if reply.status == .tracked { break }
        }
        XCTAssertEqual(reply.status, .tracked)
        XCTAssertGreaterThan(reply.key.frameID, 3)
        XCTAssertEqual(reply.rect?.first, Double(reply.key.frameID) / 1000)
        let count = await gate.calls
        XCTAssertEqual(count, 1)
    }
    func testLateOldCandidateCannotPromoteReplacementOrLostTrack() async throws {
        for loss in [true, false] {
            let gate = Gate()
            let subject = worker(gate, lossAt: loss ? 3 : nil, replaceAt: loss ? nil : 3)
            _ = try await subject.observe(frame(1))
            _ = try await subject.observe(frame(2))
            try await waitForCall(gate)
            _ = try await subject.observe(frame(3))
            await gate.release()
            for id in 4...8 {
                try await Task.sleep(for: .milliseconds(2))
                let reply = try await subject.observe(frame(UInt64(id)))
                XCTAssertEqual(reply.status, loss ? .notFound : .candidate)
            }
            let count = await gate.calls
            XCTAssertEqual(count, 1, "new candidate comparison must respect five-second interval")
        }
    }
    func testLateComparisonCannotAuthorizeNewSelectionEvenWithReusedCandidateID() async throws {
        let gate = Gate(), subject = worker(gate)
        _ = try await subject.observe(frame(1))
        _ = try await subject.observe(frame(2))
        try await waitForCall(gate)
        let replacement = UUID()
        func newFrame(_ id: UInt64, reference: Bool = false) -> FrameRequest {
            FrameRequest(key: ObservationKey(sessionID: session, objectID: replacement, frameID: id, captureTime: Double(id)),
                jpeg: Data([reference ? 1 : 2]), seedRect: reference ? [0, 0, 1, 1] : nil, isReference: reference)
        }
        _ = try await subject.observe(newFrame(10, reference: true))
        _ = try await subject.observe(newFrame(11))
        await gate.release()
        for id in 12...16 {
            try await Task.sleep(for: .milliseconds(2))
            let reply = try await subject.observe(newFrame(UInt64(id)))
            XCTAssertEqual(reply.status, .candidate)
        }
    }

    func testUncertainAndLowConfidenceNeverPromoteOrRetryCandidate() async throws {
        for decision in [AstraLabeler.Comparison(verdict: .uncertain, confidence: 1), .init(verdict: .same, confidence: 0.84)] {
            let gate = Gate(), subject = worker(gate)
            _ = try await subject.observe(frame(1))
            _ = try await subject.observe(frame(2))
            try await waitForCall(gate)
            await gate.release(decision.verdict, confidence: decision.confidence)
            for id in 3...8 {
                try await Task.sleep(for: .milliseconds(1))
                let reply = try await subject.observe(frame(UInt64(id)))
                XCTAssertEqual(reply.status, .candidate)
            }
            let count = await gate.calls
            XCTAssertEqual(count, 1)
        }
    }
    func testComparisonParserRejectsExtraFieldsAndBooleanConfidence() throws {
        func response(_ text: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["status": "completed", "output": [["content": [["type": "output_text", "text": text]]]]])
        }
        XCTAssertTrue(try AstraLabeler.parseComparison(response("{\"verdict\":\"same\",\"confidence\":0.85}")).authorizes)
        for invalid in ["{\"verdict\":\"same\",\"confidence\":true}", "{\"verdict\":\"same\",\"confidence\":1,\"rect\":[]}", "{\"verdict\":\"same\",\"confidence\":1.1}"] {
            XCTAssertThrowsError(try AstraLabeler.parseComparison(response(invalid)))
        }
        XCTAssertThrowsError(try AstraLabeler.parse(response("{\"label\":\"mug\",\"extra\":true}")))
    }
}
