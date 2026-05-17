import Darwin
import Foundation
import Network
import NetworkExtension
import os

/// Packet Tunnel Provider — hosts the Go backend and manages the VPN tunnel.
///
/// This runs in a separate process from the main App.
/// Do NOT use UIApplication, shared global state, or any App-process APIs here.
class PacketTunnelProvider: NEPacketTunnelProvider {

    private struct TunnelSettingsRequest {
        let settings: NEPacketTunnelNetworkSettings
        let hasDefaultRoute: Bool?
        let completion: ((Error?) -> Void)?
    }

    private let logger = Logger(subsystem: IPCConstants.appBundleID, category: "tunnel")
    private let defaultRouteMonitorQueue = DispatchQueue(label: "top.yesican.awgscale.default-route-monitor")
    private var defaultRouteMonitor: NWPathMonitor?
    private let packetBridgeStallThreshold: TimeInterval = 30
    private let packetBridgeProgressLogInterval: TimeInterval = 5
    private let underlayRefreshCooldown: TimeInterval = 60
    private var notifyHandle: NotificationHandle?
    private var tunnelConfigCallback: AnyObject?
    private let packetReadQueue = DispatchQueue(label: "top.yesican.awgscale.packetflow.read", qos: .userInitiated)
    private let packetWriteQueue = DispatchQueue(label: "top.yesican.awgscale.packetflow.write", qos: .userInitiated)
    private let packetStateQueue = DispatchQueue(label: "top.yesican.awgscale.packetflow.state")
    private let packetStateQueueKey = DispatchSpecificKey<Void>()
    private var packetReadLoopRunning = false
    private let tunnelSettingsQueue = DispatchQueue(label: "top.yesican.awgscale.tunnel-settings")
    private var tunnelStopping = false
    private var tunnelSettingsInFlight = false
    private var pendingTunnelSettings: TunnelSettingsRequest?
    private var packetsFromSystem: UInt64 = 0
    private var bytesFromSystem: UInt64 = 0
    private var packetsFromGoCallback: UInt64 = 0
    private var bytesFromGoCallback: UInt64 = 0
    private var packetsToSystem: UInt64 = 0
    private var bytesToSystem: UInt64 = 0
    private var packetBridgeHasDefaultRoute = false
    private var lastPacketsToSystemProgressTime = Date()
    private var packetsFromSystemAtLastToSystemProgress: UInt64 = 0
    private var lastPacketBridgeProgressLogTime = Date.distantPast
    private var lastUnderlayRefreshTime: Date?
    private var hasPublishedBackendSnapshot = false
    private var notifiedIncomingTaildropFiles: Set<String> = []

    override init() {
        super.init()
        packetStateQueue.setSpecific(key: packetStateQueueKey, value: ())
    }

    // MARK: - Lifecycle

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        logger.log("startTunnel: beginning")
        logger.notice("runtime marker awgscale=0.1.7 build=8 recovery=official-soft-refresh-fast30-cd60 refactor=dns-subnet-tka-advertise-routes-mullvad-notifications")
        resetTunnelLifecycleState()
        sharedDefaults?.removeObject(forKey: IPCConstants.keyLastError)
        sharedDefaults?.set(false, forKey: IPCConstants.keyTunnelHasDefaultRoute)
        writeSharedState(ipnState: 4) // IpnState.starting

        // 1. Determine data directory inside App Group container
        guard let containerURL = sharedContainerURL else {
            completeStartWithError("No App Group container", code: 1, completionHandler: completionHandler)
            return
        }

        let dataDir = containerURL.appendingPathComponent("awgscale", isDirectory: true).path
        let directFileRoot = containerURL.appendingPathComponent("taildrop", isDirectory: true).path

        // Ensure directories exist
        do {
            try FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: directFileRoot, withIntermediateDirectories: true)
        } catch {
            logger.error("startTunnel: failed to create directories: \(error.localizedDescription)")
            completeStartWithError(
                "Failed to create data directories: \(error.localizedDescription)",
                code: 3,
                completionHandler: completionHandler
            )
            return
        }

        startDefaultRouteMonitor()

        // 2. Start Go backend
        let started = GoBridge.start(dataDir: dataDir, directFileRoot: directFileRoot, hwAttestation: false)
        if !started {
            logger.error("startTunnel: Go backend failed to start")
            completeStartWithError("Go backend start failed", code: 2, completionHandler: completionHandler)
            return
        }
        logger.log("startTunnel: Go backend started")

        // 3. Bridge IP packets between NetworkExtension and Go's TUN device.
        startPacketBridge()

        // 4. Subscribe to WatchNotifications to track state
        guard let notifyHandle = GoBridge.watchNotifications(mask: NotifyWatchOpt.defaultMask, callback: { [weak self] data in
            self?.handleNotification(data)
        }) else {
            logger.error("startTunnel: failed to watch Go backend notifications")
            cleanupStartedBackend()
            completeStartWithError("Go backend did not become ready", code: 4, completionHandler: completionHandler)
            return
        }
        self.notifyHandle = notifyHandle
        logger.log("startTunnel: watching notifications")

        // 5. Configure initial tunnel settings
        //    Real settings update from Go backend via TunnelConfigCallback.
        let settings = createInitialTunnelSettings()
        enqueueTunnelSettingsUpdate(settings, hasDefaultRoute: false) { [weak self] error in
            if let error = error {
                self?.logger.error("startTunnel: setTunnelNetworkSettings failed: \(error.localizedDescription)")
                self?.publishLastError("setTunnelNetworkSettings failed: \(error.localizedDescription)")
                completionHandler(error)
                return
            }
            guard let self = self, !self.isTunnelStopping() else {
                completionHandler(nil)
                return
            }
            self.logger.log("startTunnel: initial tunnel settings applied")
            self.registerTunnelConfigCallback()
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logger.log("stopTunnel: reason=\(String(describing: reason))")
        markTunnelStopping()

        // Stop notifications
        if let handle = notifyHandle {
            GoBridge.stopNotifications(handle)
            notifyHandle = nil
        }
        #if canImport(Libtailscale)
        if let app = GoBridge.application {
            LibtailscaleSetTunnelConfigCallback(app, nil)
        }
        #endif
        tunnelConfigCallback = nil
        GoBridge.stopBackend()

        // Write disconnected state to shared defaults
        sharedDefaults?.set(false, forKey: IPCConstants.keyTunnelHasDefaultRoute)
        sharedDefaults?.removeObject(forKey: IPCConstants.keyLastError)
        writeSharedState(ipnState: 3) // IpnState.stopped

        completionHandler()
    }

    // MARK: - Tunnel Config from Go Backend

    /// Called by Go when router.Config or dns.OSConfig changes.
    private func handleTunnelConfigUpdate(_ configJSON: Data) {
        guard !isTunnelStopping() else { return }
        do {
            let config = try JSONDecoder().decode(TunnelConfigFromGo.self, from: configJSON)
            let settings = buildTunnelSettings(from: config)
            let hasDefaultRoute = tunnelConfigHasDefaultRoute(config.routes)
            updateTunnelSettings(settings, hasDefaultRoute: hasDefaultRoute)
            logger.log("tunnel config updated: \(config.localAddresses.count) addrs, \(config.routes.count) routes, \(config.excludeRoutes?.count ?? 0) excluded, \(config.dnsServers.count) DNS, defaultRoute=\(hasDefaultRoute)")
        } catch {
            logger.error("handleTunnelConfigUpdate: decode failed: \(error.localizedDescription)")
            sharedDefaults?.set("Tunnel config error: \(error.localizedDescription)",
                               forKey: IPCConstants.keyLastError)
            postDarwinNotification(IPCConstants.notifyStateChanged)
        }
    }

    private func registerTunnelConfigCallback() {
        #if canImport(Libtailscale)
        guard let app = GoBridge.application else { return }
        let configCb = GoTunnelConfigCallback { [weak self] configJSON in
            self?.handleTunnelConfigUpdate(configJSON)
        }
        tunnelConfigCallback = configCb
        LibtailscaleSetTunnelConfigCallback(app, configCb)
        #endif
    }

    /// Build NEPacketTunnelNetworkSettings from Go's TunnelConfig JSON.
    private func buildTunnelSettings(from config: TunnelConfigFromGo) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "100.100.100.100")

        var ipv4Addrs: [String] = []
        var ipv4Masks: [String] = []
        var ipv6Addrs: [String] = []
        var ipv6PrefixLens: [NSNumber] = []

        // Parse local addresses (CIDR notation)
        for addrStr in config.localAddresses {
            guard let parsed = parseCIDR(addrStr) else {
                logger.error("ignoring malformed local tunnel address: \(addrStr, privacy: .private)")
                continue
            }

            if parsed.address.contains(":") {
                guard (0...128).contains(parsed.prefixLen) else {
                    logger.error("ignoring IPv6 tunnel address with invalid prefix: \(addrStr, privacy: .private)")
                    continue
                }
                ipv6Addrs.append(parsed.address)
                ipv6PrefixLens.append(NSNumber(value: parsed.prefixLen))
            } else {
                guard (0...32).contains(parsed.prefixLen) else {
                    logger.error("ignoring IPv4 tunnel address with invalid prefix: \(addrStr, privacy: .private)")
                    continue
                }
                ipv4Addrs.append(parsed.address)
                ipv4Masks.append(prefixLenToMask(parsed.prefixLen))
            }
        }

        // IPv4
        if !ipv4Addrs.isEmpty {
            let ipv4 = NEIPv4Settings(addresses: ipv4Addrs, subnetMasks: ipv4Masks)
            ipv4.includedRoutes = config.routes.compactMap(makeIPv4Route)
            let excludedRoutes = (config.excludeRoutes ?? []).compactMap(makeIPv4Route)
            if !excludedRoutes.isEmpty {
                ipv4.excludedRoutes = excludedRoutes
            }
            settings.ipv4Settings = ipv4
        }

        // IPv6
        if !ipv6Addrs.isEmpty {
            let ipv6 = NEIPv6Settings(addresses: ipv6Addrs, networkPrefixLengths: ipv6PrefixLens)
            ipv6.includedRoutes = config.routes.compactMap(makeIPv6Route)
            let excludedRoutes = (config.excludeRoutes ?? []).compactMap(makeIPv6Route)
            if !excludedRoutes.isEmpty {
                ipv6.excludedRoutes = excludedRoutes
            }
            settings.ipv6Settings = ipv6
        }

        // DNS
        if !config.dnsServers.isEmpty {
            let dns = NEDNSSettings(servers: config.dnsServers)
            if let matchDomains = config.dnsMatchDomains, !matchDomains.isEmpty {
                dns.matchDomains = matchDomains
            } else {
                dns.matchDomains = [""]
            }
            if !config.dnsDomains.isEmpty {
                dns.searchDomains = config.dnsDomains
            }
            settings.dnsSettings = dns
        }

        settings.mtu = NSNumber(value: config.mtu > 0 ? config.mtu : 1280)

        return settings
    }

    // MARK: - IPC: App → Extension

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        do {
            let request = try JSONDecoder().decode(IPCRequest.self, from: messageData)

            switch request.command {
            case .callLocalAPI:
                handleLocalAPIRequest(request, completionHandler: completionHandler)

            case .callLocalAPIWithSharedFile:
                handleLocalAPISharedFileRequest(request, completionHandler: completionHandler)

            case .startLoginInteractive:
                handleStartLoginInteractive(completionHandler: completionHandler)

            case .prepareToStop:
                handlePrepareToStop(completionHandler: completionHandler)
            }
        } catch {
            logger.error("handleAppMessage: decode failed: \(error.localizedDescription)")
            let resp = IPCResponse.failure("Invalid IPC request: \(error.localizedDescription)")
            completionHandler?(try? JSONEncoder().encode(resp))
        }
    }

    // MARK: - IPC Handlers

    private func handleLocalAPIRequest(_ request: IPCRequest, completionHandler: ((Data?) -> Void)?) {
        guard let method = request.method, let endpoint = request.endpoint else {
            let resp = IPCResponse.failure("Missing method or endpoint")
            completionHandler?(try? JSONEncoder().encode(resp))
            return
        }

        let timeout = request.timeoutMillis ?? 30000
        let body: Data? = request.bodyBase64.flatMap { Data(base64Encoded: $0) }
        let readBody = request.readBody ?? true

        Task {
            let startedAt = Date()
            do {
                guard await waitForGoBackendStarted(maxWaitMillis: max(12_000, timeout)) else {
                    let message = isTunnelStopping() ? "Go backend is stopping" : "Go backend is not ready"
                    let resp = IPCResponse.failure(message)
                    completionHandler?(try? JSONEncoder().encode(resp))
                    return
                }
                let apiResp = try await GoBridge.callLocalAPI(
                    timeoutMillis: timeout,
                    method: method,
                    endpoint: endpoint,
                    body: body,
                    readBody: readBody
                )
                let resp = IPCResponse.success(statusCode: apiResp.statusCode, body: apiResp.body)
                completionHandler?(try? JSONEncoder().encode(resp))
                logLocalAPICompletionIfUseful(method: method, endpoint: endpoint, statusCode: apiResp.statusCode, startedAt: startedAt)
            } catch {
                let durationMillis = Int(Date().timeIntervalSince(startedAt) * 1000)
                logger.error("LocalAPI failed method=\(method, privacy: .public) endpoint=\(endpoint, privacy: .public) durationMs=\(durationMillis, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                if shouldPublishLocalAPIError(endpoint: endpoint) {
                    publishLastError(error.localizedDescription)
                }
                let resp = IPCResponse.failure(error.localizedDescription)
                completionHandler?(try? JSONEncoder().encode(resp))
            }
        }
    }

    private func shouldPublishLocalAPIError(endpoint: String) -> Bool {
        !endpoint.hasPrefix("/localapi/v0/ping")
    }

    private func logLocalAPICompletionIfUseful(method: String, endpoint: String, statusCode: Int, startedAt: Date) {
        guard endpoint.contains("/ping") || endpoint.contains("/awg-") else { return }
        let durationMillis = Int(Date().timeIntervalSince(startedAt) * 1000)
        logger.notice("LocalAPI completed method=\(method, privacy: .public) endpoint=\(endpoint, privacy: .public) status=\(statusCode, privacy: .public) durationMs=\(durationMillis, privacy: .public)")
    }

    private func handleLocalAPISharedFileRequest(_ request: IPCRequest, completionHandler: ((Data?) -> Void)?) {
        guard let method = request.method,
              let endpoint = request.endpoint,
              let relativePath = request.bodyFileRelativePath else {
            let resp = IPCResponse.failure("Missing method, endpoint, or shared file path")
            completionHandler?(try? JSONEncoder().encode(resp))
            return
        }
        guard let fileURL = sharedFileURL(relativePath: relativePath) else {
            let resp = IPCResponse.failure("Invalid shared file path")
            completionHandler?(try? JSONEncoder().encode(resp))
            return
        }

        let timeout = request.timeoutMillis ?? 600000
        let readBody = request.readBody ?? false

        Task {
            do {
                guard await waitForGoBackendStarted(maxWaitMillis: max(12_000, timeout)) else {
                    let message = isTunnelStopping() ? "Go backend is stopping" : "Go backend is not ready"
                    let resp = IPCResponse.failure(message)
                    completionHandler?(try? JSONEncoder().encode(resp))
                    return
                }
                if method.uppercased() == "POST",
                   let peerID = taildropFilePutPeerID(from: endpoint) {
                    let transferID = request.bodyFileTransferID ?? UUID().uuidString
                    let uploadURL = try copySharedFileForDetachedUpload(fileURL)
                    let resp = IPCResponse.success(statusCode: 202)
                    completionHandler?(try? JSONEncoder().encode(resp))

                    Task {
                        defer { cleanupDetachedUpload(uploadURL) }
                        do {
                            let apiResp = try await GoBridge.callTaildropFilePut(
                                timeoutMillis: timeout,
                                peerID: peerID,
                                fileURL: uploadURL,
                                transferID: transferID,
                                readBody: true
                            )
                            if !(200..<300).contains(apiResp.statusCode) {
                                let body = String(data: apiResp.body, encoding: .utf8)?
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                let detail = body.map { $0.isEmpty ? "" : ": \($0)" } ?? ""
                                publishLastError("Taildrop upload failed with HTTP \(apiResp.statusCode)\(detail)")
                            }
                        } catch {
                            logger.error("Detached Taildrop upload failed peer=\(peerID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                            publishLastError("Taildrop upload failed: \(error.localizedDescription)")
                        }
                    }
                    return
                }
                let apiResp: LocalAPIResponse
                apiResp = try await GoBridge.callLocalAPI(
                    timeoutMillis: timeout,
                    method: method,
                    endpoint: endpoint,
                    bodyFileURL: fileURL,
                    readBody: readBody
                )
                let resp = IPCResponse.success(statusCode: apiResp.statusCode, body: apiResp.body)
                completionHandler?(try? JSONEncoder().encode(resp))
            } catch {
                logger.error("LocalAPI shared-file failed method=\(method, privacy: .public) endpoint=\(endpoint, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                sharedDefaults?.set(error.localizedDescription, forKey: IPCConstants.keyLastError)
                postDarwinNotification(IPCConstants.notifyStateChanged)
                let resp = IPCResponse.failure(error.localizedDescription)
                completionHandler?(try? JSONEncoder().encode(resp))
            }
        }
    }

    private func taildropFilePutPeerID(from endpoint: String) -> String? {
        let prefix = "/localapi/v0/file-put/"
        guard endpoint.hasPrefix(prefix) else { return nil }
        let peerID = String(endpoint.dropFirst(prefix.count))
        guard !peerID.isEmpty, !peerID.contains("/") else { return nil }
        return peerID
    }

    private func copySharedFileForDetachedUpload(_ fileURL: URL) throws -> URL {
        guard let containerURL = sharedContainerURL else {
            throw VPNError.sharedContainerUnavailable
        }
        let directory = containerURL
            .appendingPathComponent("taildrop-active-uploads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(fileURL.lastPathComponent.isEmpty ? "file" : fileURL.lastPathComponent)
        try FileManager.default.copyItem(at: fileURL, to: destination)
        return destination
    }

    private func cleanupDetachedUpload(_ uploadURL: URL) {
        try? FileManager.default.removeItem(at: uploadURL.deletingLastPathComponent())
    }

    private func sharedFileURL(relativePath: String) -> URL? {
        guard !relativePath.isEmpty,
              !relativePath.split(separator: "/").contains(".."),
              let containerURL = sharedContainerURL else {
            return nil
        }

        let rootURL = containerURL.standardizedFileURL
        let fileURL = rootURL.appendingPathComponent(relativePath, isDirectory: false).standardizedFileURL
        guard fileURL.path.hasPrefix(rootURL.path + "/") else {
            return nil
        }
        return fileURL
    }

    private func waitForGoBackendStarted(maxWaitMillis: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(maxWaitMillis) / 1000.0)
        while GoBridge.application == nil && !isTunnelStopping() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return GoBridge.application != nil && !isTunnelStopping()
    }

    private func handleStartLoginInteractive(completionHandler: ((Data?) -> Void)?) {
        Task {
            do {
                let apiResp = try await GoBridge.callLocalAPI(
                    timeoutMillis: 30000,
                    method: "POST",
                    endpoint: "/localapi/v0/login-interactive"
                )
                let resp = IPCResponse.success(statusCode: apiResp.statusCode, body: apiResp.body)
                completionHandler?(try? JSONEncoder().encode(resp))
            } catch {
                let resp = IPCResponse.failure(error.localizedDescription)
                completionHandler?(try? JSONEncoder().encode(resp))
            }
        }
    }

    private func handlePrepareToStop(completionHandler: ((Data?) -> Void)?) {
        logger.log("prepareToStop: app requested tunnel shutdown")
        markTunnelStopping()
        sharedDefaults?.removeObject(forKey: IPCConstants.keyLastError)
        postDarwinNotification(IPCConstants.notifyStateChanged)
        let resp = IPCResponse.success(statusCode: 200)
        completionHandler?(try? JSONEncoder().encode(resp))
    }

    // MARK: - Notification Handling

    /// Process ipn.Notify JSON from Go backend.
    /// Writes relevant state to App Group UserDefaults and posts Darwin notification.
    private func handleNotification(_ data: Data) {
        do {
            let notify = try JSONDecoder().decode(IpnNotify.self, from: data)
            sharedDefaults?.removeObject(forKey: IPCConstants.keyLastError)

            let shouldClearBackendSnapshot = (notify.State.flatMap(IpnState.init(rawValue:))?.clearsBackendSnapshot ?? false) && hasPublishedBackendSnapshot

            if let stateInt = notify.State {
                writeSharedState(ipnState: stateInt)
                if shouldClearBackendSnapshot {
                    clearSharedBackendSnapshot()
                }
            }

            if !shouldClearBackendSnapshot, let prefs = notify.Prefs {
                if let prefsData = try? JSONEncoder().encode(prefs) {
                    sharedDefaults?.set(String(data: prefsData, encoding: .utf8), forKey: IPCConstants.keyPrefsJSON)
                }
            }

            if !shouldClearBackendSnapshot, let netMap = notify.NetMap {
                if let netMapData = try? JSONEncoder().encode(netMap) {
                    sharedDefaults?.set(String(data: netMapData, encoding: .utf8), forKey: IPCConstants.keyNetMapJSON)
                    hasPublishedBackendSnapshot = true
                }
            }

            if let url = notify.BrowseToURL {
                sharedDefaults?.set(url, forKey: IPCConstants.keyBrowseToURL)
            }

            if notify.LoginFinished != nil {
                sharedDefaults?.set(true, forKey: IPCConstants.keyLoginFinished)
                sharedDefaults?.removeObject(forKey: IPCConstants.keyBrowseToURL)
            }

            if !shouldClearBackendSnapshot, let health = notify.Health {
                if let healthData = try? JSONEncoder().encode(health) {
                    sharedDefaults?.set(String(data: healthData, encoding: .utf8), forKey: IPCConstants.keyHealthJSON)
                }
            }

            if !shouldClearBackendSnapshot, let outgoingFiles = notify.OutgoingFiles {
                if let outgoingData = try? JSONEncoder().encode(outgoingFiles) {
                    sharedDefaults?.set(String(data: outgoingData, encoding: .utf8), forKey: IPCConstants.keyOutgoingFilesJSON)
                }
            }

            if !shouldClearBackendSnapshot, let incomingFiles = notify.IncomingFiles {
                if let incomingData = try? JSONEncoder().encode(incomingFiles) {
                    sharedDefaults?.set(String(data: incomingData, encoding: .utf8), forKey: IPCConstants.keyIncomingFilesJSON)
                }
                publishCompletedIncomingTaildropFiles(incomingFiles)
            }

            if !shouldClearBackendSnapshot, notify.FilesWaiting != nil {
                sharedDefaults?.set(true, forKey: IPCConstants.keyTaildropFilesWaiting)
            }

            // Signal the App to re-read shared state
            postDarwinNotification(IPCConstants.notifyStateChanged)

        } catch {
            logger.error("handleNotification: decode failed: \(error.localizedDescription)")
            sharedDefaults?.set(error.localizedDescription, forKey: IPCConstants.keyLastError)
            postDarwinNotification(IPCConstants.notifyStateChanged)
        }
    }

    // MARK: - Shared State

    private func completeStartWithError(_ message: String,
                                        code: Int,
                                        completionHandler: @escaping (Error?) -> Void) {
        logger.error("startTunnel failed: \(message, privacy: .public)")
        publishLastError(message)
        let err = NSError(domain: "PacketTunnel", code: code,
                          userInfo: [NSLocalizedDescriptionKey: message])
        completionHandler(err)
    }

    private func publishLastError(_ message: String) {
        sharedDefaults?.set(message, forKey: IPCConstants.keyLastError)
        postDarwinNotification(IPCConstants.notifyStateChanged)
    }

    private func publishCompletedIncomingTaildropFiles(_ incomingFiles: [TaildropIncomingFile]) {
        let completedFiles = incomingFiles.filter(\.isDone)
        guard !completedFiles.isEmpty else { return }

        var revision = sharedDefaults?.integer(forKey: IPCConstants.keyTaildropInboxRevision) ?? 0
        for file in completedFiles {
            let key = incomingTaildropNotificationKey(file)
            guard !notifiedIncomingTaildropFiles.contains(key) else { continue }

            notifiedIncomingTaildropFiles.insert(key)
            revision += 1
            sharedDefaults?.set(true, forKey: IPCConstants.keyTaildropFilesWaiting)
            sharedDefaults?.set(revision, forKey: IPCConstants.keyTaildropInboxRevision)
            sharedDefaults?.set(file.Name, forKey: IPCConstants.keyTaildropLastFileName)
            logger.log("Taildrop file received: \(file.Name, privacy: .public)")

            Task { @MainActor in
                await NotificationManager.shared.notifyFileReceived(fileName: file.Name, sender: "A device")
            }
        }
    }

    private func incomingTaildropNotificationKey(_ file: TaildropIncomingFile) -> String {
        [file.Name, file.FinalPath ?? "", file.Started ?? ""].joined(separator: "|")
    }

    private func clearSharedBackendSnapshot() {
        let keys = [
            IPCConstants.keyPrefsJSON,
            IPCConstants.keyNetMapJSON,
            IPCConstants.keyHealthJSON,
            IPCConstants.keySelfNodeJSON,
            IPCConstants.keyTunnelHasDefaultRoute,
            IPCConstants.keyCurrentProfileID,
            IPCConstants.keyOutgoingFilesJSON,
            IPCConstants.keyIncomingFilesJSON,
            IPCConstants.keyTaildropFilesWaiting,
            IPCConstants.keyTaildropInboxRevision,
            IPCConstants.keyTaildropPromptedInboxRevision,
            IPCConstants.keyTaildropLastFileName,
        ]
        keys.forEach { sharedDefaults?.removeObject(forKey: $0) }
        hasPublishedBackendSnapshot = false
    }

    private func writeSharedState(ipnState: Int) {
        sharedDefaults?.set(ipnState, forKey: IPCConstants.keyIPNState)
        postDarwinNotification(IPCConstants.notifyStateChanged)
    }

    private func publishTunnelDefaultRoute(_ hasDefaultRoute: Bool) {
        sharedDefaults?.set(hasDefaultRoute, forKey: IPCConstants.keyTunnelHasDefaultRoute)
        sharedDefaults?.synchronize()
        packetStateQueue.async { [weak self] in
            self?.packetBridgeHasDefaultRoute = hasDefaultRoute
            self?.lastPacketsToSystemProgressTime = Date()
            self?.packetsFromSystemAtLastToSystemProgress = self?.packetsFromSystem ?? 0
            self?.lastPacketBridgeProgressLogTime = Date.distantPast
            self?.lastUnderlayRefreshTime = nil
        }
        postDarwinNotification(IPCConstants.notifyStateChanged)
    }

    // MARK: - Tunnel Configuration

    /// Creates initial tunnel network settings before Go provides real config.
    private func createInitialTunnelSettings() -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "100.100.100.100")

        let ipv4 = NEIPv4Settings(addresses: ["192.0.2.1"], subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = []
        settings.ipv4Settings = ipv4

        settings.mtu = 1280

        return settings
    }

    /// Re-apply tunnel settings without destroying the TUN device.
    /// iOS supports this via setTunnelNetworkSettings + reasserting flag.
    func updateTunnelSettings(_ settings: NEPacketTunnelNetworkSettings, hasDefaultRoute: Bool) {
        enqueueTunnelSettingsUpdate(settings, hasDefaultRoute: hasDefaultRoute) { [weak self] error in
            if let error = error {
                self?.logger.error("updateTunnelSettings failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Helpers

    private func prefixLenToMask(_ prefixLen: Int) -> String {
        return ipv4PrefixLenToMask(prefixLen)
    }

    private func makeIPv4Route(_ routeStr: String) -> NEIPv4Route? {
        if routeStr.contains(":") { return nil }
        guard let route = parseCIDR(routeStr) else {
            logger.error("ignoring malformed IPv4 route: \(routeStr, privacy: .private)")
            return nil
        }
        guard (0...32).contains(route.prefixLen) else {
            logger.error("ignoring IPv4 route with invalid prefix: \(routeStr, privacy: .private)")
            return nil
        }
        if isIPv4DefaultRoute(address: route.address, prefixLen: route.prefixLen) {
            return NEIPv4Route.default()
        }
        return NEIPv4Route(destinationAddress: route.address, subnetMask: prefixLenToMask(route.prefixLen))
    }

    private func makeIPv6Route(_ routeStr: String) -> NEIPv6Route? {
        if !routeStr.contains(":") { return nil }
        guard let route = parseCIDR(routeStr) else {
            logger.error("ignoring malformed IPv6 route: \(routeStr, privacy: .private)")
            return nil
        }
        guard (0...128).contains(route.prefixLen) else {
            logger.error("ignoring IPv6 route with invalid prefix: \(routeStr, privacy: .private)")
            return nil
        }
        if isIPv6DefaultRoute(address: route.address, prefixLen: route.prefixLen) {
            return NEIPv6Route.default()
        }
        return NEIPv6Route(destinationAddress: route.address,
                           networkPrefixLength: NSNumber(value: route.prefixLen))
    }

    private func resetTunnelLifecycleState() {
        if DispatchQueue.getSpecific(key: packetStateQueueKey) != nil {
            packetReadLoopRunning = false
        } else {
            packetStateQueue.sync {
                packetReadLoopRunning = false
            }
        }
        tunnelSettingsQueue.sync {
            tunnelStopping = false
            tunnelSettingsInFlight = false
            pendingTunnelSettings = nil
        }
        packetStateQueue.sync {
            packetsFromSystem = 0
            bytesFromSystem = 0
            packetsFromGoCallback = 0
            bytesFromGoCallback = 0
            packetsToSystem = 0
            bytesToSystem = 0
            packetBridgeHasDefaultRoute = false
            lastPacketBridgeProgressLogTime = Date.distantPast
        }
        hasPublishedBackendSnapshot = false
    }

    private func markTunnelStopping() {
        tunnelSettingsQueue.sync {
            tunnelStopping = true
            pendingTunnelSettings = nil
        }
        stopDefaultRouteMonitor()
        stopPacketBridge()
    }

    private func cleanupStartedBackend() {
        markTunnelStopping()
        #if canImport(Libtailscale)
        if let app = GoBridge.application {
            LibtailscaleSetTunnelConfigCallback(app, nil)
        }
        #endif
        tunnelConfigCallback = nil
        GoBridge.stopBackend()
    }

    private func isTunnelStopping() -> Bool {
        return tunnelSettingsQueue.sync {
            tunnelStopping
        }
    }

    private func startDefaultRouteMonitor() {
        stopDefaultRouteMonitor()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            self?.publishDefaultRouteInterface(from: path)
        }
        defaultRouteMonitor = monitor
        monitor.start(queue: defaultRouteMonitorQueue)
        publishDefaultRouteInterface(from: monitor.currentPath)
    }

    private func stopDefaultRouteMonitor() {
        defaultRouteMonitor?.cancel()
        defaultRouteMonitor = nil
    }

    private func publishDefaultRouteInterface(from path: Network.NWPath) {
        guard path.status == .satisfied,
              let ifName = defaultRouteInterfaceName(from: path) else {
            return
        }
        GoBridge.updateDefaultRouteInterface(ifName)
        logger.log("default route monitor: using interface \(ifName, privacy: .public)")
    }

    private func defaultRouteInterfaceName(from path: Network.NWPath) -> String? {
        let preferredTypes: [Network.NWInterface.InterfaceType] = [.wifi, .wiredEthernet, .cellular]
        for type in preferredTypes {
            if let iface = path.availableInterfaces.first(where: { $0.type == type && !$0.name.hasPrefix("utun") }) {
                return iface.name
            }
        }
        return path.availableInterfaces.first { iface in
            !iface.name.hasPrefix("utun") && iface.type != .loopback
        }?.name
    }

    private func enqueueTunnelSettingsUpdate(_ settings: NEPacketTunnelNetworkSettings,
                                             hasDefaultRoute: Bool? = nil,
                                             completion: ((Error?) -> Void)? = nil) {
        tunnelSettingsQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.tunnelStopping else {
                completion?(nil)
                return
            }
            let request = TunnelSettingsRequest(settings: settings, hasDefaultRoute: hasDefaultRoute, completion: completion)
            if self.tunnelSettingsInFlight {
                self.pendingTunnelSettings = request
                return
            }
            self.tunnelSettingsInFlight = true
            self.performTunnelSettingsUpdate(request)
        }
    }

    private func performTunnelSettingsUpdate(_ request: TunnelSettingsRequest) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard !self.isTunnelStopping() else {
                request.completion?(nil)
                self.finishTunnelSettingsUpdate()
                return
            }
            self.reasserting = true
            self.setTunnelNetworkSettings(request.settings) { [weak self] error in
                var completionError = error
                if let error = error {
                    if self?.isTunnelStopping() == true {
                        completionError = nil
                        self?.logger.log("setTunnelNetworkSettings failed while stopping; suppressing: \(error.localizedDescription)")
                    } else {
                        self?.logger.error("setTunnelNetworkSettings failed: \(error.localizedDescription)")
                    }
                    if request.hasDefaultRoute != nil && self?.isTunnelStopping() != true {
                        self?.publishLastError("setTunnelNetworkSettings failed: \(error.localizedDescription)")
                    }
                } else if let hasDefaultRoute = request.hasDefaultRoute {
                    self?.publishTunnelDefaultRoute(hasDefaultRoute)
                }
                request.completion?(completionError)
                self?.finishTunnelSettingsUpdate()
            }
        }
    }

    private func finishTunnelSettingsUpdate() {
        tunnelSettingsQueue.async { [weak self] in
            guard let self = self else { return }
            if self.tunnelStopping {
                self.pendingTunnelSettings = nil
                self.tunnelSettingsInFlight = false
                DispatchQueue.main.async { [weak self] in
                    self?.reasserting = false
                }
                return
            }
            if let next = self.pendingTunnelSettings {
                self.pendingTunnelSettings = nil
                self.performTunnelSettingsUpdate(next)
                return
            }
            self.tunnelSettingsInFlight = false
            DispatchQueue.main.async { [weak self] in
                self?.reasserting = false
            }
        }
    }

    // MARK: - Packet Flow Bridge

    private func startPacketBridge() {
        GoBridge.setPacketCallback { [weak self] packet in
            self?.writePacketToFlow(packet)
        }

        let shouldStartReadLoop = packetStateQueue.sync { () -> Bool in
            if packetReadLoopRunning { return false }
            packetReadLoopRunning = true
            return true
        }
        guard shouldStartReadLoop else { return }
        packetReadQueue.async { [weak self] in
            guard let self = self else { return }
            self.readPacketsFromFlow()
        }
    }

    private func stopPacketBridge() {
        if DispatchQueue.getSpecific(key: packetStateQueueKey) != nil {
            packetReadLoopRunning = false
        } else {
            packetStateQueue.sync {
                packetReadLoopRunning = false
            }
        }
        GoBridge.clearPacketCallback()
    }

    private func readPacketsFromFlow() {
        guard isPacketBridgeRunning() else { return }
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self = self else { return }
            self.packetReadQueue.async {
                guard self.isPacketBridgeRunning() else { return }
                for packet in packets {
                    do {
                        self.recordPacketFromSystem(byteCount: packet.count)
                        try GoBridge.injectInboundPacket(packet)
                    } catch {
                        self.logger.error("injectInboundPacket failed: \(error.localizedDescription)")
                    }
                }
                self.readPacketsFromFlow()
            }
        }
    }

    private func writePacketToFlow(_ packet: Data) {
        recordPacketFromGoCallback(byteCount: packet.count)
        packetWriteQueue.async { [weak self] in
            guard let self = self, self.isPacketBridgeRunning() else { return }
            guard let protocolFamily = self.protocolFamily(for: packet) else {
                self.logger.error("dropping packet with unknown IP version")
                return
            }
            self.recordPacketToSystem(byteCount: packet.count)
            self.packetFlow.writePackets([packet], withProtocols: [protocolFamily])
        }
    }

    private func isPacketBridgeRunning() -> Bool {
        if DispatchQueue.getSpecific(key: packetStateQueueKey) != nil {
            return packetReadLoopRunning
        }
        return packetStateQueue.sync { packetReadLoopRunning }
    }

    private func recordPacketFromSystem(byteCount: Int) {
        packetStateQueue.async { [weak self] in
            guard let self else { return }
            packetsFromSystem += 1
            bytesFromSystem += UInt64(byteCount)
            recoverUnderlayIfPacketBridgeStalled()
        }
    }

    private func recordPacketFromGoCallback(byteCount: Int) {
        packetStateQueue.async { [weak self] in
            guard let self else { return }
            packetsFromGoCallback += 1
            bytesFromGoCallback += UInt64(byteCount)
        }
    }

    private func recordPacketToSystem(byteCount: Int) {
        packetStateQueue.async { [weak self] in
            guard let self else { return }
            packetsToSystem += 1
            bytesToSystem += UInt64(byteCount)
            lastPacketsToSystemProgressTime = Date()
            packetsFromSystemAtLastToSystemProgress = packetsFromSystem
        }
    }

    private func recoverUnderlayIfPacketBridgeStalled() {
        guard packetBridgeHasDefaultRoute, packetsToSystem > 0 else { return }

        let now = Date()
        let stalledFor = now.timeIntervalSince(lastPacketsToSystemProgressTime)
        let incomingSinceProgress = packetsFromSystem - packetsFromSystemAtLastToSystemProgress

        if stalledFor >= packetBridgeProgressLogInterval,
           now.timeIntervalSince(lastPacketBridgeProgressLogTime) >= packetBridgeProgressLogInterval {
            lastPacketBridgeProgressLogTime = now
            let currentPacketsFromSystem = packetsFromSystem
            let currentPacketsFromGoCallback = packetsFromGoCallback
            let currentPacketsToSystem = packetsToSystem
            let currentBytesFromSystem = bytesFromSystem
            let currentBytesFromGoCallback = bytesFromGoCallback
            let currentBytesToSystem = bytesToSystem
            logger.notice("packet bridge default-route progress system-to-go=\(currentPacketsFromSystem, privacy: .public) go-callbacks=\(currentPacketsFromGoCallback, privacy: .public) go-to-system=\(currentPacketsToSystem, privacy: .public) incomingSinceProgress=\(incomingSinceProgress, privacy: .public) stalled=\(Int(stalledFor), privacy: .public)s bytes-system-to-go=\(currentBytesFromSystem, privacy: .public) bytes-go-callbacks=\(currentBytesFromGoCallback, privacy: .public) bytes-go-to-system=\(currentBytesToSystem, privacy: .public)")
        }

        guard stalledFor >= packetBridgeStallThreshold else { return }
        guard incomingSinceProgress >= 16 else { return }

          if let lastUnderlayRefreshTime,
              now.timeIntervalSince(lastUnderlayRefreshTime) < underlayRefreshCooldown {
            return
        }

          lastUnderlayRefreshTime = now
        lastPacketsToSystemProgressTime = now
        packetsFromSystemAtLastToSystemProgress = packetsFromSystem

        let reason = "exit-node-stall system-to-go=\(packetsFromSystem) go-to-system=\(packetsToSystem) stalled=\(Int(stalledFor))s"
        logger.error("packet bridge appears stalled; refreshing underlay: \(reason, privacy: .public)")
        DispatchQueue.global(qos: .utility).async {
            GoBridge.rebindUnderlay(reason: reason)
        }
    }

    private func protocolFamily(for packet: Data) -> NSNumber? {
        return ipPacketProtocolFamily(for: packet)
    }
}

// MARK: - Go Tunnel Config Callback

#if canImport(Libtailscale)
import Libtailscale

/// Implements Go's TunnelConfigCallback interface.
class GoTunnelConfigCallback: NSObject, LibtailscaleTunnelConfigCallbackProtocol {
    private let handler: (Data) -> Void

    init(_ handler: @escaping (Data) -> Void) {
        self.handler = handler
    }

    func onTunnelConfigUpdate(_ configJSON: Data?) throws {
        guard let configJSON = configJSON else { return }
        handler(configJSON)
    }
}

#endif
