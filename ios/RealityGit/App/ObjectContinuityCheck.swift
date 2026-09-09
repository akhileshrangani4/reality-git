#if DEBUG
import QuartzCore
import RealityGitCore
import SwiftUI
import simd

/// Opt-in device test: real Astra selection, an empty view, and return from a shifted camera.
/// Exercises the production coordinator while its AR camera is paused; no credentials exported.
struct ObjectContinuityCheck: View {
    @State private var status = "Checking remembered-object continuity…"
    @State private var finished = false
    var body: some View {
        VStack(spacing: 16) {
            if !finished { ProgressView() }
            Text(status).multilineTextAlignment(.center)
        }.padding(30).task { await run() }
    }

    private func run() async {
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        let controller = ARSessionController(), assistant = controller.assistant
        var report: [String: Any] = ["fixture": "real native Astra; synthetic camera translation, offscreen and return"]
        do {
            await assistant.restoreConnection()
            guard assistant.connected, assistant.modelID == "gpt-6-astra" else { throw NativeCodexError.modelUnavailable }
            let source = try CaptureFixture.frame(time: CACurrentMediaTime(), offset: 0)
            controller.beginSelection(.point(CGPoint(x: 0.375, y: 0.5)), sample: source)
            try await wait { !assistant.isThinking && controller.objectSession.reference != nil }
            guard let memory = assistant.referenceEvidence, let reference = controller.objectSession.reference else { throw NativeCodexError.invalidResponse }
            let label = assistant.label
            report["referenceSavedWhileCameraPaused"] = !controller.status.isReady && reference.captureKey.captureTime == source.timestamp
            report["originalReferencePoints"] = reference.points.count

            // The actual reconnect path used to reset this identity.
            assistant.simulateConnectionLossForCheck()
            await assistant.refreshAccount()
            let reconnected = assistant.connected && assistant.referenceEvidence?.reply.key == memory.reply.key
            report["reconnectKeepsIdentity"] = reconnected
            guard reconnected else { throw NativeCodexError.invalidResponse }

            controller.pause()
            status = "Checking the object leaving the frame…"
            let hidden = try CaptureFixture.frame(time: CACurrentMediaTime(), offset: 0, hidden: true, cameraX: 2)
            assistant.offer(hidden)
            try await wait { !assistant.isThinking && assistant.evidence?.0.key.captureTime == hidden.timestamp }
            let missing = assistant.evidence?.0.status == .notFound
            report["emptyViewNotFound"] = missing
            report["offscreenKeepsReference"] = controller.objectSession.reference?.captureKey == reference.captureKey
            guard missing else { throw NativeCodexError.invalidResponse }

            status = "Checking return from a different camera position…"
            let returned = try CaptureFixture.frame(time: CACurrentMediaTime(), offset: -0.125, cameraX: 0.2)
            assistant.offer(returned)
            try await wait { !assistant.isThinking && assistant.evidence?.0.key.captureTime == returned.timestamp }
            guard let recovery = assistant.recoveryEvidence(), recovery.reply.status == .tracked else { throw NativeCodexError.invalidResponse }
            report["returnIsTrackedNotNewSelection"] = true
            report["referenceImageAndLabelUnchanged"] = assistant.referenceEvidence?.reply.key == memory.reply.key && assistant.label == label

            // Restart only the local pixel worker, like a camera interruption. The world reference
            // must survive and measured position must stay stable as the camera translates.
            let tracker = LocalObjectTracker(), generation = UUID(), start = CACurrentMediaTime()
            var tracks = 0, maximumDrift: Float = 0
            for index in 0..<30 {
                let cameraX = 0.2 + Float(index) * 0.002
                let sample = try CaptureFixture.frame(time: start + Double(index) / 30,
                    offset: -cameraX * 1200 / 1920, cameraX: cameraX)
                let result = await tracker.process(sample, generation: generation, recovery: recovery,
                    referencePosition: reference.position, remembered: memory)
                if let capture = result.currentCapture {
                    tracks += 1
                    maximumDrift = max(maximumDrift, simd_distance(reference.position, capture.position))
                }
                controller.objectSession.ingest(result, key: controller.objectSession.key(for: sample), now: sample.timestamp)
            }
            report["cameraMotionTracks"] = tracks
            report["maximumWorldDriftMeters"] = maximumDrift
            report["worldReferenceUnchanged"] = controller.objectSession.reference?.captureKey == reference.captureKey
            report["cameraMotionDidNotMoveObject"] = controller.objectSession.state == .unchanged

            // A late local worker must recover the FIRST source even when the latest answer is
            // offscreen. Reference memory is allowed past the current-evidence expiry.
            let interrupted = LocalObjectTracker()
            let lateSample = try CaptureFixture.frame(time: source.timestamp + 120, offset: 0, hidden: true)
            let rememberedOnly = await interrupted.process(lateSample, generation: UUID(), remembered: memory)
            report["lateWorkerKeepsOriginalSource"] = rememberedOnly.referenceCapture?.timestamp == source.timestamp
                && rememberedOnly.currentCapture == nil && rememberedOnly.provisionalCapture == nil
            controller.reset()
            report["explicitResetClearsIdentity"] = !controller.hasSelection && !assistant.hasRememberedObject && controller.objectSession.reference == nil
            let flags = report.values.compactMap { $0 as? Bool }
            let passed = flags.allSatisfy { $0 } && tracks >= 28 && maximumDrift < 0.05
            report["passed"] = passed
            status = passed ? "Same object retained through camera movement, loss and return." : "Continuity check needs review."
        } catch {
            report["passed"] = false
            report["failure"] = (error as? NativeCodexError).map { String(describing: $0) } ?? "check_failed"
            status = "Continuity check needs review."
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL.documentsDirectory.appendingPathComponent("object-continuity-check.json"),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            print("Object continuity check \(String(data: data, encoding: .utf8) ?? "")")
        }
        finished = true
        print("Object continuity check finished")
    }

    private func wait(until condition: @MainActor () -> Bool) async throws {
        let deadline = CACurrentMediaTime() + 28
        while !condition() {
            guard CACurrentMediaTime() < deadline else { throw NativeCodexError.unavailable }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
#endif
