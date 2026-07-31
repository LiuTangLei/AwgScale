import XCTest
@testable import AwgScale

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

    func testTaildropDeleteEscapesOnePathSegment() async throws {
        var capturedEndpoint = ""
        let client = LocalAPIClient { _, endpoint, _, _, _ in
            capturedEndpoint = endpoint
            return IPCResponse.success(statusCode: 204)
        }

        try await client.deleteTaildropFile(name: "a/b #?.txt")

        XCTAssertEqual(capturedEndpoint, "/localapi/v0/files/a%2Fb%20%23%3F.txt")
    }

    func testProfileIDsAreEscapedAsPathSegments() async throws {
        var capturedEndpoints: [String] = []
        let client = LocalAPIClient { _, endpoint, _, _, _ in
            capturedEndpoints.append(endpoint)
            return IPCResponse.success(statusCode: 204)
        }

        try await client.switchProfile(id: "profile/one")
        try await client.deleteProfile(id: "profile#two")

        XCTAssertEqual(capturedEndpoints, [
            "/localapi/v0/profiles/profile%2Fone",
            "/localapi/v0/profiles/profile%23two",
        ])
    }

    func testProfileCreationAndAuthKeyUseOfficialLocalAPIContracts() async throws {
        var requests: [(method: String, endpoint: String, body: Data?)] = []
        let client = LocalAPIClient { method, endpoint, body, _, _ in
            requests.append((method, endpoint, body))
            return IPCResponse.success(statusCode: 204)
        }

        try await client.newProfile()
        try await client.login(authKey: "tskey-auth-test")

        XCTAssertEqual(requests.map(\.method), ["PUT", "POST"])
        XCTAssertEqual(requests.map(\.endpoint), [
            "/localapi/v0/profiles/",
            "/localapi/v0/start",
        ])
        let startBody = try XCTUnwrap(requests.last?.body)
        let startOptions = try XCTUnwrap(
            JSONSerialization.jsonObject(with: startBody) as? [String: String]
        )
        XCTAssertEqual(startOptions, ["AuthKey": "tskey-auth-test"])
    }

    func testBugReportUsesRequiredPOSTMethod() async throws {
        var capturedMethod = ""
        var capturedEndpoint = ""
        let client = LocalAPIClient { method, endpoint, _, _, _ in
            capturedMethod = method
            capturedEndpoint = endpoint
            return IPCResponse.success(statusCode: 200, body: Data("BUG-test".utf8))
        }

        let marker = try await client.bugReportLogs()
        XCTAssertEqual(marker, "BUG-test")
        XCTAssertEqual(capturedMethod, "POST")
        XCTAssertEqual(capturedEndpoint, "/localapi/v0/bugreport")
    }
}

final class TaildropFileSafetyTests: XCTestCase {
    func testAPIFileNamesMustBeLocalBasenames() {
        XCTAssertTrue(TaildropFile.isSafeLocalName("report.txt"))
        XCTAssertTrue(TaildropFile.isSafeLocalName("space name.txt"))
        XCTAssertFalse(TaildropFile.isSafeLocalName(""))
        XCTAssertFalse(TaildropFile.isSafeLocalName("."))
        XCTAssertFalse(TaildropFile.isSafeLocalName(".."))
        XCTAssertFalse(TaildropFile.isSafeLocalName("../secret.txt"))
        XCTAssertFalse(TaildropFile.isSafeLocalName("folder/file.txt"))
        XCTAssertFalse(TaildropFile.isSafeLocalName("folder\\file.txt"))
    }

    func testSharedInputNamesAreReducedToSafeBasenames() {
        XCTAssertEqual(
            safeSharedFileName(suggestedName: "../private/report.txt", fallbackName: "fallback"),
            "report.txt"
        )
        XCTAssertEqual(
            safeSharedFileName(suggestedName: "..", fallbackName: "fallback.txt"),
            "fallback.txt"
        )
        XCTAssertEqual(
            safeSharedFileName(suggestedName: ".", fallbackName: ".."),
            "file"
        )
        XCTAssertEqual(
            safeSharedFileName(suggestedName: "folder\\secret.txt", fallbackName: "fallback"),
            "folder-secret.txt"
        )
        XCTAssertEqual(
            safeSharedFileName(suggestedName: "/", fallbackName: "fallback.txt"),
            "fallback.txt"
        )
        XCTAssertEqual(
            safeSharedFileName(suggestedName: "\u{0}", fallbackName: "fallback.txt"),
            "fallback.txt"
        )
    }
}

final class TerminalScreenBufferTests: XCTestCase {
    func testValidatedTCPPortRejectsOutOfRangeValues() {
        XCTAssertEqual(validatedTCPPort("22"), 22)
        XCTAssertEqual(validatedTCPPort(" 443 "), 443)
        XCTAssertNil(validatedTCPPort("0"))
        XCTAssertNil(validatedTCPPort("-1"))
        XCTAssertNil(validatedTCPPort("65536"))
        XCTAssertNil(validatedTCPPort("ssh"))
    }

    func testConsumesBracketedPasteModeSequences() {
        var terminal = TerminalScreenBuffer()

        terminal.append(Data("\u{1B}[?2004hroot@host:~# ".utf8))
        terminal.append(Data("\u{1B}[?2004l".utf8))

        XCTAssertEqual(terminal.renderedText, "root@host:~#")
    }

    func testCarriageReturnAndEraseLineReplaceHistoryPrompt() {
        var terminal = TerminalScreenBuffer()

        terminal.append(Data("root@host:~# docker ps".utf8))
        terminal.append(Data("\r\u{1B}[Kroot@host:~# ls".utf8))

        XCTAssertEqual(terminal.renderedText, "root@host:~# ls")
    }

    func testBackspaceEchoUpdatesCurrentLine() {
        var terminal = TerminalScreenBuffer()

        terminal.append(Data("root@host:~# catt\u{8} \u{8}".utf8))

        XCTAssertEqual(terminal.renderedText, "root@host:~# cat")
    }

    func testSplitUTF8ScalarIsDecodedOnceComplete() {
        var terminal = TerminalScreenBuffer()
        let bytes = Array("好".utf8)

        terminal.append(Data(bytes.prefix(2)))
        XCTAssertEqual(terminal.renderedText, "")

        terminal.append(Data(bytes.suffix(1)))
        XCTAssertEqual(terminal.renderedText, "好")
    }

    func testRenderedTextWithCursorUsesBufferedCursorPosition() {
        var terminal = TerminalScreenBuffer()

        terminal.append(Data("abc\u{1B}[D".utf8))

        XCTAssertEqual(terminal.renderedText, "abc")
        XCTAssertEqual(terminal.renderedTextWithCursor, "ab█")
    }

    func testCursorVisibilitySequencesHideAndShowCursor() {
        var terminal = TerminalScreenBuffer()

        terminal.append(Data("abc\u{1B}[?25l".utf8))
        XCTAssertEqual(terminal.renderedTextWithCursor, "abc")

        terminal.append(Data("\u{1B}[?25h".utf8))
        XCTAssertEqual(terminal.renderedTextWithCursor, "abc█")
    }
}
