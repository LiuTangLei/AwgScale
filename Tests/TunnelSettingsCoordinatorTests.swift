import XCTest
@testable import AwgScale

final class TunnelSettingsCoordinatorTests: XCTestCase {
    private final class SystemSettings {
        private let lock = NSLock()
        private var callbacks: [Int: (Error?) -> Void] = [:]
        private var applied: [Int] = []
        private var published: [Int] = []
        private var failures: [Error] = []
        private var activity: [Bool] = []
        var onApply: ((Int) -> Void)?
        var onPublish: (() -> Void)?

        func coordinator(timeout: TimeInterval = 15,
                         completionQueue: DispatchQueue = .main) -> TunnelSettingsCoordinator<Int> {
            TunnelSettingsCoordinator(timeout: timeout, completionQueue: completionQueue, apply: { [self] value, completion in
                lock.lock()
                applied.append(value)
                callbacks[value] = completion
                lock.unlock()
                onApply?(value)
            }, didApply: { [self] value in
                lock.lock()
                published.append(value)
                lock.unlock()
                onPublish?()
            }, activityChanged: { [self] active in
                lock.lock()
                activity.append(active)
                lock.unlock()
            }, didFail: { [self] error, _ in
                lock.lock()
                failures.append(error)
                lock.unlock()
            })
        }

        func complete(_ value: Int, error: Error? = nil) {
            lock.lock()
            let callback = callbacks[value]
            lock.unlock()
            callback?(error)
        }

        var snapshot: (applied: [Int], published: [Int], failures: [Error], active: Bool?) {
            lock.lock()
            defer { lock.unlock() }
            return (applied, published, failures, activity.last)
        }
    }

    func testCoalescingCompletesReplacedRequestAndAppliesLatest() {
        let system = SystemSettings()
        let first = expectation(description: "first system call")
        let latest = expectation(description: "latest system call")
        system.onApply = { ($0 == 1 ? first : latest).fulfill() }
        let coordinator = system.coordinator()
        let generation = coordinator.begin()
        let completed = expectation(description: "all callers completed once")
        completed.expectedFulfillmentCount = 3
        completed.assertForOverFulfill = true
        coordinator.enqueue(1, generation: generation) { error in
            XCTAssertNil(error)
            completed.fulfill()
        }
        wait(for: [first], timeout: 1)
        coordinator.enqueue(2, generation: generation) { error in
            XCTAssertEqual(error as? TunnelSettingsError, .superseded)
            completed.fulfill()
        }
        coordinator.enqueue(3, generation: generation) { error in
            XCTAssertNil(error)
            completed.fulfill()
        }
        system.complete(1)
        wait(for: [latest], timeout: 1)
        system.complete(3)
        wait(for: [completed], timeout: 1)
        XCTAssertFalse(coordinator.isStopped)
        XCTAssertEqual(system.snapshot.applied, [1, 3])
        XCTAssertEqual(system.snapshot.published, [1, 3])
        XCTAssertEqual(system.snapshot.active, false)
    }

    func testStopCancelsInFlightAndPendingAndIgnoresConcurrentLateCallbacks() {
        let system = SystemSettings()
        let started = expectation(description: "system call")
        system.onApply = { _ in started.fulfill() }
        let coordinator = system.coordinator()
        let generation = coordinator.begin()
        let cancelled = expectation(description: "both requests cancelled once")
        cancelled.expectedFulfillmentCount = 2
        cancelled.assertForOverFulfill = true
        let completion: (Error?) -> Void = { error in
            XCTAssertEqual(error as? TunnelSettingsError, .cancelled)
            cancelled.fulfill()
        }
        coordinator.enqueue(1, generation: generation, completion: completion)
        wait(for: [started], timeout: 1)
        coordinator.enqueue(2, generation: generation, completion: completion)
        coordinator.stop()
        DispatchQueue.concurrentPerform(iterations: 20) { index in
            system.complete(1, error: index.isMultiple(of: 2) ? nil : TunnelSettingsError.timedOut)
        }
        XCTAssertTrue(coordinator.isStopped) // Drain all submitted callbacks.
        wait(for: [cancelled], timeout: 1)
        XCTAssertEqual(system.snapshot.applied, [1])
        XCTAssertTrue(system.snapshot.published.isEmpty)
        XCTAssertTrue(system.snapshot.failures.isEmpty)
        XCTAssertEqual(system.snapshot.active, false)
    }

    func testTimeoutFailsSessionAndCancelsPendingWithoutApplyingStaleSettings() {
        let system = SystemSettings()
        let started = expectation(description: "system call")
        system.onApply = { _ in started.fulfill() }
        let coordinator = system.coordinator(timeout: 0.05)
        let generation = coordinator.begin()
        let timedOut = expectation(description: "timed out")
        let cancelled = expectation(description: "pending cancelled")
        timedOut.assertForOverFulfill = true
        cancelled.assertForOverFulfill = true
        coordinator.enqueue(1, generation: generation) { error in
            XCTAssertEqual(error as? TunnelSettingsError, .timedOut)
            timedOut.fulfill()
        }
        wait(for: [started], timeout: 1)
        coordinator.enqueue(2, generation: generation) { error in
            XCTAssertEqual(error as? TunnelSettingsError, .cancelled)
            cancelled.fulfill()
        }
        wait(for: [timedOut, cancelled], timeout: 1)
        system.complete(1)
        XCTAssertTrue(coordinator.isStopped)
        XCTAssertEqual(system.snapshot.applied, [1])
        XCTAssertTrue(system.snapshot.published.isEmpty)
        XCTAssertEqual(system.snapshot.failures.count, 1)
        XCTAssertEqual(system.snapshot.failures.first as? TunnelSettingsError, .timedOut)
        XCTAssertEqual(system.snapshot.active, false)
    }

    func testSystemErrorFailsOnceAndRejectsFurtherUpdates() {
        let system = SystemSettings()
        let started = expectation(description: "system call")
        system.onApply = { _ in started.fulfill() }
        let coordinator = system.coordinator()
        let generation = coordinator.begin()
        let failed = expectation(description: "original error")
        let rejected = expectation(description: "new update rejected")
        let error = NSError(domain: "NetworkExtension", code: 42)
        coordinator.enqueue(1, generation: generation) { actual in
            XCTAssertEqual(actual as NSError?, error)
            failed.fulfill()
        }
        wait(for: [started], timeout: 1)
        system.complete(1, error: error)
        XCTAssertTrue(coordinator.isStopped)
        coordinator.enqueue(2, generation: generation) { actual in
            XCTAssertEqual(actual as? TunnelSettingsError, .cancelled)
            rejected.fulfill()
        }
        system.complete(1)
        wait(for: [failed, rejected], timeout: 1)
        XCTAssertEqual(system.snapshot.applied, [1])
        XCTAssertEqual(system.snapshot.failures.count, 1)
        XCTAssertTrue(system.snapshot.published.isEmpty)
        XCTAssertEqual(system.snapshot.active, false)
    }

    func testRestartRejectsOldGenerationAndItsLateCompletion() {
        let system = SystemSettings()
        let first = expectation(description: "old system call")
        let second = expectation(description: "new system call")
        system.onApply = { ($0 == 1 ? first : second).fulfill() }
        let coordinator = system.coordinator()
        let oldGeneration = coordinator.begin()
        let oldCancelled = expectation(description: "old caller cancelled")
        let oldUpdateRejected = expectation(description: "old update rejected")
        let newCompleted = expectation(description: "new caller succeeds")
        coordinator.enqueue(1, generation: oldGeneration) { error in
            XCTAssertEqual(error as? TunnelSettingsError, .cancelled)
            oldCancelled.fulfill()
        }
        wait(for: [first], timeout: 1)
        let newGeneration = coordinator.begin()
        coordinator.enqueue(2, generation: newGeneration) { error in
            XCTAssertNil(error)
            newCompleted.fulfill()
        }
        coordinator.enqueue(3, generation: oldGeneration) { error in
            XCTAssertEqual(error as? TunnelSettingsError, .cancelled)
            oldUpdateRejected.fulfill()
        }
        wait(for: [second], timeout: 1)
        system.complete(1, error: TunnelSettingsError.timedOut)
        system.complete(1)
        XCTAssertTrue(coordinator.isActive(newGeneration))
        XCTAssertEqual(system.snapshot.active, true)
        XCTAssertTrue(system.snapshot.published.isEmpty)
        XCTAssertTrue(system.snapshot.failures.isEmpty)
        system.complete(2)
        wait(for: [oldCancelled, oldUpdateRejected, newCompleted], timeout: 1)
        XCTAssertEqual(system.snapshot.applied, [1, 2])
        XCTAssertEqual(system.snapshot.published, [2])
        XCTAssertEqual(system.snapshot.active, false)
    }

    func testSuccessAwaitingDeliveryBecomesCancellationAfterStop() {
        let system = SystemSettings()
        let published = expectation(description: "settings applied")
        system.onPublish = { published.fulfill() }
        let deliveryQueue = DispatchQueue(label: "test.settings.completion")
        deliveryQueue.suspend()
        let coordinator = system.coordinator(completionQueue: deliveryQueue)
        let generation = coordinator.begin()
        let started = expectation(description: "system call")
        system.onApply = { _ in started.fulfill() }
        let completed = expectation(description: "cancelled before delivery")
        coordinator.enqueue(1, generation: generation) { error in
            XCTAssertEqual(error as? TunnelSettingsError, .cancelled)
            completed.fulfill()
        }
        wait(for: [started], timeout: 1)
        system.complete(1)
        wait(for: [published], timeout: 1)
        coordinator.stop()
        deliveryQueue.resume()
        wait(for: [completed], timeout: 1)
        XCTAssertEqual(system.snapshot.active, false)
    }

    func testConcurrentStopAndCompletionFinishCallerExactlyOnce() {
        let system = SystemSettings()
        let started = DispatchSemaphore(value: 0)
        system.onApply = { _ in started.signal() }
        let coordinator = system.coordinator()
        let completed = expectation(description: "one completion per race")
        completed.expectedFulfillmentCount = 25
        completed.assertForOverFulfill = true
        for value in 0..<25 {
            let generation = coordinator.begin()
            coordinator.enqueue(value, generation: generation) { error in
                XCTAssertTrue(error == nil || error as? TunnelSettingsError == .cancelled)
                completed.fulfill()
            }
            XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                if index == 0 { coordinator.stop() }
                else { system.complete(value) }
            }
            XCTAssertTrue(coordinator.isStopped)
            XCTAssertEqual(system.snapshot.active, false)
        }
        wait(for: [completed], timeout: 2)
        XCTAssertTrue(system.snapshot.failures.isEmpty)
    }
}
