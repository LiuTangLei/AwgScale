import Foundation
import NetworkExtension

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
        await waitForTunnelStopped()
        guard manager.isEnabled else { return }
        try manager.connection.startVPNTunnel()
        updateStatusFromConnection()
    }

    private func waitForTunnelStopped() async {
        for _ in 0..<30 {
            switch updateStatusFromConnection() {
            case .connected, .connecting, .reasserting, .disconnecting:
                try? await Task.sleep(nanoseconds: 200_000_000)
            default:
                return
            }
        }
        updateStatusFromConnection()
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

    func resetAfterPermissionModeChange() async {
        manager?.connection.stopVPNTunnel()
        await waitForTunnelStopped()
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
        return try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var didResume = false

            func resume(_ result: Result<Data?, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !didResume else { return }
                didResume = true
                switch result {
                case .success(let response):
                    continuation.resume(returning: response)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            do {
                try session.sendProviderMessage(data) { response in
                    resume(.success(response))
                }
            } catch {
                resume(.failure(error))
                return
            }

            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                resume(.failure(VPNError.ipcTimeout))
            }
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

enum VPNError: Error, LocalizedError {
    case noSession
    case sendFailed
    case noManager
    case backendNotReady(String)
    case ipcTimeout
    case sharedContainerUnavailable

    var errorDescription: String? {
        switch self {
        case .noSession: return "No active VPN session"
        case .sendFailed: return "Failed to send message to Extension"
        case .noManager: return "VPN manager not configured"
        case .backendNotReady(let message): return "VPN backend did not become ready: \(message)"
        case .ipcTimeout: return "Timed out waiting for Packet Tunnel IPC response"
        case .sharedContainerUnavailable: return "Shared app container is unavailable"
        }
    }
}
