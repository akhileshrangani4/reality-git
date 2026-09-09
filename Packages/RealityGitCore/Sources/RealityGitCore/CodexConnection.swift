import Foundation

public struct ScanModel: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }

    /// Fail closed when a runtime omits capabilities. Scanning always uses low effort.
    public static func compatible(id: String, name: String, modalities: [String], efforts: [String], hidden: Bool) -> ScanModel? {
        guard !hidden, modalities.contains("image"), efforts.contains("low"), !id.isEmpty else { return nil }
        return ScanModel(id: id, name: name)
    }
}

public struct CodexAccountStatus: Codable, Sendable {
    public let signedIn: Bool
    public let models: [ScanModel]
    public init(signedIn: Bool, models: [ScanModel]) { self.signedIn = signedIn; self.models = models }
}

public struct CodexLogin: Codable, Sendable {
    public let loginID: String
    public let verificationURL: URL
    public let userCode: String
    public init(loginID: String, verificationURL: URL, userCode: String) {
        self.loginID = loginID; self.verificationURL = verificationURL; self.userCode = userCode
    }
}

/// This is a companion pairing credential, never an OpenAI or ChatGPT token.
public struct CompanionConnection: Codable, Equatable, Sendable {
    public let endpoint: URL
    public let token: String
    public init?(link: String) {
        guard let parts = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "realitygit", parts.host == "connect", parts.user == nil, parts.password == nil,
              parts.path.isEmpty, parts.port == nil, parts.queryItems?.count == 1,
              parts.queryItems?.first?.name == "address", let address = parts.queryItems?.first?.value,
              let endpoint = AssistantPolicy.localEndpoint(address),
              let token = parts.fragment, token.count == 64,
              token.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        self.endpoint = endpoint; self.token = token
    }
    public var link: String {
        var parts = URLComponents()
        parts.scheme = "realitygit"; parts.host = "connect"
        parts.queryItems = [URLQueryItem(name: "address", value: endpoint.absoluteString)]
        parts.fragment = token
        return parts.string!
    }
}
