import Foundation

/// The physical active slot survives invalidation until its operation actually returns.
/// All callers (including reset/reconnect) share this single owner.
@MainActor
public final class LatestAsyncWorker<Input: Sendable, Output: Sendable> {
    private let operation: @Sendable (Input) async throws -> Output
    private let completion: @MainActor (Input, Result<Output, any Error>) -> Void
    private var active: Task<Void, Never>?
    private var pending: Input?
    private var generation: UInt64 = 0

    public init(operation: @escaping @Sendable (Input) async throws -> Output,
                completion: @escaping @MainActor (Input, Result<Output, any Error>) -> Void) {
        self.operation = operation
        self.completion = completion
    }
    public func submit(_ input: Input) {
        guard active == nil else { pending = input; return }
        start(input)
    }
    public func invalidate() {
        generation &+= 1
        pending = nil
        // Synchronous encoders may ignore cancellation. Never release their slot here.
        active?.cancel()
    }
    private func start(_ input: Input) {
        let startedGeneration = generation
        let operation = operation
        active = Task {
            let result: Result<Output, any Error>
            do { result = .success(try await operation(input)) }
            catch { result = .failure(error) }
            if startedGeneration == generation { completion(input, result) }
            active = nil
            if let next = pending {
                pending = nil
                start(next)
            }
        }
    }
}

public struct AssistantConnectionState: Sendable {
    public private(set) var endpoint: URL?
    public private(set) var referenceInitialized = false
    public private(set) var requiresReselection = false
    public init() {}
    public mutating func connect(to newEndpoint: URL) {
        if let endpoint, endpoint != newEndpoint { requiresReselection = true }
        endpoint = newEndpoint
    }
    public mutating func selectNewObject() {
        referenceInitialized = false
        requiresReselection = false
    }
    public mutating func acknowledgeReference() { referenceInitialized = true }
}

/// Only mask-backed samples can supply a reference crop or metric position.
public struct LocalTrackingEvidence: Sendable {
    public let displayRect: CGRect?
    public let referenceRect: CGRect?
    public let worldPosition: SIMD3<Float>?
    public var preservesTrack: Bool { displayRect != nil }
    public init(confidentTrackedRect: CGRect?, maskRect: CGRect?, maskPosition: SIMD3<Float>?) {
        displayRect = maskRect ?? confidentTrackedRect
        referenceRect = maskRect
        worldPosition = maskRect == nil ? nil : maskPosition
    }
}
