import Foundation

enum CodexFailure: Error { case unavailable, timeout, invalidResponse, signedOut, unsupportedModel, busy, turnFailed, limited, loginUnavailable }

/// One private stdio connection. Pending requests and early turn notifications share a lock.
/// No raw protocol payload (which can contain account data and camera images) is logged.
final class CodexRPC: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var nextID = 0
    private var closed = false
    private var buffer = Data()
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var turns: [String: CheckedContinuation<Data, Error>] = [:]
    private var completed: [String: Data] = [:]
    private var messages: [String: [String]] = [:]

    init(directory: URL, executable: String = ProcessInfo.processInfo.environment["CODEX_BINARY"] ?? "codex", disabledMCP: [String] = []) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var arguments = [executable, "--disable", "shell_tool", "--disable", "unified_exec",
            "--disable", "apps", "--disable", "plugins", "--disable", "image_generation",
            "--disable", "view_image", "--disable", "in_app_browser", "--disable", "skill_search",
            "-c", "web_search=\"disabled\"", "-c", "project_doc_max_bytes=0"]
        // Empty config tables merge with user tables; disable each inherited server explicitly.
        for name in disabledMCP {
            guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else {
                throw CodexFailure.unavailable
            }
            arguments += ["-c", "mcp_servers.\(name).enabled=false"]
        }
        process.arguments = arguments + ["app-server", "--stdio"]
        process.currentDirectoryURL = directory
        // A ChatGPT account must supply inference. Do not accidentally fall back to environment API billing.
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "OPENAI_API_KEY")
        environment.removeValue(forKey: "CODEX_API_KEY")
        process.environment = environment
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { self?.close(); return }
            self?.receive(data)
        }
    }

    deinit { close() }

    func request(_ method: String, params: Data, timeout: Double = 12) async throws -> Data {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard !closed else { lock.unlock(); continuation.resume(throwing: CodexFailure.unavailable); return }
            nextID += 1; let id = nextID
            do {
                let object = try JSONSerialization.jsonObject(with: params)
                var data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": object])
                data.append(10)
                pending[id] = continuation
                try input.fileHandleForWriting.write(contentsOf: data)
                lock.unlock()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.expire(id)
                }
            } catch {
                pending.removeValue(forKey: id)
                lock.unlock(); continuation.resume(throwing: error)
            }
        }
    }

    func notify(_ method: String) throws {
        try lock.withLock {
            guard !closed else { throw CodexFailure.unavailable }
            var data = try JSONSerialization.data(withJSONObject: ["method": method, "params": [:]])
            data.append(10); try input.fileHandleForWriting.write(contentsOf: data)
        }
    }

    func waitForTurn(_ threadID: String, timeout: Double = 22) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let data = completed.removeValue(forKey: threadID) {
                lock.unlock(); continuation.resume(returning: data); return
            }
            guard !closed, turns[threadID] == nil else {
                lock.unlock(); continuation.resume(throwing: CodexFailure.unavailable); return
            }
            turns[threadID] = continuation
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                let waiting = self?.lock.withLock { self?.turns[threadID] != nil } ?? false
                // Kill the physical request before the worker can release its slot.
                if waiting { self?.close(error: CodexFailure.timeout) }
            }
        }
    }

    private func expire(_ id: Int) {
        let continuation = lock.withLock { pending.removeValue(forKey: id) }
        continuation?.resume(throwing: CodexFailure.timeout)
        if continuation != nil { close(error: CodexFailure.timeout) }
    }

    func close(error: Error = CodexFailure.unavailable) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let requests = Array(pending.values) + Array(turns.values)
        pending.removeAll(); turns.removeAll(); completed.removeAll(); messages.removeAll()
        lock.unlock()
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        requests.forEach { $0.resume(throwing: error) }
    }

    private func receive(_ data: Data) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        buffer.append(data)
        guard buffer.count <= 8 * 1024 * 1024 else { lock.unlock(); close(); return }
        var replies: [(CheckedContinuation<Data, Error>, Result<Data, Error>)] = []
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: end)
            buffer.removeSubrange(...end)
            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if message["method"] == nil, let id = message["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
                if let result = message["result"], let data = try? JSONSerialization.data(withJSONObject: result, options: .fragmentsAllowed) {
                    replies.append((continuation, .success(data)))
                } else { replies.append((continuation, .failure(CodexFailure.invalidResponse))) }
            } else if let id = message["id"] {
                // This perception service never approves tools or interactive requests.
                if var data = try? JSONSerialization.data(withJSONObject: ["id": id,
                    "error": ["code": -32601, "message": "Interactive tools are unavailable in this scanner"]]) {
                    data.append(10); try? input.fileHandleForWriting.write(contentsOf: data)
                }
            } else if let method = message["method"] as? String,
                      let params = message["params"] as? [String: Any], let thread = params["threadId"] as? String {
                if method == "item/completed", let item = params["item"] as? [String: Any],
                   item["type"] as? String == "agentMessage", let text = item["text"] as? String,
                   item["phase"] as? String != "commentary", text.utf8.count <= 64_000 {
                    if messages[thread, default: []].count < 4 { messages[thread, default: []].append(text) }
                }
                if method == "turn/completed", let turn = params["turn"] as? [String: Any] {
                    let texts = messages.removeValue(forKey: thread) ?? []
                    let errorCode = (turn["error"] as? [String: Any])?["codexErrorInfo"] as? String ?? "other"
                    if let data = try? JSONSerialization.data(withJSONObject: ["status": turn["status"] ?? "failed", "texts": texts, "errorCode": errorCode]) {
                        if let continuation = turns.removeValue(forKey: thread) { replies.append((continuation, .success(data))) }
                        else if completed.count < 4 { completed[thread] = data }
                    }
                }
            }
        }
        lock.unlock()
        replies.forEach { $0.0.resume(with: $0.1) }
    }
}
