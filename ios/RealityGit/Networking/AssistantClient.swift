import Foundation
import RealityGitCore

struct AssistantClient: Sendable {
    let endpoint: URL
    func submit(_ frame: FrameRequest) async throws -> DetectionReply {
        var request = URLRequest(url: endpoint.appendingPathComponent("observe"))
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(frame)
        guard request.httpBody!.count <= 4_000_000 else { throw ClientError.invalidResponse }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 25
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              data.count <= 64_000 else { throw ClientError.invalidResponse }
        return try JSONDecoder().decode(DetectionReply.self, from: data)
    }
    enum ClientError: Error { case invalidResponse }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
