import XCTest
@testable import RealityGitCore

final class CodexConnectionTests: XCTestCase {
    func testOnlyImageModelsWithLowEffortAreOffered() {
        XCTAssertNotNil(ScanModel.compatible(id: "astra", name: "Astra", modalities: ["text", "image"], efforts: ["low", "high"], hidden: false))
        XCTAssertNil(ScanModel.compatible(id: "spark", name: "Spark", modalities: ["text"], efforts: ["low"], hidden: false))
        XCTAssertNil(ScanModel.compatible(id: "unknown", name: "Unknown", modalities: [], efforts: ["low"], hidden: false))
        XCTAssertNil(ScanModel.compatible(id: "slow", name: "Slow", modalities: ["image"], efforts: ["high"], hidden: false))
        XCTAssertNil(ScanModel.compatible(id: "hidden", name: "Hidden", modalities: ["image"], efforts: ["low"], hidden: true))
    }

    func testPairingRequiresPrivateEndpointAndFullTokenAndRoundTrips() throws {
        let token = String(repeating: "ab", count: 32)
        let link = "realitygit://connect?address=http://mac.local:8080#" + token
        let connection = try XCTUnwrap(CompanionConnection(link: link))
        XCTAssertEqual(connection.endpoint.absoluteString, "http://mac.local:8080")
        XCTAssertEqual(CompanionConnection(link: connection.link), connection)
        for bad in ["https://connect?address=http://mac.local:8080#" + token,
                    "realitygit://connect?address=http://example.com:8080#" + token,
                    "realitygit://connect?address=http://mac.local:8080/observe#" + token,
                    "realitygit://connect?address=http://mac.local:8080#short",
                    "realitygit://connect?address=http://mac.local:8080&address=http://other.local#" + token,
                    "realitygit://connect?address=http://user@mac.local:8080#" + token] {
            XCTAssertNil(CompanionConnection(link: bad))
        }
    }
}
