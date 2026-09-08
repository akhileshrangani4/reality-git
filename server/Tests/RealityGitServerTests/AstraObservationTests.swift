import Foundation
import RealityGitCore
import XCTest
@testable import RealityGitServer

final class AstraObservationTests: XCTestCase {
    private let rect = [0.2, 0.3, 0.3, 0.4]
    private let outline = [[0.2, 0.3], [0.5, 0.3], [0.5, 0.7], [0.2, 0.7]]

    private func frame(object: UUID, id: UInt64, time: Double, reference: Bool = false) -> FrameRequest {
        FrameRequest(key: ObservationKey(sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            objectID: object, frameID: id, captureTime: time), jpeg: Data([1]),
            isReference: reference, seedPoint: reference ? [0.4, 0.5] : nil)
    }

    func testTapReachesAstraWithoutAppleMaskAndLostObjectIsSearchedInFullFrame() async throws {
        actor Recorder {
            var references: [FrameRequest?] = []
            func record(_ reference: FrameRequest?) { references.append(reference) }
        }
        let recorder = Recorder(), object = UUID()
        let rect = rect, outline = outline
        let worker = AstraWorker(validateImages: false, provider: { request, reference in
            await recorder.record(reference)
            if request.key.frameID == 2 { return .init(label: "mug", confidence: 0.3, rect: nil, outline: []) }
            return .init(label: "mug", confidence: 0.95, rect: rect, outline: outline)
        })
        let selected = frame(object: object, id: 1, time: 1, reference: true)
        let initial = try await worker.observe(selected)
        XCTAssertEqual(initial.status, .identityConfirmed)
        XCTAssertEqual(initial.key, selected.key)
        let lost = try await worker.observe(frame(object: object, id: 2, time: 2))
        XCTAssertEqual(lost.status, .notFound)
        // No candidate ID, Apple proposal, five-second gate, or second comparison call.
        let recovered = try await worker.observe(frame(object: object, id: 3, time: 2.1))
        XCTAssertEqual(recovered.status, .tracked)
        let references = await recorder.references
        XCTAssertNil(references[0])
        XCTAssertEqual(references[1]?.key, selected.key)
        XCTAssertEqual(references[2]?.key, selected.key)
        XCTAssertEqual(references[2]?.seedRect, rect)
    }

    func testUncertainInitialSelectionIsRetriedWithoutFreezingWrongReference() async throws {
        let rect = rect, outline = outline, object = UUID()
        let worker = AstraWorker(validateImages: false, provider: { request, reference in
            XCTAssertNil(reference)
            return .init(label: "mug", confidence: request.key.frameID == 1 ? 0.5 : 0.95, rect: rect, outline: outline)
        })
        let uncertain = try await worker.observe(frame(object: object, id: 1, time: 1, reference: true))
        XCTAssertEqual(uncertain.status, .notFound)
        XCTAssertNil(uncertain.rect)
        let retry = try await worker.observe(frame(object: object, id: 2, time: 1, reference: true))
        XCTAssertEqual(retry.status, .identityConfirmed)
    }

    func testNewSelectionRetiresDelayedResultAndKeepsSingleProviderSlot() async throws {
        actor Gate {
            var waiting: CheckedContinuation<AstraObserver.Observation, Never>?
            var calls = 0
            func observe() async -> AstraObserver.Observation {
                calls += 1
                if calls == 1 { return await withCheckedContinuation { waiting = $0 } }
                return .init(label: "new", confidence: 0, rect: nil, outline: [])
            }
            func release() { waiting?.resume(returning: .init(label: "old", confidence: 0, rect: nil, outline: [])); waiting = nil }
        }
        let gate = Gate(), oldObject = UUID(), newObject = UUID()
        let worker = AstraWorker(validateImages: false, provider: { _, _ in await gate.observe() })
        let oldFrame = frame(object: oldObject, id: 1, time: 1, reference: true)
        let old = Task { try await worker.observe(oldFrame) }
        while await gate.calls == 0 { await Task.yield() }
        do {
            _ = try await worker.observe(frame(object: newObject, id: 2, time: 2, reference: true))
            XCTFail("Physical provider slot must stay bounded")
        } catch { XCTAssertEqual(error as? ObservationError, .obsolete) }
        await gate.release()
        do { _ = try await old.value; XCTFail("Retired selection must not return") }
        catch { XCTAssertEqual(error as? ObservationError, .obsolete) }
        let new = try await worker.observe(frame(object: newObject, id: 3, time: 2, reference: true))
        XCTAssertEqual(new.semanticLabel, "new")
        do { _ = try await worker.observe(oldFrame); XCTFail("Old selection must stay retired") }
        catch { XCTAssertEqual(error as? ObservationError, .obsolete) }
    }

    func testProviderBodyUsesLowEffortAndFullCurrentFrame() throws {
        let selected = frame(object: UUID(), id: 1, time: 1, reference: true)
        let body = try AstraObserver.body(selected, reference: nil)
        XCTAssertEqual(body["model"] as? String, "gpt-6-astra")
        XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "low")
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.last?["image_url"] as? String, "data:image/jpeg;base64," + selected.jpeg.base64EncodedString())
        XCTAssertTrue((content.first?["text"] as? String)?.contains("[0.4, 0.5]") == true)
    }

    func testInvalidSelectionCannotRetireReferenceAndDuplicateFramesAreRejected() async throws {
        let object = UUID(), rect = rect, outline = outline
        let worker = AstraWorker(validateImages: false, provider: { _, _ in
            .init(label: "mug", confidence: 0.95, rect: rect, outline: outline)
        })
        let selected = frame(object: object, id: 1, time: 1, reference: true)
        _ = try await worker.observe(selected)
        let invalid = FrameRequest(key: frame(object: UUID(), id: 2, time: 2).key,
            jpeg: Data([1]), isReference: true, seedPoint: [1.2, 0.5])
        do { _ = try await worker.observe(invalid); XCTFail("Invalid tap must be rejected") }
        catch { XCTAssertEqual(error as? ObservationError, .invalidRectangle) }
        let current = try await worker.observe(frame(object: object, id: 2, time: 3))
        XCTAssertEqual(current.status, .tracked)
        do { _ = try await worker.observe(selected); XCTFail("Duplicate frame must be rejected") }
        catch { XCTAssertEqual(error as? ObservationError, .obsolete) }
    }

    func testParserRejectsMalformedCoordinatesRefusalAndIncompleteOutput() throws {
        func response(rect: Any, outline: Any, status: String = "completed", confidence: Any = 0.95) throws -> Data {
            let payload: [String: Any] = ["label": "mug", "confidence": confidence, "rect": rect, "outline": outline]
            let encoded = try JSONSerialization.data(withJSONObject: payload)
            return try JSONSerialization.data(withJSONObject: ["status": status, "output": [["content": [[
                "type": "output_text", "text": String(decoding: encoded, as: UTF8.self)
            ]]]]])
        }
        XCTAssertTrue(try AstraObserver.parse(response(rect: rect, outline: outline)).found)
        XCTAssertFalse(try AstraObserver.parse(response(rect: NSNull(), outline: [])).found)
        XCTAssertThrowsError(try AstraObserver.parse(response(rect: [0, 0, 2, 1], outline: outline)))
        XCTAssertThrowsError(try AstraObserver.parse(response(rect: rect, outline: [[0.1, 0.1], [0.2, 0.3], [0.3, 0.4]])))
        XCTAssertThrowsError(try AstraObserver.parse(response(rect: rect, outline: outline, status: "incomplete")))
        XCTAssertThrowsError(try AstraObserver.parse(response(rect: rect, outline: outline, confidence: true)))
        XCTAssertThrowsError(try AstraObserver.parse(response(rect: [false, 0.3, 0.5, 0.4], outline: outline)))
        let refusal = Data(#"{"status":"completed","output":[{"content":[{"type":"refusal","refusal":"declined"}]}]}"#.utf8)
        XCTAssertThrowsError(try AstraObserver.parse(refusal))
    }
}
