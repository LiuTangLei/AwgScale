import Darwin
import Foundation
import NetworkExtension
import os

/// Packet Tunnel Provider — hosts the Go backend and manages the VPN tunnel.
///
/// This runs in a separate process from the main App.
/// Do NOT use UIApplication, shared global state, or any App-process APIs here.
class PacketTunnelProvider: NEPacketTunnelProvider {

    private struct TunnelSettingsRequest {
        let settings: NEPacketTunnelNetworkSettings
        let completion: ((Error?) -> Void)?
    }

    private let logger = Logger(subsystem: "com.tailscale.ipn.ios", category: "tunnel")
    private var notifyHandle: NotificationHandle?
    private var tunnelConfigCallback: AnyObject?
    private let packetQueue = DispatchQueue(label: "com.tailscale.ipn.ios.packetflow", qos: .userInitiated)
    private let packetQueueKey = DispatchSpecificKey<Void>()
    private var packetReadLoopRunning = false
    private let tunnelSettingsQueue = DispatchQueue(label: "com.tailscale.ipn.ios.tunnel-settings")
    private var tunnelStopping = false
    private var tunnelSettingsInFlight = false
    private var pendingTunnelSettings: TunnelSettingsRequest?

    override init() {
        super.init()
        packetQueue.setSpecific(key: packetQueueKey, value: ())
    }

    // MARK: - Lifecycle

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        logger.log("startTunnel: beginning")
        resetTunnelLifecycleState()
        sharedDefaults?.removeObject(forKey: IPCConstants.keyLastError)
        writeSharedState(ipnState: 4) // IpnState.starting

        // 1. Determine data directory inside App Group container
        guard let containerURL = sharedContainerURL else {
            completeStartWithError("No App Group container", code: 1, completionHandler: completionHandler)
            return
        }

        let dataDir = containerURL.appendingPathComponent("tailscale", isDirectory: true).path
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

        // 4. Register tunnel config callback so Go backend can push route/DNS changes
        #if canImport(Libtailscale)
        if let app = GoBridge.application {
            let configCb = GoTunnelConfigCallback { [weak self] configJSON in
                self?.handleTunnelConfigUpdate(configJSON)
            }
            tunnelConfigCallback = configCb
            LibtailscaleSetTunnelConfigCallback(app, configCb)
        }
        #endif

        // 5. Subscribe to WatchNotifications to track state
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

        // 6. Configure initial tunnel settings
        //    Real settings update from Go backend via TunnelConfigCallback.
        let settings = createInitialTunnelSettings()
        enqueueTunnelSettingsUpdate(settings) { [weak self] error in
            if let error = error {
                self?.logger.error("startTunnel: setTunnelNetworkSettings failed: \(error.localizedDescription)")
                self?.publishLastError("setTunnelNetworkSettings failed: \(error.localizedDescription)")
                completionHandler(error)
                return
            }
            self?.logger.log("startTunnel: tunnel settings applied")
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
            updateTunnelSettings(settings)
            let hasDefaultRoute = config.routes.contains { $0 == "0.0.0.0/0" || $0 == "::/0" }
            logger.log("tunnel config updated: \(config.localAddresses.count) addrs, \(config.routes.count) routes, \(config.excludeRoutes?.count ?? 0) excluded, \(config.dnsServers.count) DNS, defaultRoute=\(hasDefaultRoute)")
        } catch {
            logger.error("handleTunnelConfigUpdate: decode failed: \(error.localizedDescription)")
            sharedDefaults?.set("Tunnel config error: \(error.localizedDescription)",
                               forKey: IPCConstants.keyLastError)
            postDarwinNotification(IPCConstants.notifyStateChanged)
        }
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
                dns.matchDomains = [""] // Primary resolver for Tailscale DNS.
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

            case .startLoginInteractive:
                handleStartLoginInteractive(completionHandler: completionHandler)
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

        Task {
            do {
                let apiResp = try await GoBridge.callLocalAPI(
                    timeoutMillis: timeout,
                    method: method,
                    endpoint: endpoint,
                    body: body
                )
                let resp = IPCResponse.success(statusCode: apiResp.statusCode, body: apiResp.body)
                completionHandler?(try? JSONEncoder().encode(resp))
            } catch {
                logger.error("LocalAPI \(method) \(endpoint) failed: \(error.localizedDescription)")
                sharedDefaults?.set(error.localizedDescription, forKey: IPCConstants.keyLastError)
                postDarwinNotification(IPCConstants.notifyStateChanged)
                let resp = IPCResponse.failure(error.localizedDescription)
                completionHandler?(try? JSONEncoder().encode(resp))
            }
        }
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

    // MARK: - Notification Handling

    /// Process ipn.Notify JSON from Go backend.
    /// Writes relevant state to App Group UserDefaults and posts Darwin notification.
    private func handleNotification(_ data: Data) {
        do {
            let notify = try JSONDecoder().decode(IpnNotify.self, from: data)
            sharedDefaults?.removeObject(forKey: IPCConstants.keyLastError)

            if let stateInt = notify.State {
                writeSharedState(ipnState: stateInt)
            }

            if let prefs = notify.Prefs {
                if let prefsData = try? JSONEncoder().encode(prefs) {
                    sharedDefaults?.set(String(data: prefsData, encoding: .utf8), forKey: IPCConstants.keyPrefsJSON)
                }
            }

            if let netMap = notify.NetMap {
                if let netMapData = try? JSONEncoder().encode(netMap) {
                    sharedDefaults?.set(String(data: netMapData, encoding: .utf8), forKey: IPCConstants.keyNetMapJSON)
                }
            }

            if let url = notify.BrowseToURL {
                sharedDefaults?.set(url, forKey: IPCConstants.keyBrowseToURL)
            }

            if notify.LoginFinished != nil {
                sharedDefaults?.set(true, forKey: IPCConstants.keyLoginFinished)
                sharedDefaults?.removeObject(forKey: IPCConstants.keyBrowseToURL)
            }

            if let health = notify.Health {
                if let healthData = try? JSONEncoder().encode(health) {
                    sharedDefaults?.set(String(data: healthData, encoding: .utf8), forKey: IPCConstants.keyHealthJSON)
                }
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

    private func writeSharedState(ipnState: Int) {
        sharedDefaults?.set(ipnState, forKey: IPCConstants.keyIPNState)
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
    func updateTunnelSettings(_ settings: NEPacketTunnelNetworkSettings) {
        enqueueTunnelSettingsUpdate(settings) { [weak self] error in
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
        if DispatchQueue.getSpecific(key: packetQueueKey) != nil {
            packetReadLoopRunning = false
        } else {
            packetQueue.sync {
                packetReadLoopRunning = false
            }
        }
        tunnelSettingsQueue.sync {
            tunnelStopping = false
            tunnelSettingsInFlight = false
            pendingTunnelSettings = nil
        }
    }

    private func markTunnelStopping() {
        tunnelSettingsQueue.sync {
            tunnelStopping = true
            pendingTunnelSettings = nil
        }
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

    private func enqueueTunnelSettingsUpdate(_ settings: NEPacketTunnelNetworkSettings,
                                             completion: ((Error?) -> Void)? = nil) {
        tunnelSettingsQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.tunnelStopping else {
                completion?(nil)
                return
            }
            let request = TunnelSettingsRequest(settings: settings, completion: completion)
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
                if let error = error {
                    self?.logger.error("setTunnelNetworkSettings failed: \(error.localizedDescription)")
                }
                request.completion?(error)
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

        packetQueue.async { [weak self] in
            guard let self = self, !self.packetReadLoopRunning else { return }
            self.packetReadLoopRunning = true
            self.readPacketsFromFlow()
        }
    }

    private func stopPacketBridge() {
        if DispatchQueue.getSpecific(key: packetQueueKey) != nil {
            packetReadLoopRunning = false
        } else {
            packetQueue.sync {
                packetReadLoopRunning = false
            }
        }
        GoBridge.clearPacketCallback()
    }

    private func readPacketsFromFlow() {
        guard packetReadLoopRunning else { return }
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self = self else { return }
            self.packetQueue.async {
                guard self.packetReadLoopRunning else { return }
                for packet in packets {
                    do {
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
        packetQueue.async { [weak self] in
            guard let self = self, self.packetReadLoopRunning else { return }
            guard let protocolFamily = self.protocolFamily(for: packet) else {
                self.logger.error("dropping packet with unknown IP version")
                return
            }
            self.packetFlow.writePackets([packet], withProtocols: [protocolFamily])
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
