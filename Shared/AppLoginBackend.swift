import Foundation

@MainActor
final class AppLoginBackend {
    struct Runtime {
        var start: () throws -> Void
        var stop: () -> Void
        var callLocalAPI: @MainActor (String, String, Data?, Int, Bool) async throws -> IPCResponse
        var watchNotifications: (@escaping (Data) -> Void) -> NotificationHandle?
        var stopNotifications: (NotificationHandle) -> Void

        static var live: Runtime {
            Runtime(
                start: {
                    let containerURL = sharedContainerURL ?? fallbackContainerURL()
                    let dataDirURL = containerURL.appendingPathComponent("awgscale", isDirectory: true)
                    let directFileRootURL = containerURL.appendingPathComponent("taildrop", isDirectory: true)
                    try FileManager.default.createDirectory(at: dataDirURL, withIntermediateDirectories: true)
                    try FileManager.default.createDirectory(at: directFileRootURL, withIntermediateDirectories: true)
                    guard GoBridge.start(
                        dataDir: dataDirURL.path,
                        directFileRoot: directFileRootURL.path,
                        hwAttestation: false,
                        appLogin: true
                    ) else {
                        throw AppLoginBackendError.startFailed
                    }
                },
                stop: { GoBridge.stopBackend() },
                callLocalAPI: { method, endpoint, body, timeout, readBody in
                    let backend = GoBridge.captureBackend()
                    let response = try await Task.detached(priority: .userInitiated) {
                        try await GoBridge.callLocalAPI(
                            timeoutMillis: timeout,
                            method: method,
                            endpoint: endpoint,
                            body: body,
                            readBody: readBody,
                            backend: backend
                        )
                    }.value
                    return IPCResponse.success(statusCode: response.statusCode, body: response.body)
                },
                watchNotifications: { callback in
                    GoBridge.watchNotifications(mask: NotifyWatchOpt.defaultMask, callback: callback)
                },
                stopNotifications: { GoBridge.stopNotifications($0) }
            )
        }
    }

    private let runtime: Runtime
    private var notifyHandle: NotificationHandle?
    private var running = false
    private var generation: UInt64 = 0
    private var startTask: Task<Void, Error>?

    init(runtime: Runtime? = nil) {
        self.runtime = runtime ?? .live
    }

    var isRunning: Bool { running }

    func start(onNotify: @escaping (Data) -> Void) async throws {
        if let startTask {
            let attempt = generation
            try await startTask.value
            try requireCurrentAttempt(attempt)
            return
        }
        if running { return }
        generation &+= 1
        let attempt = generation
        let task = Task { @MainActor in
            do {
                try requireCurrentAttempt(attempt)
                try runtime.start()
                running = true
                let status = try await callLocalAPI(method: "GET", endpoint: "/localapi/v0/status", timeout: 30000)
                try status.requireSuccess(endpoint: "/localapi/v0/status")
                try requireCurrentAttempt(attempt)
                guard let handle = runtime.watchNotifications({ [weak self] data in
                    Task { @MainActor in
                        guard let self, self.generation == attempt, self.running else { return }
                        onNotify(data)
                    }
                }) else {
                    throw AppLoginBackendError.notificationsFailed
                }
                notifyHandle = handle
            } catch {
                // An older start may finish after stop and a new start. Its
                // completion must never stop or subscribe to that new backend.
                if generation == attempt {
                    stop()
                }
                throw error
            }
        }
        startTask = task
        defer {
            if generation == attempt {
                startTask = nil
            }
        }
        try await task.value
        try requireCurrentAttempt(attempt)
    }

    private func requireCurrentAttempt(_ attempt: UInt64) throws {
        guard generation == attempt, !Task.isCancelled else {
            throw CancellationError()
        }
    }

    func stop() {
        generation &+= 1
        startTask?.cancel()
        startTask = nil
        if let handle = notifyHandle {
            runtime.stopNotifications(handle)
            notifyHandle = nil
        }
        if running {
            runtime.stop()
            running = false
        }
    }

    func callLocalAPI(method: String, endpoint: String, body: Data? = nil, timeout: Int = 30000, readBody: Bool = true) async throws -> IPCResponse {
        try Task.checkCancellation()
        guard running else { throw AppLoginBackendError.notRunning }
        let attempt = generation
        let response = try await runtime.callLocalAPI(method, endpoint, body, timeout, readBody)
        // An in-flight request may finish after a stop or profile/backend
        // restart. Its old state must not be published into the new session.
        try requireCurrentAttempt(attempt)
        return response
    }

    func startLoginInteractive() async throws -> IPCResponse {
        try await callLocalAPI(method: "POST", endpoint: "/localapi/v0/login-interactive", readBody: false)
    }
}

private func fallbackContainerURL() -> URL {
    let urls = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
    return urls[0].appendingPathComponent("AwgScaleLogin", isDirectory: true)
}

enum AppLoginBackendError: Error, LocalizedError {
    case startFailed
    case notificationsFailed
    case notRunning

    var errorDescription: String? {
        switch self {
        case .startFailed:
            return "App login backend failed to start"
        case .notificationsFailed:
            return "App login backend did not start notifications"
        case .notRunning:
            return "App login backend is not running"
        }
    }
}
