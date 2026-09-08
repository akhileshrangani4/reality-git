import XCTest
@testable import RealityGitCore

private final class TestFrame: @unchecked Sendable {
    let id: Int
    init(_ id: Int) { self.id = id }
}
private actor HeldEncoder {
    private var active = 0
    private(set) var peak = 0
    private(set) var starts: [Int] = []
    private var holds: [Int: CheckedContinuation<Int, Never>] = [:]
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func encode(_ id: Int) async -> Int {
        active += 1; peak = max(peak, active); starts.append(id)
        return await withCheckedContinuation { continuation in
            holds[id] = continuation
            let ready = startWaiters.filter { starts.count >= $0.0 }
            startWaiters.removeAll { starts.count >= $0.0 }
            ready.forEach { $0.1.resume() }
        }
    }
    func waitForStarts(_ count: Int) async {
        if starts.count >= count { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }
    func release(_ id: Int) {
        active -= 1
        holds.removeValue(forKey: id)?.resume(returning: id)
    }
}

final class AssistantLifecycleTests: XCTestCase {
    @MainActor
    func testHeldDetachedEncoderSurvivesRepeatedResetWithoutParallelWork() async {
        let encoder = HeldEncoder()
        let results = AsyncStream<Int>.makeStream()
        let worker = LatestAsyncWorker<TestFrame, Int>(operation: { frame in
            // Deliberately ignores parent cancellation just like synchronous Core Image work.
            await Task.detached { await encoder.encode(frame.id) }.value
        }, completion: { _, result in
            if case .success(let value) = result { results.continuation.yield(value) }
        })
        worker.submit(TestFrame(1))
        await encoder.waitForStarts(1)
        var abandoned: TestFrame? = TestFrame(2)
        weak var weakAbandoned = abandoned
        worker.submit(abandoned!)
        abandoned = nil
        worker.invalidate()
        XCTAssertNil(weakAbandoned, "Invalidation must release pending full-frame payloads")
        for id in 3...6 { worker.submit(TestFrame(id)); worker.invalidate() }
        worker.submit(TestFrame(7))
        worker.submit(TestFrame(8))
        worker.submit(TestFrame(9))
        let responsive = await Task { @MainActor in true }.value
        XCTAssertTrue(responsive, "Main actor must run while the encoder remains held")
        let before = await encoder.starts
        XCTAssertEqual(before, [1])
        await encoder.release(1)
        await encoder.waitForStarts(2)
        let started = await encoder.starts
        XCTAssertEqual(started, [1, 9])
        await encoder.release(9)
        var iterator = results.stream.makeAsyncIterator()
        let result = await iterator.next()
        XCTAssertEqual(result, 9, "Old generation completion must not reach its owner")
        let peak = await encoder.peak
        XCTAssertEqual(peak, 1)
    }

    @MainActor
    func testReconnectInvalidatesHeldWorkAndEndpointChangeRequiresExplicitSelection() async {
        var connection = AssistantConnectionState()
        let first = URL(string: "http://mac.local:8080")!
        let second = URL(string: "http://other.local:8080")!
        connection.connect(to: first)
        connection.acknowledgeReference()
        let encoder = HeldEncoder()
        let results = AsyncStream<Int>.makeStream()
        let worker = LatestAsyncWorker<Int, Int>(operation: { await encoder.encode($0) }, completion: { _, result in
            if case .success(let value) = result { results.continuation.yield(value) }
        })
        worker.submit(1)
        await encoder.waitForStarts(1)
        worker.invalidate() // Same coordinator invalidation used by Connect/Disconnect.
        connection.connect(to: first)
        XCTAssertTrue(connection.referenceInitialized)
        XCTAssertFalse(connection.requiresReselection)
        connection.connect(to: second)
        XCTAssertTrue(connection.requiresReselection)
        connection.selectNewObject()
        XCTAssertFalse(connection.requiresReselection)
        XCTAssertFalse(connection.referenceInitialized)
        worker.submit(2)
        await encoder.release(1)
        await encoder.waitForStarts(2)
        await encoder.release(2)
        var iterator = results.stream.makeAsyncIterator()
        let result = await iterator.next()
        XCTAssertEqual(result, 2)
        let peak = await encoder.peak
        XCTAssertEqual(peak, 1)
    }

    func testMaskDropoutKeepsConfidentBoxWithholdsGeometryAndRecoversOnMaskReturn() {
        let box = CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3)
        let position = SIMD3<Float>(0, 0, -1)
        let before = LocalTrackingEvidence(confidentTrackedRect: box, maskRect: box, maskPosition: position)
        XCTAssertEqual(before.worldPosition, position)
        let dropout = LocalTrackingEvidence(confidentTrackedRect: box, maskRect: nil, maskPosition: position)
        XCTAssertTrue(dropout.preservesTrack)
        XCTAssertEqual(dropout.displayRect, box)
        XCTAssertNil(dropout.worldPosition)
        XCTAssertNil(dropout.referenceRect, "Visual-only boxes cannot initialize the Mac reference")
        let recovered = LocalTrackingEvidence(confidentTrackedRect: box, maskRect: box, maskPosition: position)
        XCTAssertTrue(recovered.preservesTrack)
        XCTAssertEqual(recovered.worldPosition, position)
        XCTAssertEqual(recovered.referenceRect, box)
        let lost = LocalTrackingEvidence(confidentTrackedRect: nil, maskRect: nil, maskPosition: nil)
        XCTAssertFalse(lost.preservesTrack)
        XCTAssertNil(lost.worldPosition)
    }
}
