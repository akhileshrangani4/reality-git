import RealityGitCore
import Vapor

extension FrameRequest: @retroactive Content {}
extension DetectionReply: @retroactive Content {}

struct HealthResponse: Content { let status: String }

func configure(_ app: Application, worker: VisionWorker) throws {
    try configure(app, observe: { try await worker.observe($0) })
}

func configure(_ app: Application, astra: AstraWorker = AstraWorker()) throws {
    try configure(app, observe: { try await astra.observe($0) })
}

private func configure(_ app: Application, observe: @escaping @Sendable (FrameRequest) async throws -> DetectionReply) throws {
    app.routes.defaultMaxBodySize = "4mb"
    app.get("health") { _ in HealthResponse(status: "ok") }
    app.on(.POST, "observe", body: .collect(maxSize: "4mb")) { request async throws -> DetectionReply in
        guard (request.body.data?.readableBytes ?? 0) <= 4 * 1024 * 1024 else {
            throw Abort(.payloadTooLarge)
        }
        let frame: FrameRequest
        do { frame = try request.content.decode(FrameRequest.self) }
        catch { throw Abort(.badRequest, reason: "Invalid frame request") }
        do { return try await observe(frame) }
        catch let error as ObservationError { throw error.abort }
    }
}
