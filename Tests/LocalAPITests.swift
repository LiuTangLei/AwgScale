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
}

final class TerminalScreenBufferTests: XCTestCase {
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