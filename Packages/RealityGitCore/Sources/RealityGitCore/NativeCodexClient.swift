import Foundation

/// Native Swift port of Codex's device login and Responses connection. No subprocess or companion.
/// Protocol source and Apache-2.0 attribution: docs/native-codex.md and ThirdPartyNotices.txt.
public actor NativeCodexClient {
    // Public OAuth application ID published in OpenAI's Apache-2.0 Codex source, not a secret.
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let issuer = "https://auth.openai.com"
    private static let backend = "https://chatgpt.com/backend-api/codex"
    private let store: any CodexCredentialStore
    private let transport: any CodexTransport
    private let now: @Sendable () -> Date
    private var loaded = false
    private var tokens: Tokens?
    private var revision = UUID()
    private var challenge: Challenge?
    private var loginRequestActive = false
    private var pollActive = false
    private var refresh: (id: UUID, task: Task<Tokens, Error>)?
    private var availableModels: [ScanModel] = []
    private var referenceImage: (key: ObservationKey, url: String)?

    private struct Tokens: Codable, Sendable {
        let accessToken: String
        let refreshToken: String
        let accountID: String
        let expiresAt: Date
    }
    private struct Challenge: Sendable {
        let login: CodexLogin
        let deviceID: String
        let interval: TimeInterval
        let deadline: Date
        var nextPoll: Date
    }
    public init(store: any CodexCredentialStore = CodexKeychainStore()) {
        self.store = store; self.transport = CodexURLTransport(); self.now = { Date() }
    }
    init(store: any CodexCredentialStore, transport: any CodexTransport, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.transport = transport; self.now = now
    }

    public func hasCredentials() throws -> Bool {
        try restore()
        return tokens != nil
    }

    public func account() async throws -> CodexAccountStatus {
        try restore()
        guard tokens != nil else { return CodexAccountStatus(signedIn: false, models: []) }
        let revision = revision
        let request = Self.request(Self.backend + "/models?client_version=1.0.0")
        let data = try await authorized(request, limit: 8_388_608)
        try check(revision)
        availableModels = try Self.models(data)
        return CodexAccountStatus(signedIn: true, models: availableModels)
    }

    public func beginLogin() async throws -> CodexLogin {
        try restore()
        if let challenge, now() < challenge.deadline { return challenge.login }
        guard tokens == nil, !loginRequestActive else { throw NativeCodexError.unavailable }
        loginRequestActive = true
        let revision = revision, started = now()
        defer { loginRequestActive = false }
        let request = try Self.jsonRequest(Self.issuer + "/api/accounts/deviceauth/usercode", body: ["client_id": Self.clientID])
        let reply = try await transport.send(request, limit: 65_536, eventStream: false)
        try check(revision)
        if reply.status == 404 { throw NativeCodexError.loginUnavailable }
        try Self.requireSuccess(reply)
        guard let body = try JSONSerialization.jsonObject(with: reply.data) as? [String: Any],
              let deviceID = body["device_auth_id"] as? String, !deviceID.isEmpty,
              let code = (body["user_code"] ?? body["usercode"]) as? String,
              !code.isEmpty, code.count <= 64 else { throw NativeCodexError.invalidResponse }
        let interval = (body["interval"] as? String).flatMap(Double.init) ?? body["interval"] as? Double ?? 5
        guard interval.isFinite, interval >= 0, interval <= 900 else { throw NativeCodexError.invalidResponse }
        let login = CodexLogin(loginID: UUID().uuidString,
            verificationURL: URL(string: Self.issuer + "/codex/device")!, userCode: code)
        challenge = Challenge(login: login, deviceID: deviceID, interval: max(3, interval),
            deadline: started.addingTimeInterval(900), nextPoll: now())
        return login
    }

    /// Polling is throttled on the actor, including after foregrounding the app.
    public func pollLogin() async throws -> Bool {
        guard var challenge else { return tokens != nil }
        guard now() < challenge.deadline else { self.challenge = nil; throw NativeCodexError.loginExpired }
        guard !pollActive, now() >= challenge.nextPoll else { return false }
        challenge.nextPoll = now().addingTimeInterval(challenge.interval)
        self.challenge = challenge; pollActive = true
        let revision = revision
        defer { pollActive = false }
        let request = try Self.jsonRequest(Self.issuer + "/api/accounts/deviceauth/token",
            body: ["device_auth_id": challenge.deviceID, "user_code": challenge.login.userCode])
        let reply = try await transport.send(request, limit: 65_536, eventStream: false)
        try check(revision)
        guard self.challenge?.login.loginID == challenge.login.loginID else { throw CancellationError() }
        if reply.status == 403 || reply.status == 404 { return false }
        try Self.requireSuccess(reply)
        struct Authorization: Decodable { let authorization_code: String; let code_verifier: String }
        let code = try JSONDecoder().decode(Authorization.self, from: reply.data)
        guard !code.authorization_code.isEmpty, !code.code_verifier.isEmpty else { throw NativeCodexError.invalidResponse }
        var exchange = Self.request(Self.issuer + "/oauth/token", method: "POST")
        exchange.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        exchange.httpBody = Self.form([
            "grant_type": "authorization_code", "code": code.authorization_code,
            "redirect_uri": Self.issuer + "/deviceauth/callback", "client_id": Self.clientID,
            "code_verifier": code.code_verifier
        ])
        // This authorization code can only be exchanged once. A failed exchange needs a new sign-in.
        do {
            let result = try await transport.send(exchange, limit: 65_536, eventStream: false)
            try check(revision)
            guard self.challenge?.login.loginID == challenge.login.loginID else { throw CancellationError() }
            try Self.requireSuccess(result)
            let tokens = try Self.decodeTokens(result.data, previous: nil, now: now())
            try persist(tokens)
            self.challenge = nil
            return true
        } catch {
            if self.challenge?.login.loginID == challenge.login.loginID { self.challenge = nil }
            throw error
        }
    }

    public func cancelLogin() {
        revision = UUID(); challenge = nil
    }

    public func signOut() throws {
        // Invalidate in-flight work even if Keychain is temporarily locked. Never resurrect a login.
        revision = UUID(); challenge = nil; tokens = nil; availableModels = []; referenceImage = nil
        refresh?.task.cancel(); refresh = nil; loaded = true
        try store.remove()
    }

    public func perceive(_ frame: FrameRequest, reference: FrameRequest?) async throws -> AstraPerception.Observation {
        guard let model = frame.modelID, availableModels.contains(where: { $0.id == model }) else {
            throw NativeCodexError.modelUnavailable
        }
        let revision = revision
        var request = Self.request(Self.backend + "/responses", method: "POST")
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let reference {
            if referenceImage?.key != reference.key {
                referenceImage = (reference.key, "data:image/jpeg;base64," + (try AstraPerception.crop(reference)).base64EncodedString())
            }
        } else { referenceImage = nil }
        request.httpBody = try Self.observationBody(frame, reference: reference, referenceImageURL: referenceImage?.url)
        let data = try await authorized(request, limit: 1_048_576, eventStream: true)
        try check(revision)
        return try AstraPerception.parse(data)
    }

    static func observationBody(_ frame: FrameRequest, reference: FrameRequest?, referenceImageURL: String? = nil) throws -> Data {
        var body = try AstraPerception.body(frame, reference: reference, referenceImageURL: referenceImageURL)
        body["model"] = frame.modelID
        body.removeValue(forKey: "max_output_tokens") // Not a field in Codex's Responses request.
        body["instructions"] = "You are Reality Git's camera perception assistant. Follow the supplied object-location task and return only its structured result."
        body["stream"] = true
        body["tools"] = [String]()
        body["tool_choice"] = "none"
        body["parallel_tool_calls"] = false
        body["include"] = [String]()
        // Codex's supported routing hint. Reference bytes and the prompt prefix stay identical.
        // This does not cache answers or promise a provider cache hit for changing camera frames.
        body["prompt_cache_key"] = "realitygit-v1-" + frame.key.sessionID.uuidString + "-" + frame.key.objectID.uuidString
        let data = try JSONSerialization.data(withJSONObject: body)
        guard data.count <= 6_000_000 else { throw NativeCodexError.invalidResponse }
        return data
    }

    private func restore() throws {
        guard !loaded else { return }
        if let data = try store.load() { tokens = try JSONDecoder().decode(Tokens.self, from: data) }
        loaded = true
    }

    private func persist(_ tokens: Tokens) throws {
        do { try store.save(JSONEncoder().encode(tokens)) }
        catch {
            self.tokens = nil; availableModels = []
            // A refresh token may have rotated. Do not reuse a stale disk copy on the next launch.
            try? store.remove()
            throw NativeCodexError.storage
        }
        self.tokens = tokens; loaded = true
    }

    private func credential(rejectedAccess: String? = nil) async throws -> Tokens {
        try restore()
        guard let previous = tokens else { throw NativeCodexError.signedOut }
        if previous.expiresAt > now().addingTimeInterval(60), rejectedAccess != previous.accessToken { return previous }
        let revision = revision
        let operation: (id: UUID, task: Task<Tokens, Error>)
        if let refresh { operation = refresh }
        else {
            let request = try Self.jsonRequest(Self.issuer + "/oauth/token", body: [
                "client_id": Self.clientID, "grant_type": "refresh_token", "refresh_token": previous.refreshToken
            ])
            let transport = transport, now = now
            operation = (UUID(), Task {
                let reply = try await transport.send(request, limit: 65_536, eventStream: false)
                if reply.status == 400 {
                    let body = try? JSONSerialization.jsonObject(with: reply.data) as? [String: Any]
                    let code = body?["error"] as? String ?? (body?["error"] as? [String: Any])?["code"] as? String
                    if ["invalid_grant", "refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated"].contains(code ?? "") {
                        throw NativeCodexError.signedOut
                    }
                }
                try Self.requireSuccess(reply)
                return try Self.decodeTokens(reply.data, previous: previous, now: now())
            })
            refresh = operation
        }
        do {
            let value = try await operation.task.value
            // A cancelled scan still has to save a rotated refresh token. Account changes must not.
            guard self.revision == revision else { throw CancellationError() }
            if refresh?.id == operation.id {
                refresh = nil
                try persist(value)
            }
            try Task.checkCancellation()
            guard let tokens else { throw NativeCodexError.signedOut }
            return tokens
        } catch {
            if self.revision == revision, refresh?.id == operation.id {
                refresh = nil
                if error as? NativeCodexError == .signedOut { try signOut() }
            }
            throw error
        }
    }

    private func authorized(_ original: URLRequest, limit: Int, eventStream: Bool = false) async throws -> Data {
        let revision = revision
        var rejected: String?
        for attempt in 0..<2 {
            let tokens = try await credential(rejectedAccess: rejected)
            try check(revision)
            var request = original
            request.setValue("Bearer " + tokens.accessToken, forHTTPHeaderField: "Authorization")
            request.setValue(tokens.accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
            let reply = try await transport.send(request, limit: limit, eventStream: eventStream)
            try check(revision)
            if reply.status == 401 {
                if attempt == 0 { rejected = tokens.accessToken; continue }
                try signOut(); throw NativeCodexError.signedOut
            }
            try Self.requireSuccess(reply)
            return reply.data
        }
        throw NativeCodexError.signedOut
    }

    private func check(_ expected: UUID) throws {
        try Task.checkCancellation()
        guard revision == expected else { throw CancellationError() }
    }

    private static func request(_ url: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method; request.timeoutInterval = 20
        request.setValue("RealityGit/1.0 (native Codex connection)", forHTTPHeaderField: "User-Agent")
        request.setValue("reality_git_ios", forHTTPHeaderField: "originator")
        return request
    }
    private static func jsonRequest(_ url: String, body: [String: String]) throws -> URLRequest {
        var request = request(url, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
    static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return Data(fields.sorted(by: { $0.key < $1.key }).map {
            $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
    }
    private static func requireSuccess(_ reply: CodexHTTPReply) throws {
        switch reply.status {
        case 200..<300: return
        case 401: throw NativeCodexError.signedOut
        case 403: throw NativeCodexError.accessDenied
        case 404: throw NativeCodexError.modelUnavailable
        case 429: throw NativeCodexError.limited
        default: throw NativeCodexError.unavailable
        }
    }

    private static func decodeTokens(_ data: Data, previous: Tokens?, now: Date) throws -> Tokens {
        struct Response: Decodable {
            let access_token: String
            let refresh_token: String?
            let id_token: String?
            let expires_in: Double?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        let access = claims(response.access_token), identity = response.id_token.flatMap(claims)
        let auth = (identity?["https://api.openai.com/auth"] ?? access?["https://api.openai.com/auth"]) as? [String: Any]
        guard let account = auth?["chatgpt_account_id"] as? String ?? previous?.accountID,
              !account.isEmpty, account.count <= 128,
              account.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }),
              let refresh = response.refresh_token ?? previous?.refreshToken, !refresh.isEmpty,
              !response.access_token.isEmpty else { throw NativeCodexError.invalidResponse }
        if let previous, account != previous.accountID { throw NativeCodexError.signedOut }
        let expiration = (access?["exp"] as? Double).map { Date(timeIntervalSince1970: $0) }
            ?? response.expires_in.map { now.addingTimeInterval($0) }
        guard let expiration, expiration.timeIntervalSince1970.isFinite, expiration > now else { throw NativeCodexError.invalidResponse }
        return Tokens(accessToken: response.access_token, refreshToken: refresh, accountID: account, expiresAt: expiration)
    }
    /// Only reads routing/expiry metadata from tokens returned over TLS. The backend validates authorization.
    private static func claims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var value = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let data = Data(base64Encoded: value) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    static func models(_ data: Data) throws -> [ScanModel] {
        struct Catalog: Decodable {
            struct Model: Decodable {
                struct Effort: Decodable { let effort: String }
                let slug: String; let display_name: String; let visibility: String
                let input_modalities: [String]?
                let supported_reasoning_levels: [Effort]
            }
            let models: [Model]
        }
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        var seen = Set<String>()
        return catalog.models.compactMap { model in
            guard seen.insert(model.slug).inserted else { return nil }
            return ScanModel.compatible(id: model.slug, name: model.display_name,
                modalities: model.input_modalities ?? [], efforts: model.supported_reasoning_levels.map(\.effort),
                hidden: model.visibility != "list")
        }
    }
}
