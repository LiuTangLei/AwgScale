import Foundation

@MainActor
final class AppLoginBackend {
    private var notifyHandle: NotificationHandle?
    private var running = false

    var isRunning: Bool { running }

    func start(onNotify: @escaping (Data) -> Void) async throws {
        if running { return }

        let containerURL = sharedContainerURL ?? fallbackContainerURL()

        let dataDirURL = containerURL.appendingPathComponent("tailscale", isDirectory: true)
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

        running = true

        do {
            _ = try await callLocalAPI(method: "GET", endpoint: "/localapi/v0/status", timeout: 30000)
        } catch {
            stop()
            throw error
        }

        guard let handle = GoBridge.watchNotifications(mask: NotifyWatchOpt.defaultMask, callback: { data in
            Task { @MainActor in
                onNotify(data)
            }
        }) else {
            stop()
            throw AppLoginBackendError.notificationsFailed
        }
        notifyHandle = handle
    }

    func stop() {
        if let handle = notifyHandle {
            GoBridge.stopNotifications(handle)
            notifyHandle = nil
        }
        if running {
            GoBridge.stopBackend()
            running = false
        }
    }

    func callLocalAPI(method: String, endpoint: String, body: Data? = nil, timeout: Int = 30000, readBody: Bool = true) async throws -> IPCResponse {
        let localResponse = try await Task.detached(priority: .userInitiated) {
            try await GoBridge.callLocalAPI(
                timeoutMillis: timeout,
                method: method,
                endpoint: endpoint,
                body: body,
                readBody: readBody
            )
        }.value

        return IPCResponse.success(statusCode: localResponse.statusCode, body: localResponse.body)
    }

    func startLoginInteractive() async throws -> IPCResponse {
        try await callLocalAPI(method: "POST", endpoint: "/localapi/v0/login-interactive", readBody: false)
    }
}

private func fallbackContainerURL() -> URL {
    let urls = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
    return urls[0].appendingPathComponent("TailscaleLogin", isDirectory: true)
}

enum AppLoginBackendError: Error, LocalizedError {
    case startFailed
    case notificationsFailed

    var errorDescription: String? {
        switch self {
        case .startFailed:
            return "App login backend failed to start"
        case .notificationsFailed:
            return "App login backend did not start notifications"
        }
    }
}
