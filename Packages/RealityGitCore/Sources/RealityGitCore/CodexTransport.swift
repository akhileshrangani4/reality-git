import Foundation

public enum NativeCodexError: Error, Equatable, Sendable {
    case invalidResponse, signedOut, accessDenied, modelUnavailable, limited, unavailable, loginUnavailable, loginExpired, storage
}

struct CodexHTTPReply: Sendable {
    let status: Int
    let data: Data
}

protocol CodexTransport: Sendable {
    func send(_ request: URLRequest, limit: Int, eventStream: Bool) async throws -> CodexHTTPReply
}

/// A completed response is the only stream event allowed to become scan evidence.
struct CodexEventDecoder {
    private var line = Data()
    private var event = Data()
    private var total = 0
    private var responseID: String?
    private var completedItems: [Data] = []
    private var itemIDs = Set<String>()
    #if DEBUG
    private var loggedTypes = Set<String>()
    #endif
    private let limit: Int
    init(limit: Int = 1_048_576) { self.limit = limit }

    mutating func append(_ byte: UInt8) throws -> Data? {
        total += 1
        guard total <= limit, line.count < 131_072 else { throw NativeCodexError.invalidResponse }
        if byte != 10 { line.append(byte); return nil }
        if line.last == 13 { line.removeLast() }
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty {
            defer { event.removeAll(keepingCapacity: true) }
            guard !event.isEmpty else { return nil }
            if event == Data("[DONE]".utf8) { throw NativeCodexError.invalidResponse }
            guard let object = try JSONSerialization.jsonObject(with: event) as? [String: Any],
                  let type = object["type"] as? String else { throw NativeCodexError.invalidResponse }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--native-codex-check"), loggedTypes.insert(type).inserted {
                let safe = type.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") }.prefix(64)
                print("Native Codex event=\(safe)")
            }
            #endif
            switch type {
            case "response.created":
                guard let response = object["response"] as? [String: Any], let id = response["id"] as? String,
                      !id.isEmpty, responseID == nil else { throw NativeCodexError.invalidResponse }
                responseID = id
                return nil
            case "response.output_item.done":
                guard let item = object["item"] as? [String: Any], let kind = item["type"] as? String else {
                    throw NativeCodexError.invalidResponse
                }
                if kind == "reasoning" { return nil }
                guard kind == "message", item["role"] as? String == "assistant", completedItems.count < 16,
                      item["status"] == nil || item["status"] as? String == "completed" else { throw NativeCodexError.invalidResponse }
                if let id = item["id"] as? String {
                    guard itemIDs.insert(id).inserted else { throw NativeCodexError.invalidResponse }
                }
                completedItems.append(try JSONSerialization.data(withJSONObject: item))
                return nil
            case "response.completed":
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--native-codex-check") {
                    let response = object["response"] as? [String: Any]
                    print("Native Codex completed status=\(response?["status"] as? String ?? "missing") outputCount=\((response?["output"] as? [Any])?.count ?? -1)")
                }
                #endif
                guard var response = object["response"] as? [String: Any],
                      response["status"] == nil || response["status"] as? String == "completed",
                      response["error"] == nil || response["error"] is NSNull else { throw NativeCodexError.invalidResponse }
                if let responseID, response["id"] as? String != responseID { throw NativeCodexError.invalidResponse }
                // Codex can send only ID/usage in this terminal event. Its output is carried by
                // output_item.done events, as in the upstream Codex SSE client and fixtures.
                if (response["output"] as? [Any])?.isEmpty ?? true {
                    guard !completedItems.isEmpty, let id = response["id"] as? String, !id.isEmpty else {
                        throw NativeCodexError.invalidResponse
                    }
                    response["output"] = try completedItems.map { try JSONSerialization.jsonObject(with: $0) }
                }
                response["status"] = "completed"
                return try JSONSerialization.data(withJSONObject: response)
            case "error", "response.failed", "response.incomplete":
                let response = object["response"] as? [String: Any]
                let error = (object["error"] as? [String: Any]) ?? (response?["error"] as? [String: Any])
                let code = error?["code"] as? String ?? object["code"] as? String
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--native-codex-check") {
                    let safe = (code ?? "missing").filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }.prefix(64)
                    print("Native Codex stream failure event=\(type) code=\(safe)")
                }
                #endif
                switch code {
                case "usage_limit_reached", "rate_limit_exceeded", "insufficient_quota": throw NativeCodexError.limited
                case "model_not_found", "unsupported_model": throw NativeCodexError.modelUnavailable
                default: throw NativeCodexError.invalidResponse
                }
            default: return nil
            }
        }
        if line.starts(with: Data("data:".utf8)) {
            var value = line.dropFirst(5)
            if value.first == 32 { value = value.dropFirst() }
            if !event.isEmpty { event.append(10) }
            event.append(contentsOf: value)
        }
        return nil
    }
}

final class CodexURLTransport: CodexTransport {
    private let session: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 25
        session = URLSession(configuration: config, delegate: CodexNoRedirects(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    func send(_ request: URLRequest, limit: Int, eventStream: Bool) async throws -> CodexHTTPReply {
        guard request.url?.scheme == "https", let host = request.url?.host,
              ["auth.openai.com", "chatgpt.com"].contains(host) else { throw NativeCodexError.invalidResponse }
        let (bytes, response) = try await session.bytes(for: request)
        // Cancel just this stream after its terminal event; keep the TLS/HTTP connection pool warm.
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else { throw NativeCodexError.invalidResponse }
        #if DEBUG
        // Fixed endpoint paths and status only. Never log bodies, codes, tokens or headers.
        print("Native Codex HTTP \(request.httpMethod ?? "GET") \(host)\(request.url?.path ?? "") status=\(response.statusCode) mime=\(response.mimeType ?? "missing")")
        #endif
        let streaming = eventStream && (200..<300).contains(response.statusCode)
        if streaming {
            // The Codex endpoint can omit Content-Type (verified on iOS). The bounded SSE
            // parser and terminal event validate the payload; an HTML/JSON body cannot pass.
            guard response.mimeType == nil || response.mimeType == "text/event-stream" else { throw NativeCodexError.invalidResponse }
            var decoder = CodexEventDecoder(limit: limit)
            for try await byte in bytes {
                try Task.checkCancellation()
                if let completed = try decoder.append(byte) {
                    return CodexHTTPReply(status: response.statusCode, data: completed)
                }
            }
            throw NativeCodexError.invalidResponse
        }
        var data = Data()
        let bound = (200..<300).contains(response.statusCode) ? limit : min(limit, 65_536)
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < bound else { throw NativeCodexError.invalidResponse }
            data.append(byte)
        }
        return CodexHTTPReply(status: response.statusCode, data: data)
    }
}

private final class CodexNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
