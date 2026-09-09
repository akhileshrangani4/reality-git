import Vapor

@main
enum RealityGitServerMain {
    static func main() async throws {
        let lan = CommandLine.arguments.contains("--lan")
        var arguments = CommandLine.arguments
        arguments.removeAll { $0 == "--lan" }
        var pairAddress: String?
        if let index = arguments.firstIndex(of: "--pair-address"), arguments.indices.contains(index + 1) {
            pairAddress = arguments[index + 1]
            arguments.removeSubrange(index...index + 1)
        }
        let environment = try Environment.detect(arguments: arguments)
        let app = try await Application.make(environment)
        app.http.server.configuration.hostname = lan ? "0.0.0.0" : "127.0.0.1"
        app.http.server.configuration.port = 8080
        do {
            let directory = try CompanionPairing.stateDirectory()
            let token = try CompanionPairing.token(in: directory)
            let runtimeDirectory = directory.appendingPathComponent("scanner")
            try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            configureCompanion(app, runtime: CodexRuntime(directory: runtimeDirectory), token: token)
            if let pairAddress {
                let card = try CompanionPairing.writeCard(address: pairAddress, token: token, directory: directory)
                app.logger.notice("Pairing card: \(card.path)")
            }
            try await app.execute()
            try await app.asyncShutdown()
        } catch {
            try await app.asyncShutdown()
            throw error
        }
    }
}
