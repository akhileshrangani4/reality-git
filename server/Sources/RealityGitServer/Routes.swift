import RealityGitCore
import Vapor

extension FrameRequest: @retroactive Content {}
extension DetectionReply: @retroactive Content {}

struct HealthResponse: Content { let status: String }

func configure(_ app: Application, worker: VisionWorker = VisionWorker()) throws {
    app.routes.defaultMaxBodySize = "4mb"
    app.get("health") { _ in HealthResponse(status: "ok") }
    app.on(.POST, "observe", body: .collect(maxSize: "4mb")) { request async throws -> DetectionReply in
        guard (request.body.data?.readableBytes ?? 0) <= 4 * 1024 * 1024 else {
            throw Abort(.payloadTooLarge)
        }
        let frame: FrameRequest
        do { frame = try request.content.decode(FrameRequest.self) }
        catch { throw Abort(.badRequest, reason: "Invalid frame request") }
        do { return try await worker.observe(frame) }
        catch let error as ObservationError { throw error.abort }
    }
}
