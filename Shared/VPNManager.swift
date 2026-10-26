import Foundation
import NetworkExtension

extension NEVPNStatus {
    /// A tunnel is only *fully stopped* when it is disconnected or invalid.
    /// `.disconnecting` is a transient state and must not be treated as stopped:
    /// a new tunnel owner must never be started while the previous one is still
    /// tearing down.
    var isFullyStopped: Bool {
        self == .disconnected || self == .invalid
    }
}

/// Manages the VPN tunnel connection via NEVPNManager.
///
/// This is the main App's interface to control the Packet Tunnel Extension.
/// The Extension runs in a separate process — communication uses:
/// - NEVPNManager for start/stop
/// - NETunnelProviderSession.sendProviderMessage for IPC
/// - App Group UserDefaults for shared state
/// - Darwin Notifications for change signals
@MainActor
class VPNManager: ObservableObject {
    @Published var vpnStatus: NEVPNStatus = .invalid
    @Published var lastError: String?

    var isTunnelActive: Bool {
        vpnStatus == .connected || vpnStatus == .connecting || vpnStatus == .reasserting
    }

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?
    private var needsConfigurationInstall = false

    init() {
        Task {
            await loadManager()
        }
    }

    deinit {
        if let observer = statusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Manager Lifecycle

    /// Load or create the VPN configuration.
    func loadManager() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            if let existing = managers.first(where: isAwgScaleManager) {
                manager = existing
                let protocolChanged = configureTunnelProtocol(existing)
                needsConfigurationInstall = !existing.isEnabled || protocolChanged
                observeStatus()
                vpnStatus = existing.connection.status
                if protocolChanged {
                    try await saveProtocolConfigurationRepair(restartIfActive: isTunnelActive)
                }
            } else {
                manager = createManager()
                needsConfigurationInstall = true
                observeStatus()
                vpnStatus = manager?.connection.status ?? .invalid
            }
        } catch {
            NSLog("Failed to load VPN managers: \(error)")
        }
    }

    func refreshStatus() async -> NEVPNStatus {
        if manager == nil {
            await loadManager()
        } else if let manager = manager {
            do {
                try await manager.loadFromPreferences()
                let protocolChanged = configureTunnelProtocol(manager)
                needsConfigurationInstall = !manager.isEnabled || protocolChanged
                observeStatus()
                vpnStatus = manager.connection.status
                if protocolChanged {
                    try await saveProtocolConfigurationRepair(restartIfActive: isTunnelActive)
                }
            } catch {
                NSLog("Failed to refresh VPN manager: \(error)")
                self.manager = nil
                needsConfigurationInstall = true
                await loadManager()
            }
        }

        vpnStatus = manager?.connection.status ?? .invalid
        return vpnStatus
    }

    func requiresConfigurationInstall() async -> Bool {
        if manager == nil {
            await loadManager()
        }
        return needsConfigurationInstall || manager?.isEnabled != true
    }

    @discardableResult
    func updateStatusFromConnection() -> NEVPNStatus {
        let status = manager?.connection.status ?? vpnStatus
        vpnStatus = status
        return status
    }

    private func isAwgScaleManager(_ manager: NETunnelProviderManager) -> Bool {
        guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else { return false }
        return proto.providerBundleIdentifier == IPCConstants.packetTunnelBundleID
    }

    private func createManager() -> NETunnelProviderManager {
        let manager = NETunnelProviderManager()
        manager.localizedDescription = "AwgScale"

        let proto = NETunnelProviderProtocol()
        configureTunnelProtocol(proto)
        manager.protocolConfiguration = proto

        manager.isEnabled = true
        return manager
    }

    @discardableResult
    private func configureTunnelProtocol(_ manager: NETunnelProviderManager) -> Bool {
        guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else { return false }
        return configureTunnelProtocol(proto)
    }

    @discardableResult
    private func configureTunnelProtocol(_ proto: NETunnelProviderProtocol) -> Bool {
        var changed = false
        if proto.providerBundleIdentifier != IPCConstants.packetTunnelBundleID {
            proto.providerBundleIdentifier = IPCConstants.packetTunnelBundleID
            changed = true
        }
        if proto.serverAddress != "AwgScale" {
            proto.serverAddress = "AwgScale"
            changed = true
        }
        if proto.enforceRoutes {
            proto.enforceRoutes = false
            changed = true
        }
        if proto.includeAllNetworks {
            proto.includeAllNetworks = false
            changed = true
        }
        if proto.excludeLocalNetworks {
            proto.excludeLocalNetworks = false
            changed = true
        }
        return changed
    }

    private func saveProtocolConfigurationRepair(restartIfActive: Bool) async throws {
        guard let manager = manager else {
            throw VPNError.noManager
        }

        let shouldRestart = restartIfActive && isTunnelActive
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        needsConfigurationInstall = !manager.isEnabled
        observeStatus()
        vpnStatus = manager.connection.status

        if shouldRestart {
            try await restartTunnelAfterConfigurationChange()
        }
    }

    private func restartTunnelAfterConfigurationChange() async throws {
        guard let manager = manager else {
            throw VPNError.noManager
        }

        manager.connection.stopVPNTunnel()
        try await waitUntilTunnelStopped()
        guard manager.isEnabled else { return }
        try Task.checkCancellation()
        try manager.connection.startVPNTunnel()
        updateStatusFromConnection()
    }

    /// A completed stop is required before another owner may open backend state.
    func waitUntilTunnelStopped(timeout: TimeInterval = 6) async throws {
        try await waitForVPNStopped(timeout: timeout) { self.updateStatusFromConnection() }
    }

    /// Save VPN configuration. This will trigger the system VPN permission dialog on first use.
    func installVPNConfiguration() async throws {
        guard let manager = manager else {
            throw VPNError.noManager
        }
        manager.isEnabled = true
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        needsConfigurationInstall = false
        observeStatus()
        vpnStatus = manager.connection.status
    }

    // MARK: - Connect / Disconnect

    func connect() {
        Task {
            do {
                try await connectTunnel()
            } catch {
                lastError = error.localizedDescription
                NSLog("Failed to start VPN: \(error)")
            }
        }
    }

    func connectTunnel() async throws {
        lastError = nil

        await loadManager()

        let shouldInstallConfiguration = needsConfigurationInstall || manager?.isEnabled != true
        let shouldRestartAfterConfigurationInstall = shouldInstallConfiguration && isTunnelActive
        if shouldInstallConfiguration {
            try await installVPNConfiguration()
        }

        if shouldRestartAfterConfigurationInstall {
            try await restartTunnelAfterConfigurationChange()
            return
        }

        if updateStatusFromConnection() == .disconnecting {
            try await waitUntilTunnelStopped()
        }
        try Task.checkCancellation()
        switch updateStatusFromConnection() {
        case .connected:
            return
        case .connecting, .reasserting:
            if !shouldInstallConfiguration { return }
        default:
            break
        }
        try await startVPNTunnelAndWaitForProgress()
    }

    func disconnect() {
        manager?.connection.stopVPNTunnel()
        updateStatusFromConnection()
    }

    func resetAfterPermissionModeChange() async throws {
        manager?.connection.stopVPNTunnel()
        try await waitUntilTunnelStopped()
        manager = nil
        needsConfigurationInstall = true
        await loadManager()
    }

    // MARK: - IPC: App → Extension

    /// Send a raw message to the Packet Tunnel Extension and receive a response.
    func sendMessage(_ data: Data, timeoutSeconds: TimeInterval = 15) async throws -> Data? {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            throw VPNError.noSession
        }
        return try await waitForProviderReply(timeoutSeconds: timeoutSeconds) { reply in
            try session.sendProviderMessage(data, responseHandler: reply)
        }
    }

    /// Send an IPC request to the Extension and decode the response.
    func sendIPCRequest(_ request: IPCRequest) async throws -> IPCResponse {
        let requestData = try JSONEncoder().encode(request)
        let requestTimeout = TimeInterval(request.timeoutMillis ?? 30000) / 1000.0
        let maxTransportTimeout: TimeInterval = request.command == .callLocalAPIWithSharedFile ? 900 : 65
        let transportTimeout = min(max(requestTimeout + 2, 3), maxTransportTimeout)
        guard let responseData = try await sendMessage(requestData, timeoutSeconds: transportTimeout) else {
            return IPCResponse.failure("No response from Extension")
        }
        return try JSONDecoder().decode(IPCResponse.self, from: responseData)
    }

    /// Call a LocalAPI endpoint through the Extension.
    func callLocalAPI(method: String, endpoint: String, body: Data? = nil, timeout: Int = 30000, readBody: Bool = true) async throws -> IPCResponse {
        let request = IPCRequest(
            command: .callLocalAPI,
            method: method,
            endpoint: endpoint,
            bodyBase64: body?.base64EncodedString(),
            timeoutMillis: timeout,
            readBody: readBody
        )
        return try await sendIPCRequest(request)
    }

    func callLocalAPIWithFileBody(method: String, endpoint: String, fileURL: URL, transferID: String? = nil, timeout: Int = 600000, readBody: Bool = false) async throws -> IPCResponse {
        let (relativePath, cleanupURL) = try prepareSharedUploadFile(fileURL)
        defer { try? FileManager.default.removeItem(at: cleanupURL) }

        let request = IPCRequest(
            command: .callLocalAPIWithSharedFile,
            method: method,
            endpoint: endpoint,
            bodyFileRelativePath: relativePath,
            bodyFileTransferID: transferID,
            timeoutMillis: timeout,
            readBody: readBody
        )
        return try await sendIPCRequest(request)
    }

    private func prepareSharedUploadFile(_ sourceURL: URL) throws -> (relativePath: String, cleanupURL: URL) {
        guard let containerURL = sharedContainerURL else {
            throw VPNError.sharedContainerUnavailable
        }

        let uploadRootName = "taildrop-uploads"
        let uploadID = UUID().uuidString
        let fileName = sourceURL.lastPathComponent.isEmpty ? "file" : sourceURL.lastPathComponent
        let uploadDirectory = containerURL
            .appendingPathComponent(uploadRootName, isDirectory: true)
            .appendingPathComponent(uploadID, isDirectory: true)
        let destinationURL = uploadDirectory.appendingPathComponent(fileName, isDirectory: false)

        try FileManager.default.createDirectory(at: uploadDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return ("\(uploadRootName)/\(uploadID)/\(fileName)", uploadDirectory)
    }

    /// Trigger interactive login via the Extension.
    func startLoginInteractive() async throws -> IPCResponse {
        let request = IPCRequest(command: .startLoginInteractive)
        return try await sendIPCRequest(request)
    }

    /// Tell the extension that a user-requested stop is about to happen so it can
    /// suppress final tunnel-settings churn while iOS tears the provider down.
    func prepareToDisconnect() async {
        let request = IPCRequest(command: .prepareToStop)
        do {
            _ = try await sendIPCRequest(request)
        } catch {
            NSLog("Failed to prepare PacketTunnel for stop: \(error)")
        }
    }

    // MARK: - Status Observation

    private func observeStatus() {
        if let observer = statusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: manager?.connection,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.vpnStatus = self?.manager?.connection.status ?? .invalid
            }
        }
    }

    private func startVPNTunnelAndWaitForProgress() async throws {
        guard let manager = manager else {
            throw VPNError.noManager
        }

        do {
            try manager.connection.startVPNTunnel()
        } catch {
            let status = updateStatusFromConnection()
            if status == .connecting || status == .reasserting {
                NSLog("VPN start requested while status is \(status.rawValue); continuing without retry: \(error)")
                return
            }
            throw error
        }

        updateStatusFromConnection()
        let status = await waitForTunnelStartProgress(timeoutSeconds: 10)
        if status == .connecting || status == .reasserting {
            NSLog("VPN start remained in status \(status.rawValue); continuing to backend readiness check")
        }
    }

    private func waitForTunnelStartProgress(timeoutSeconds: TimeInterval) async -> NEVPNStatus {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let status = updateStatusFromConnection()
            switch status {
            case .connected, .disconnected, .disconnecting, .invalid:
                return status
            case .connecting, .reasserting:
                try? await Task.sleep(nanoseconds: 250_000_000)
            @unknown default:
                return status
            }
        }
        return updateStatusFromConnection()
    }
}

/// NETunnelProviderSession has no cancellation API. End the caller's wait and
/// release its timer on cancellation, reply or error; ignore a late callback.
@MainActor
func waitForProviderReply(
    timeoutSeconds: TimeInterval,
    send: (@escaping (Data?) -> Void) throws -> Void
) async throws -> Data? {
    let reply = ProviderReply()
    return try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            guard reply.install(continuation, timeout: timeoutSeconds) else { return }
            do {
                try send { reply.finish(.success($0)) }
            } catch {
                reply.finish(.failure(error))
            }
        }
    } onCancel: {
        reply.finish(.failure(CancellationError()))
    }
}

private final class ProviderReply {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Error>?
    private var earlyResult: Result<Data?, Error>?
    private var finished = false
    private var timer: DispatchSourceTimer?

    func install(_ continuation: CheckedContinuation<Data?, Error>, timeout: TimeInterval) -> Bool {
        lock.lock()
        if let result = earlyResult {
            earlyResult = nil
            lock.unlock()
            continuation.resume(with: result)
            return false
        }
        self.continuation = continuation
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in
            self?.finish(.failure(VPNError.ipcTimeout))
        }
        self.timer = timer
        timer.resume()
        lock.unlock()
        return true
    }

    func finish(_ result: Result<Data?, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil { earlyResult = result }
        timer?.cancel()
        timer = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

enum VPNError: Error, LocalizedError {
    case noSession
    case noManager
    case backendNotReady(String)
    case ipcTimeout
    case stopTimeout
    case sharedContainerUnavailable

    var errorDescription: String? {
        switch self {
        case .noSession: return "No active VPN session"
        case .noManager: return "VPN manager not configured"
        case .backendNotReady(let message): return "VPN backend did not become ready: \(message)"
        case .ipcTimeout: return "Timed out waiting for Packet Tunnel IPC response"
        case .stopTimeout: return "The previous VPN tunnel has not stopped yet. Please try again."
        case .sharedContainerUnavailable: return "Shared app container is unavailable"
        }
    }
}

/// Poll the real connection state with a monotonic deadline. Cancellation and a
/// slow teardown must never be interpreted as permission to start a new owner.
@MainActor
func waitForVPNStopped(
    timeout: TimeInterval = 6,
    pollIntervalNanoseconds: UInt64 = 200_000_000,
    status: () -> NEVPNStatus
) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while true {
        try Task.checkCancellation()
        if status().isFullyStopped { return }
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw VPNError.stopTimeout
        }
        try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
    }
}
