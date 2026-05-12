import XCTest
@testable import Tailscale

final class LocalAPITests: XCTestCase {
    private struct Sample: Codable, Equatable {
        let value: String
    }

    func testDecodedBodyReturnsModel() throws {
        let data = try JSONEncoder().encode(Sample(value: "ok"))
        let response = IPCResponse.success(statusCode: 200, body: data)

        let decoded = try response.decodedBody(Sample.self, endpoint: "/localapi/v0/test")

        XCTAssertEqual(decoded, Sample(value: "ok"))
    }

    func testRequireSuccessIncludesErrorBodyPreview() {
        let response = IPCResponse.success(statusCode: 409, body: Data("peer unavailable".utf8))

        XCTAssertThrowsError(try response.requireSuccess(endpoint: "/localapi/v0/test")) { error in
            XCTAssertTrue(error.localizedDescription.contains("HTTP 409"))
            XCTAssertTrue(error.localizedDescription.contains("peer unavailable"))
        }
    }

    func testBodyDataRejectsInvalidBase64() {
        let response = IPCResponse(statusCode: 200, bodyBase64: "not base64", error: nil)

        XCTAssertThrowsError(try response.bodyData(endpoint: "/localapi/v0/test")) { error in
            XCTAssertTrue(error.localizedDescription.contains("invalid response body"))
        }
    }
}