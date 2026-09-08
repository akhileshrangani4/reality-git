import Vapor

@main
enum RealityGitServerMain {
    static func main() async throws {
        let lan = CommandLine.arguments.contains("--lan")
        var arguments = CommandLine.arguments
        arguments.removeAll { $0 == "--lan" }
        let environment = try Environment.detect(arguments: arguments)
        let app = try await Application.make(environment)
        app.http.server.configuration.hostname = lan ? "0.0.0.0" : "127.0.0.1"
        app.http.server.configuration.port = 8080
        do {
            try configure(app)
            try await app.execute()
            try await app.asyncShutdown()
        } catch {
            try await app.asyncShutdown()
            throw error
        }
    }
}
