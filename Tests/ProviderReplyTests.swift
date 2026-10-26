import XCTest
@testable import AwgScale

@MainActor
final class ProviderReplyTests: XCTestCase {
    func testSynchronousReplyWinsOverDuplicateCallbackAndSendError() async throws {
        let result = try await waitForProviderReply(timeoutSeconds: 900) { reply in
            reply(Data("reply".utf8))
            reply(nil)
            throw VPNError.noSession
        }
        XCTAssertEqual(result, Data("reply".utf8))
    }

    func testSendErrorReturnsWithoutWaitingForTimeout() async {
        do {
            _ = try await waitForProviderReply(timeoutSeconds: 900) { _ in throw VPNError.noSession }
            XCTFail("Send error was lost")
        } catch VPNError.noSession {
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testCancellationBeforeSendDoesNotSendMessage() async {
        var sends = 0
        let task = Task {
            try await waitForProviderReply(timeoutSeconds: 900) { _ in sends += 1 }
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled request succeeded")
        } catch is CancellationError {
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(sends, 0)
    }

    func testCancellationWhileWaitingIgnoresLateSuccess() async {
        var callback: ((Data?) -> Void)?
        let sent = expectation(description: "sent")
        let cancelled = expectation(description: "cancelled before callback")
        let task = Task {
            defer { cancelled.fulfill() }
            return try await waitForProviderReply(timeoutSeconds: 900) { reply in
                callback = reply
                sent.fulfill()
            }
        }
        await fulfillment(of: [sent], timeout: 1)
        task.cancel()
        await fulfillment(of: [cancelled], timeout: 1)
        callback?(Data("late".utf8))
        do {
            _ = try await task.value
            XCTFail("Late success revived cancelled request")
        } catch is CancellationError {
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testTimeoutIgnoresLateCallback() async {
        var callback: ((Data?) -> Void)?
        do {
            _ = try await waitForProviderReply(timeoutSeconds: 0.01) { callback = $0 }
            XCTFail("Missing callback did not time out")
        } catch VPNError.ipcTimeout {
        } catch { XCTFail("Unexpected error: \(error)") }
        callback?(Data("late".utf8))
    }
}
