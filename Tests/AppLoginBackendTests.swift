import Foundation
import XCTest
@testable import AwgScale

private actor LoginBackendResponseGate {
    private var nextID = 0
    private var responses: [Int: CheckedContinuation<IPCResponse, Error>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func response() async throws -> IPCResponse {
        let id = nextID
        nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            responses[id] = continuation
            let ready = waiters.filter { nextID >= $0.0 }
            waiters.removeAll { nextID >= $0.0 }
            ready.forEach { $0.1.resume() }
        }
    }

    func waitForRequests(_ count: Int) async {
        guard nextID < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func complete(_ id: Int, result: Result<IPCResponse, Error> = .success(.success(statusCode: 200))) {
        responses.removeValue(forKey: id)?.resume(with: result)
    }
}

@MainActor
private final class LoginBackendRuntimeHarness {
    let gate = LoginBackendResponseGate()
    var starts = 0
    var stops = 0
    var stoppedNotifications = 0
    var callbacks: [(Data) -> Void] = []

    var runtime: AppLoginBackend.Runtime {
        AppLoginBackend.Runtime(
            start: { self.starts += 1 },
            stop: { self.stops += 1 },
            callLocalAPI: { _, _, _, _, _ in try await self.gate.response() },
            watchNotifications: { callback in
                self.callbacks.append(callback)
                return NotificationHandle()
            },
            stopNotifications: { _ in self.stoppedNotifications += 1 }
        )
    }
}

@MainActor
final class AppLoginBackendTests: XCTestCase {
    func testReadinessHTTPFailureStopsBackendWithoutSubscribing() async throws {
        let harness = LoginBackendRuntimeHarness()
        let backend = AppLoginBackend(runtime: harness.runtime)
        let start = Task { try await backend.start { _ in } }
        await harness.gate.waitForRequests(1)
        await harness.gate.complete(0, result: .success(.success(statusCode: 503)))
        do {
            try await start.value
            XCTFail("HTTP failure must not count as readiness")
        } catch LocalAPIError.unsuccessfulStatus(let code, _, _) {
            XCTAssertEqual(code, 503)
        }
        XCTAssertFalse(backend.isRunning)
        XCTAssertEqual(harness.stops, 1)
        XCTAssertTrue(harness.callbacks.isEmpty)
    }

    func testStoppedBackendRejectsLocalAPIWithoutCallingRuntime() async {
        var requests = 0
        let backend = AppLoginBackend(runtime: .init(
            start: {}, stop: {},
            callLocalAPI: { _, _, _, _, _ in
                requests += 1
                return .success(statusCode: 200)
            },
            watchNotifications: { _ in NotificationHandle() },
            stopNotifications: { _ in }
        ))
        do {
            _ = try await backend.callLocalAPI(method: "GET", endpoint: "/localapi/v0/prefs")
            XCTFail("A stopped backend cannot serve LocalAPI requests")
        } catch AppLoginBackendError.notRunning {
            // A retained client cannot silently issue work to a different owner.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(requests, 0)
    }

    func testInFlightLocalAPIResponseCannotCrossBackendGeneration() async throws {
        let harness = LoginBackendRuntimeHarness()
        let backend = AppLoginBackend(runtime: harness.runtime)
        defer { backend.stop() }
        let firstStart = Task { try await backend.start { _ in } }
        await harness.gate.waitForRequests(1)
        await harness.gate.complete(0)
        try await firstStart.value

        let oldRequest = Task {
            try await backend.callLocalAPI(method: "GET", endpoint: "/localapi/v0/profiles/current")
        }
        await harness.gate.waitForRequests(2)
        backend.stop()
        let secondStart = Task { try await backend.start { _ in } }
        await harness.gate.waitForRequests(3)
        await harness.gate.complete(2)
        try await secondStart.value
        await harness.gate.complete(1)
        do {
            _ = try await oldRequest.value
            XCTFail("The previous session's response must not update the current UI")
        } catch is CancellationError {
            // The current backend remains active, but the old response is stale.
        }
        XCTAssertTrue(backend.isRunning)
        XCTAssertEqual(harness.starts, 2)
        XCTAssertEqual(harness.stops, 1)
    }

    func testCancelledLocalAPIRequestRejectsLateSuccess() async throws {
        let harness = LoginBackendRuntimeHarness()
        let backend = AppLoginBackend(runtime: harness.runtime)
        defer { backend.stop() }
        let start = Task { try await backend.start { _ in } }
        await harness.gate.waitForRequests(1)
        await harness.gate.complete(0)
        try await start.value
        let request = Task {
            try await backend.callLocalAPI(method: "GET", endpoint: "/localapi/v0/prefs")
        }
        await harness.gate.waitForRequests(2)
        request.cancel()
        await harness.gate.complete(1)
        do {
            _ = try await request.value
            XCTFail("Cancelled requests must not deliver late state")
        } catch is CancellationError {
            // The synchronous Go operation can finish after Swift cancellation.
        }
        XCTAssertTrue(backend.isRunning)
    }

    func testConcurrentStartsShareReadiness() async throws {
        let harness = LoginBackendRuntimeHarness()
        let backend = AppLoginBackend(runtime: harness.runtime)
        defer { backend.stop() }
        let first = Task { try await backend.start { _ in } }
        await harness.gate.waitForRequests(1)
        let secondEntered = expectation(description: "second start entered")
        var secondCompleted = false
        let second = Task {
            secondEntered.fulfill()
            try await backend.start { _ in }
            secondCompleted = true
        }
        await fulfillment(of: [secondEntered], timeout: 1)
        XCTAssertFalse(secondCompleted, "a second start must await the shared readiness task")
        XCTAssertEqual(harness.starts, 1)
        await harness.gate.complete(0)
        try await first.value
        try await second.value
        XCTAssertTrue(secondCompleted)
        XCTAssertEqual(harness.callbacks.count, 1)
    }

    func testOldSuccessfulStartCannotSubscribeToNewBackend() async throws {
        let harness = LoginBackendRuntimeHarness()
        let backend = AppLoginBackend(runtime: harness.runtime)
        defer { backend.stop() }
        let old = Task { try await backend.start { _ in } }
        await harness.gate.waitForRequests(1)
        backend.stop()
        let current = Task { try await backend.start { _ in } }
        await harness.gate.waitForRequests(2)
        await harness.gate.complete(1)
        try await current.value
        await harness.gate.complete(0)
        do {
            try await old.value
            XCTFail("superseded start succeeded")
        } catch is CancellationError {
            // The old Go request may complete, but it no longer owns this backend.
        }
        XCTAssertTrue(backend.isRunning)
        XCTAssertEqual(harness.starts, 2)
        XCTAssertEqual(harness.stops, 1)
        XCTAssertEqual(harness.callbacks.count, 1)
    }

    func testOldFailedStartCannotStopNewBackend() async throws {
        let harness = LoginBackendRuntimeHarness()
        let backend = AppLoginBackend(runtime: harness.runtime)
        defer { backend.stop() }
        let old = Task { try await backend.start { _ in } }
        await harness.gate.waitForRequests(1)
        backend.stop()
        let current = Task { try await backend.start { _ in } }
        await harness.gate.waitForRequests(2)
        await harness.gate.complete(1)
        try await current.value
        await harness.gate.complete(0, result: .failure(AppLoginBackendError.startFailed))
        do {
            try await old.value
            XCTFail("failed old start succeeded")
        } catch {
            XCTAssertTrue(error is AppLoginBackendError)
        }
        XCTAssertTrue(backend.isRunning)
        XCTAssertEqual(harness.stops, 1)
        XCTAssertEqual(harness.callbacks.count, 1)
        XCTAssertEqual(harness.stoppedNotifications, 0)
    }

    func testCurrentStartFailureStopsItsBackend() async throws {
        let harness = LoginBackendRuntimeHarness()
        let backend = AppLoginBackend(runtime: harness.runtime)
        let start = Task { try await backend.start { _ in } }
        await harness.gate.waitForRequests(1)
        await harness.gate.complete(0, result: .failure(AppLoginBackendError.startFailed))
        do {
            try await start.value
            XCTFail("failed start succeeded")
        } catch {
            XCTAssertTrue(error is AppLoginBackendError)
        }
        XCTAssertFalse(backend.isRunning)
        XCTAssertEqual(harness.stops, 1)
        XCTAssertTrue(harness.callbacks.isEmpty)
    }

    func testStoppedGenerationCannotDeliverNotifications() async throws {
        let harness = LoginBackendRuntimeHarness()
        let backend = AppLoginBackend(runtime: harness.runtime)
        defer { backend.stop() }
        let staleNotification = expectation(description: "old notification suppressed")
        staleNotification.isInverted = true
        let currentNotification = expectation(description: "current notification delivered")
        let old = Task { try await backend.start { _ in staleNotification.fulfill() } }
        await harness.gate.waitForRequests(1)
        await harness.gate.complete(0)
        try await old.value
        backend.stop()
        let current = Task { try await backend.start { _ in currentNotification.fulfill() } }
        await harness.gate.waitForRequests(2)
        await harness.gate.complete(1)
        try await current.value
        harness.callbacks[0](Data("old".utf8))
        harness.callbacks[1](Data("new".utf8))
        await fulfillment(of: [staleNotification, currentNotification], timeout: 0.1)
        XCTAssertEqual(harness.stoppedNotifications, 1)
    }
}
