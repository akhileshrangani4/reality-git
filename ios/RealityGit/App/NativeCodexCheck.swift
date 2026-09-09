#if DEBUG
import CoreImage
import ImageIO
import RealityGitCore
import SwiftUI

/// Opt-in device diagnostic. Uses the phone's own sign-in; exports only results, never credentials.
struct NativeCodexCheck: View {
    @State private var status = "Checking your iPhone connection…"
    @State private var finished = false
    var body: some View {
        VStack(spacing: 20) {
            if !finished { ProgressView() }
            Text(status).multilineTextAlignment(.center)
        }.padding(32).task { await run() }
    }

    private func run() async {
        let file = URL.documentsDirectory.appendingPathComponent("native-codex-check.json")
        try? FileManager.default.removeItem(at: file)
        var rows: [[String: Any]] = []
        var report: [String: Any] = ["startedAt": ISO8601DateFormatter().string(from: Date()), "transport": "native-ios-https"]
        do {
            let client = NativeCodexClient()
            let account = try await client.account()
            report["signedIn"] = account.signedIn
            report["models"] = account.models.map(\.id)
            guard account.signedIn, !account.models.isEmpty else { throw NativeCodexError.signedOut }
            let selected = ["gpt-6-astra", "gpt-5.6-luna"].filter { wanted in account.models.contains { $0.id == wanted } }
            for model in selected.isEmpty ? [account.models[0].id] : selected {
                let scanner = NativeScanSession { frame, reference in try await client.perceive(frame, reference: reference) }
                let session = UUID(), object = UUID()
                var firstRect: [Double]?
                for index in 0...1 {
                    status = "Testing \(model) · \(index == 0 ? "selection" : "movement")"
                    let frame = FrameRequest(key: .init(sessionID: session, objectID: object, frameID: UInt64(index + 1),
                        captureTime: ProcessInfo.processInfo.systemUptime), jpeg: try image(x: index == 0 ? 120 : 280),
                        isReference: index == 0, seedPoint: index == 0 ? [0.32, 0.5] : nil, modelID: model)
                    let start = Date()
                    let reply = try await scanner.observe(frame)
                    print("Native Codex check observation status=\(reply.status) confidence=\(reply.confidence) rect=\(reply.rect ?? [])")
                    guard reply.key == frame.key, reply.status == (index == 0 ? .identityConfirmed : .tracked),
                          let rect = reply.rect, let outline = reply.outline,
                          AstraGeometry.validOutline(outline, rect: rect) else { throw NativeCodexError.invalidResponse }
                    if let firstRect {
                        guard rect[0] - firstRect[0] > 0.15 else { throw NativeCodexError.invalidResponse }
                    } else { firstRect = rect }
                    let expected = CGRect(x: Double(index == 0 ? 120 : 280) / 640, y: 0.25, width: 180.0 / 640, height: 0.5)
                    let actual = CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3])
                    let intersection = actual.intersection(expected)
                    let overlap = intersection.isNull ? 0 : intersection.width * intersection.height
                    let iou = overlap / (actual.width * actual.height + expected.width * expected.height - overlap)
                    let accurate = iou >= 0.7
                    let seconds = Date().timeIntervalSince(start)
                    rows.append(["model": model, "frame": index, "seconds": seconds, "rect": rect, "iou": iou, "passed": accurate])
                    print("Native Codex check model=\(model) frame=\(index) seconds=\(seconds) iou=\(iou) passed=\(accurate)")
                }
            }
            let passed = rows.allSatisfy { $0["passed"] as? Bool == true }
            report["passed"] = passed
            status = passed ? "iPhone sign-in and image scanning passed." : "Connected. Some model outlines need review."
        } catch {
            report["passed"] = false
            let failure = (error as? NativeCodexError).map { String(describing: $0) } ?? "request_failed"
            report["failure"] = failure
            status = "Connection check: \(failure)"
            print("Native Codex check failed: \(failure)")
        }
        report["observations"] = rows
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: file, options: [.atomic, .completeFileProtection])
        }
        finished = true
        print("Native Codex check finished")
    }

    private func image(x: CGFloat) throws -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 640, height: 480)
        let background = CIImage(color: CIColor(red: 0.12, green: 0.14, blue: 0.17)).cropped(to: bounds)
        let block = CIImage(color: CIColor(red: 0.95, green: 0.12, blue: 0.08)).cropped(to: CGRect(x: x, y: 120, width: 180, height: 240))
        let patch = CIImage(color: CIColor(red: 0.95, green: 0.95, blue: 0.92)).cropped(to: CGRect(x: x + 35, y: 245, width: 45, height: 55))
        guard let cg = CIContext().createCGImage(patch.composited(over: block.composited(over: background)), from: bounds) else {
            throw NativeCodexError.invalidResponse
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { throw NativeCodexError.invalidResponse }
        CGImageDestinationAddImage(destination, cg, [kCGImagePropertyOrientation: 1] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw NativeCodexError.invalidResponse }
        return data as Data
    }
}
#endif
