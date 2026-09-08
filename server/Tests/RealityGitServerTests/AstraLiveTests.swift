import CoreImage
import Foundation
import RealityGitCore
import XCTest
@testable import RealityGitServer

final class AstraLiveTests: XCTestCase {
    func testLiveSelectionAndFullFrameReacquisition() async throws {
        guard ProcessInfo.processInfo.environment["RUN_ASTRA_LIVE"] == "1" else {
            throw XCTSkip("Opt-in provider smoke test")
        }
        let context = CIContext()
        let scene = CGRect(x: 0, y: 0, width: 640, height: 480)
        func jpeg(offset: CGFloat) throws -> Data {
            let background = CIImage(color: CIColor(red: 0.18, green: 0.2, blue: 0.23)).cropped(to: scene)
            let block = CIImage(color: CIColor(red: 0.85, green: 0.05, blue: 0.05)).cropped(to: CGRect(x: 180 + offset, y: 130, width: 150, height: 220))
            let mark = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 215 + offset, y: 240, width: 35, height: 45))
            return try XCTUnwrap(context.jpegRepresentation(of: mark.composited(over: block).composited(over: background), colorSpace: CGColorSpaceCreateDeviceRGB()))
        }
        let object = UUID(), session = UUID()
        let selected = FrameRequest(key: ObservationKey(sessionID: session, objectID: object, frameID: 1, captureTime: 1),
            jpeg: try jpeg(offset: 0), isReference: true, seedPoint: [0.4, 0.5])
        let start = Date()
        let initial = try await AstraObserver.observe(selected, reference: nil)
        print("Astra live initial latency=\(Date().timeIntervalSince(start))s confidence=\(initial.confidence) rect=\(String(describing: initial.rect))")
        XCTAssertTrue(initial.found)
        let rect = try XCTUnwrap(initial.rect)
        XCTAssertTrue(try XCTUnwrap(AstraGeometry.rectangle(rect)).contains(CGPoint(x: 0.4, y: 0.5)))
        let reference = FrameRequest(key: selected.key, jpeg: selected.jpeg, seedRect: rect, isReference: true)
        let moved = FrameRequest(key: ObservationKey(sessionID: session, objectID: object, frameID: 2, captureTime: 2), jpeg: try jpeg(offset: 120))
        let nextStart = Date()
        let current = try await AstraObserver.observe(moved, reference: reference)
        print("Astra live recovery latency=\(Date().timeIntervalSince(nextStart))s confidence=\(current.confidence) rect=\(String(describing: current.rect))")
        XCTAssertTrue(current.found)
        XCTAssertGreaterThan(try XCTUnwrap(current.rect).first ?? 0, rect[0] + 0.1)
    }
}
