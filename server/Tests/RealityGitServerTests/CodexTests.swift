import Foundation
import CoreImage
import ImageIO
import RealityGitCore
import XCTVapor
@testable import RealityGitServer

final class CodexTests: XCTestCase {
    func testCompanionRequiresPairingBeforeAccountOrImageAccess() throws {
        let app = Application(.testing)
        defer { app.shutdown() }
        configureCompanion(app, runtime: CodexRuntime(directory: FileManager.default.temporaryDirectory), token: String(repeating: "a", count: 64))
        try app.test(.GET, "health") { XCTAssertEqual($0.status, .ok) }
        for route in ["account", "login", "observe"] {
            try app.test(route == "account" ? .GET : .POST, route) { XCTAssertEqual($0.status, .unauthorized) }
            try app.test(route == "account" ? .GET : .POST, route,
                headers: ["authorization": "Bearer " + String(repeating: "b", count: 64)]) { XCTAssertEqual($0.status, .unauthorized) }
        }
    }

    func testPairingTokenIsStablePrivateAndExact() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let token = try CompanionPairing.token(in: directory)
        XCTAssertEqual(token.count, 64)
        XCTAssertEqual(try CompanionPairing.token(in: directory), token)
        XCTAssertTrue(CompanionAuth.matches(token, token))
        XCTAssertFalse(CompanionAuth.matches(nil, token))
        XCTAssertFalse(CompanionAuth.matches(token + "a", token))
        let mode = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("pairing-token").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testRPCHandlesEarlyCompletionAndTimesOutWithoutHanging() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-codex")
        let script = """
        #!/usr/bin/python3
        import sys,json
        for line in sys.stdin:
            message=json.loads(line)
            method=message['method']
            if method=='hang': continue
            if method=='turn/start':
                print(json.dumps({'method':'item/completed','params':{'threadId':'t1','item':{'type':'agentMessage','text':'{}','phase':'final_answer'}}}),flush=True)
                print(json.dumps({'method':'turn/completed','params':{'threadId':'t1','turn':{'status':'completed'}}}),flush=True)
            if 'id' in message: print(json.dumps({'id':message['id'],'result':{}}),flush=True)
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let rpc = try CodexRPC(directory: directory, executable: executable.path)
        defer { rpc.close() }
        _ = try await rpc.request("turn/start", params: Data("{}".utf8))
        let data = try await rpc.waitForTurn("t1")
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(result["texts"] as? [String], ["{}"])
        do { _ = try await rpc.request("hang", params: Data("{}".utf8), timeout: 0.05); XCTFail("Expected deadline") }
        catch { XCTAssertTrue(error is CodexFailure) }
        do { _ = try await rpc.request("after-close", params: Data("{}".utf8)); XCTFail("Expected closed connection") }
        catch { XCTAssertTrue(error is CodexFailure) }
    }

    func testLiveSubscriptionSelectionAndMovement() async throws {
        guard ProcessInfo.processInfo.environment["REALITY_CODEX_LIVE"] == "1" else {
            throw XCTSkip("Opt-in Codex subscription test")
        }
        let token = try String(contentsOfFile: "/tmp/reality-codex-integration/pairing-token", encoding: .utf8)
        let selectedModels = ProcessInfo.processInfo.environment["REALITY_CODEX_MODELS"]?.split(separator: ",").map(String.init) ?? ["gpt-6-astra", "gpt-5.6-luna"]
        for model in selectedModels {
            let session = UUID(), object = UUID()
            var first: DetectionReply?
            for index in 0...1 {
                let frame = FrameRequest(key: .init(sessionID: session, objectID: object, frameID: UInt64(index + 1), captureTime: Date().timeIntervalSince1970),
                    jpeg: try image(x: index == 0 ? 120 : 280), isReference: index == 0,
                    seedPoint: index == 0 ? [0.32, 0.5] : nil, modelID: model)
                var request = URLRequest(url: URL(string: "http://127.0.0.1:8081/observe")!)
                request.httpMethod = "POST"; request.timeoutInterval = 35
                request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(frame)
                let start = Date()
                let (data, response) = try await URLSession.shared.data(for: request)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, String(data: data, encoding: .utf8) ?? "")
                let reply = try JSONDecoder().decode(DetectionReply.self, from: data)
                XCTAssertEqual(reply.key, frame.key)
                XCTAssertEqual(reply.status, index == 0 ? .identityConfirmed : .tracked)
                let rect = try XCTUnwrap(reply.rect)
                XCTAssertTrue(AstraGeometry.validOutline(try XCTUnwrap(reply.outline), rect: rect))
                if let first { XCTAssertGreaterThan(rect[0] - first.rect![0], 0.15) } else { first = reply }
                print("Codex live model=\(model) frame=\(index) seconds=\(Date().timeIntervalSince(start)) status=\(reply.status)")
            }
        }
    }

    private func image(x: CGFloat) throws -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 640, height: 480)
        let background = CIImage(color: CIColor(red: 0.12, green: 0.14, blue: 0.17)).cropped(to: bounds)
        let block = CIImage(color: CIColor(red: 0.95, green: 0.12, blue: 0.08)).cropped(to: CGRect(x: x, y: 120, width: 180, height: 240))
        let patch = CIImage(color: CIColor(red: 0.95, green: 0.95, blue: 0.92)).cropped(to: CGRect(x: x + 35, y: 245, width: 45, height: 55))
        let cg = try XCTUnwrap(CIContext().createCGImage(patch.composited(over: block.composited(over: background)), from: bounds))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cg, [kCGImagePropertyOrientation: 1] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
