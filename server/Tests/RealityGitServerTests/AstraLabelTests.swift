import CoreImage
import Foundation
import ImageIO
import RealityGitCore
import XCTest
@testable import RealityGitServer

final class AstraLabelTests: XCTestCase {
    actor ProviderGate {
        var calls = 0
        var waiting: CheckedContinuation<String, Error>?
        func label(_ request: FrameRequest) async throws -> String {
            calls += 1
            if calls == 1 { return try await withCheckedThrowingContinuation { waiting = $0 } }
            return "new object"
        }
        func release() { waiting?.resume(returning: "old object"); waiting = nil }
    }

    func testSlowOldLabelDoesNotBlockObservationsOrLeakIntoNewSelection() async throws {
        let gate = ProviderGate()
        let worker = VisionWorker(validateImageMetadata: false, localizer: { request, _ in
            LocalizationResult(rect: request.seedRect, confidence: 1, candidateID: nil, status: .tracked)
        }, semanticProvider: { try await gate.label($0) })
        let session = UUID(), first = UUID(), second = UUID()
        func frame(_ object: UUID, _ id: UInt64, reference: Bool = false) -> FrameRequest {
            FrameRequest(key: ObservationKey(sessionID: session, objectID: object, frameID: id, captureTime: Double(id)),
                         jpeg: Data([1]), seedRect: reference ? [0, 0, 1, 1] : nil, isReference: reference)
        }
        let initial = try await worker.observe(frame(first, 1, reference: true))
        XCTAssertEqual(initial.semanticStatus, "labeling")
        for _ in 0..<100 where await gate.calls == 0 { try await Task.sleep(for: .milliseconds(1)) }
        let next = try await worker.observe(frame(second, 2, reference: true))
        XCTAssertNil(next.semanticLabel)
        let pending = try await worker.observe(frame(second, 3))
        XCTAssertEqual(pending.semanticStatus, "labeling")
        let callCount = await gate.calls
        XCTAssertEqual(callCount, 1)
        await gate.release()
        var reply = pending
        for id in 4...100 {
            try await Task.sleep(for: .milliseconds(2))
            reply = try await worker.observe(frame(second, UInt64(id)))
            XCTAssertNotEqual(reply.semanticLabel, "old object")
            if reply.semanticStatus == "ready" { break }
        }
        XCTAssertEqual(reply.semanticLabel, "new object")
    }

    func testUnavailableProviderLeavesTrackingWorking() async throws {
        let worker = VisionWorker(validateImageMetadata: false, localizer: { _, _ in
            LocalizationResult(rect: [0, 0, 1, 1], confidence: 1, candidateID: nil, status: .tracked)
        }, semanticProvider: { _ in throw AstraLabeler.Failure.unavailable })
        let session = UUID(), object = UUID()
        var reply: DetectionReply?
        for id in 1...50 {
            reply = try await worker.observe(FrameRequest(key: ObservationKey(sessionID: session, objectID: object, frameID: UInt64(id), captureTime: Double(id)), jpeg: Data([1]), seedRect: id == 1 ? [0, 0, 1, 1] : nil, isReference: id == 1))
            XCTAssertEqual(reply?.status, .tracked)
            if reply?.semanticStatus == "unavailable" { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(reply?.semanticStatus, "unavailable")
    }

    func testCropUsesTopLeftSeedAndCapsLongEdge() throws {
        let context = CIContext()
        let bottom = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 1200, height: 400))
        let top = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 400, width: 1200, height: 400))
        let image = top.composited(over: bottom)
        let jpeg = try XCTUnwrap(context.jpegRepresentation(of: image, colorSpace: CGColorSpaceCreateDeviceRGB()))
        let frame = FrameRequest(key: ObservationKey(sessionID: UUID(), objectID: UUID(), frameID: 1, captureTime: 1),
                                 jpeg: jpeg, seedRect: [0, 0, 1, 0.5], isReference: true)
        let cropped = try AstraLabeler.crop(frame)
        let output = try XCTUnwrap(CIImage(data: cropped))
        XCTAssertLessThanOrEqual(output.extent.width, 512)
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: output.extent.midX, y: output.extent.midY, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        XCTAssertGreaterThan(pixel[0], 200)
        XCTAssertLessThan(pixel[2], 40)
    }

    func testProviderParsingRejectsRefusalIncompleteAndInvalidLabels() throws {
        func response(_ status: String, _ type: String, _ text: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["status": status, "output": [["content": [["type": type, "text": text]]]]])
        }
        XCTAssertEqual(try AstraLabeler.parse(response("completed", "output_text", "{\"label\":\"red mug\"}")), "red mug")
        XCTAssertThrowsError(try AstraLabeler.parse(response("incomplete", "output_text", "{\"label\":\"mug\"}")))
        XCTAssertThrowsError(try AstraLabeler.parse(response("completed", "refusal", "declined")))
        XCTAssertThrowsError(try AstraLabeler.parse(response("completed", "output_text", "{\"label\":\"\"}")))
    }
}
