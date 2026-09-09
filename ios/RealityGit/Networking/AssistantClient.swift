import Foundation
import RealityGitCore

struct AssistantClient: Sendable {
    let connection: CompanionConnection
    enum ClientError: Error { case invalidResponse, pairing, signedOut, modelUnavailable, limited, unavailable, loginUnavailable }

    func account() async throws -> CodexAccountStatus {
        try JSONDecoder().decode(CodexAccountStatus.self, from: await send("account"))
    }
    func login() async throws -> CodexLogin {
        let login = try JSONDecoder().decode(CodexLogin.self, from: await send("login", method: "POST"))
        guard login.verificationURL.scheme == "https", login.verificationURL.host == "auth.openai.com",
              login.verificationURL.path == "/codex/device", !login.userCode.isEmpty else { throw ClientError.invalidResponse }
        return login
    }
    func cancelLogin() async throws { _ = try await send("login/cancel", method: "POST") }
    func submit(_ frame: FrameRequest) async throws -> DetectionReply {
        let body = try JSONEncoder().encode(frame)
        guard body.count <= 4_000_000 else { throw ClientError.invalidResponse }
        return try JSONDecoder().decode(DetectionReply.self, from: await send("observe", method: "POST", body: body))
    }

    private func send(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: connection.endpoint.appendingPathComponent(path))
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + connection.token, forHTTPHeaderField: "Authorization")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 25
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        switch response.statusCode {
        case 200, 204: break
        case 401: throw ClientError.pairing
        case 403: throw ClientError.signedOut
        case 409: throw ClientError.modelUnavailable
        case 422: throw ClientError.loginUnavailable
        case 429: throw ClientError.limited
        default: throw ClientError.unavailable
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 64_000 else { throw ClientError.invalidResponse }
            data.append(byte)
        }
        return data
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
