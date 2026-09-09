import Foundation
import RealityGitCore

struct AssistantClient: Sendable {
    typealias ClientError = NativeCodexError
    let auth: NativeCodexClient
    private let scanner: NativeScanSession

    init() {
        let auth = NativeCodexClient()
        self.auth = auth
        scanner = NativeScanSession { frame, reference in
            try await auth.perceive(frame, reference: reference)
        }
    }
    func account() async throws -> CodexAccountStatus { try await auth.account() }
    func login() async throws -> CodexLogin { try await auth.beginLogin() }
    func pollLogin() async throws -> Bool { try await auth.pollLogin() }
    func cancelLogin() async { await auth.cancelLogin() }
    func signOut() async throws { try await auth.signOut() }
    func submit(_ frame: FrameRequest) async throws -> DetectionReply { try await scanner.observe(frame) }
}
