#if canImport(Libtailscale)
import Libtailscale
import XCTest
@testable import AwgScale

private final class NativeResponse: NSObject, LibtailscaleLocalAPIResponseProtocol {
    var closes = 0
    var reads = 0
    var readError: Error?
    func statusCode() -> Int { 202 }
    func bodyBytes() throws -> Data {
        reads += 1
        if let readError { throw readError }
        return Data("reply".utf8)
    }
    func close() throws { closes += 1 }
}

private final class NativeBackend: NSObject, LibtailscaleApplicationProtocol {
    let response = NativeResponse()
    var requests = 0
    var uploads = 0
    func callLocalAPI(_ timeoutMillis: Int, method: String?, endpoint: String?, body: (any LibtailscaleInputStreamProtocol)?) throws -> any LibtailscaleLocalAPIResponseProtocol {
        requests += 1
        return response
    }
    func callLocalAPIMultipart(_ timeoutMillis: Int, method: String?, endpoint: String?, parts: (any LibtailscaleFilePartsProtocol)?) throws -> any LibtailscaleLocalAPIResponseProtocol {
        uploads += 1
        return response
    }
    func injectInboundPacket(_ packet: Data?) throws {}
    func networkChanged() {}
    func notifyPolicyChanged() {}
    func rebindUnderlay(_ why: String?) {}
    func setPacketCallback(_ cb: (any LibtailscalePacketCallbackProtocol)?) {}
    func stop() {}
    func watchNotifications(_ mask: Int, cb: (any LibtailscaleNotificationCallbackProtocol)?) -> (any LibtailscaleNotificationManagerProtocol)? { nil }
}

final class GoBridgeRequestTests: XCTestCase {
    func testExplicitBackendOwnsRequestAndDiscardedResponseIsClosed() async throws {
        let backend = NativeBackend()
        let owner = GoBackendReference(application: backend)
        let response = try await GoBridge.callLocalAPI(timeoutMillis: 1000, method: "PATCH", endpoint: "/test", readBody: false, backend: owner)
        XCTAssertEqual(response.statusCode, 202)
        XCTAssertEqual(backend.requests, 1)
        XCTAssertEqual(backend.response.reads, 0)
        XCTAssertEqual(backend.response.closes, 1)
    }

    func testUnavailableCapturedBackendCannotFallBackToCurrentBackend() async {
        do {
            _ = try await GoBridge.callLocalAPI(timeoutMillis: 1000, method: "PATCH", endpoint: "/test", backend: GoBackendReference(application: nil))
            XCTFail("An unavailable owner must not issue work to a replacement backend")
        } catch GoBridgeError.startFailed {
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testResponseReadErrorStillClosesNativeResponse() async {
        let backend = NativeBackend()
        backend.response.readError = NSError(domain: "read", code: 42)
        do {
            _ = try await GoBridge.callLocalAPI(timeoutMillis: 1000, method: "GET", endpoint: "/test", backend: GoBackendReference(application: backend))
            XCTFail("Body read failure was lost")
        } catch {
            XCTAssertEqual((error as NSError).code, 42)
        }
        XCTAssertEqual(backend.response.closes, 1)
    }

    func testFileAndMultipartRequestsKeepTheirBackendAndCloseResponses() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("file".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let backend = NativeBackend()
        let owner = GoBackendReference(application: backend)
        _ = try await GoBridge.callLocalAPI(timeoutMillis: 1000, method: "POST", endpoint: "/test", bodyFileURL: url, readBody: false, backend: owner)
        _ = try await GoBridge.callTaildropFilePut(timeoutMillis: 1000, peerID: "peer", fileURL: url, transferID: "transfer", readBody: false, backend: owner)
        XCTAssertEqual(backend.requests, 1)
        XCTAssertEqual(backend.uploads, 1)
        XCTAssertEqual(backend.response.reads, 0)
        XCTAssertEqual(backend.response.closes, 2)
    }
}
#endif
