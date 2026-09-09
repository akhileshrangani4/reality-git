import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import RealityGitCore
import Security
import Vapor

extension CodexAccountStatus: @retroactive Content {}
extension CodexLogin: @retroactive Content {}

struct CompanionAuth: AsyncMiddleware {
    let token: String
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard Self.matches(request.headers.bearerAuthorization?.token, token) else { throw Abort(.unauthorized) }
        let response = try await next.respond(to: request)
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        return response
    }
    static func matches(_ supplied: String?, _ expected: String) -> Bool {
        guard let supplied else { return false }
        let a = Array(supplied.utf8), b = Array(expected.utf8)
        guard a.count == 64, b.count == 64 else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

func configureCompanion(_ app: Application, runtime: CodexRuntime, token: String) {
    let worker = AstraWorker(provider: { try await runtime.observe($0, reference: $1) })
    app.routes.defaultMaxBodySize = "4mb"
    app.get("health") { _ in HealthResponse(status: "ok") }
    let paired = app.grouped(CompanionAuth(token: token))
    paired.get("account") { _ async throws -> CodexAccountStatus in
        do { return try await runtime.account() } catch { throw companionError(error) }
    }
    paired.post("login") { _ async throws -> CodexLogin in
        do { return try await runtime.startLogin() } catch { throw companionError(error) }
    }
    paired.post("login", "cancel") { _ async throws -> HTTPStatus in
        do { try await runtime.cancelLogin(); return .noContent } catch { throw companionError(error) }
    }
    paired.on(.POST, "observe", body: .collect(maxSize: "4mb")) { request async throws -> DetectionReply in
        let frame: FrameRequest
        do { frame = try request.content.decode(FrameRequest.self) }
        catch { throw Abort(.badRequest, reason: "Invalid camera frame") }
        do { return try await worker.observe(frame) }
        catch let error as ObservationError { throw error.abort }
        catch { throw companionError(error) }
    }
}

private func companionError(_ error: Error) -> Abort {
    switch error as? CodexFailure {
    case .signedOut: return Abort(.forbidden, reason: "Sign in to ChatGPT")
    case .unsupportedModel: return Abort(.conflict, reason: "Choose an available image model")
    case .busy: return Abort(.conflict, reason: "Account is already connected")
    case .loginUnavailable: return Abort(.unprocessableEntity, reason: "Sign in using codex login on your Mac, then reconnect.")
    case .timeout: return Abort(.gatewayTimeout, reason: "The model took too long")
    case .limited: return Abort(.tooManyRequests, reason: "Check your Codex allowance and retry.")
    case .turnFailed: return Abort(.badGateway, reason: "Codex could not complete this scan. Try again.")
    default: return Abort(.serviceUnavailable, reason: "Codex is unavailable. Check the companion on your Mac.")
    }
}

enum CompanionPairing {
    static func stateDirectory() throws -> URL {
        let directory = ProcessInfo.processInfo.environment["REALITY_GIT_STATE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".reality-git")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory
    }

    static func token(in directory: URL) throws -> String {
        let file = directory.appendingPathComponent("pairing-token")
        if FileManager.default.fileExists(atPath: file.path) {
            let value = try String(contentsOf: file, encoding: .utf8)
            guard value.count == 64, value.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw CodexFailure.invalidResponse }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return value
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw CodexFailure.unavailable }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try token.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return token
    }

    static func writeCard(address: String, token: String, directory: URL) throws -> URL {
        var components = URLComponents()
        components.scheme = "realitygit"; components.host = "connect"
        components.queryItems = [URLQueryItem(name: "address", value: address)]; components.fragment = token
        guard let link = components.string, CompanionConnection(link: link) != nil else { throw CodexFailure.invalidResponse }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(link.utf8); filter.correctionLevel = "M"
        guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 7, y: 7)),
              let cg = CIContext().createCGImage(image, from: image.extent) else { throw CodexFailure.invalidResponse }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil) else { throw CodexFailure.invalidResponse }
        CGImageDestinationAddImage(destination, cg, nil)
        guard CGImageDestinationFinalize(destination) else { throw CodexFailure.invalidResponse }
        let html = """
        <!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Connect Reality Git</title><style>body{font:17px -apple-system,BlinkMacSystemFont,sans-serif;background:#f5f5f7;color:#1d1d1f;max-width:420px;margin:8vh auto;padding:24px;text-align:center}h1{font-size:32px;letter-spacing:-1px}p{line-height:1.5;color:#6e6e73}img{width:260px;max-width:80%;border:20px solid white;border-radius:24px}button{font:inherit;padding:14px 24px;border:0;border-radius:24px;background:#1d1d1f;color:white;cursor:pointer}small{display:block;margin-top:24px;line-height:1.5;color:#6e6e73}</style>
        <h1>Connect your iPhone.</h1><p>Scan this code with the iPhone Camera to open Reality Git.</p>
        <img alt="Reality Git pairing code" src="data:image/png;base64,\((png as Data).base64EncodedString())">
        <p><button id="copy">Copy connection link</button></p>
        <small>Keep both devices on the same trusted Wi-Fi.<br>Your ChatGPT sign-in stays with Codex on this Mac.<br>Anyone with this pairing code can use this companion.</small>
        <script>document.getElementById('copy').onclick=async function(){await navigator.clipboard.writeText('\(link)');this.textContent='Copied';};</script></html>
        """
        let file = directory.appendingPathComponent("connect.html")
        try html.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        // Useful for AirDrop and the debug device provisioning command. Never logged.
        let linkFile = directory.appendingPathComponent("connection.txt")
        try link.write(to: linkFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: linkFile.path)
        return file
    }
}
