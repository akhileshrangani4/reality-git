import Foundation
import RealityGitCore

/// Legacy API adapter; the production companion uses CodexRuntime with the same perception contract.
enum AstraObserver {
    typealias Observation = AstraPerception.Observation
    typealias Provider = AstraPerception.Provider

    static func observe(_ frame: FrameRequest, reference: FrameRequest?) async throws -> Observation {
        try parse(await AstraLabeler.send(body(frame, reference: reference)))
    }

    static func body(_ frame: FrameRequest, reference: FrameRequest?) throws -> [String: Any] {
        try AstraPerception.body(frame, reference: reference)
    }

    static func parse(_ data: Data) throws -> Observation { try AstraPerception.parse(data) }
}
