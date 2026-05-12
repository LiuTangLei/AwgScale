import Foundation

private enum LoginFlowError: Error, LocalizedError {
    case missingPrefsResponse
    case localAPI(String)

    var errorDescription: String? {
        switch self {
        case .missingPrefsResponse:
            return "Control server preferences were not returned by LocalAPI"
        case .localAPI(let message):
            return message
        }
    }
}

private let appInstallMarkerKey = "com.tailscale.ipn.ios.install-marker.v1"

private extension IpnState {
    init?(backendState: String) {
        switch backendState {
        case "NoState": self = .noState
        case "NeedsLogin": self = .needsLogin
        case "NeedsMachineAuth": self = .needsMachineAuth
        case "Stopped": self = .stopped
        case "Starting": self = .starting
        case "Running": self = .running
        default: return nil
        }
    }
}

/// App-wide state container driven by ipn.Notify events.
///
/// In the dual-process architecture:
/// - Extension receives Notify from Go backend → writes to App Group UserDefaults
/// - Extension posts Darwin notification ("state changed")
/// - App's AppState observes Darwin notification → reads from App Group UserDefaults
///
/// This replaces single-process global state with app/extension IPC state.
/// All updates must happen on @MainActor since SwiftUI observes this.
@MainActor
class AppState: ObservableObject {
    // MARK: - Published State

    @Published var ipnState: IpnState = .noState
    @Published var currentProfile: LoginProfile?
    @Published var prefs: IpnPrefs?
    @Published var selfNode: PeerNode?
    @Published var peers: [PeerNode] = []
    @Published var health: HealthState?
    @Published var lastError: String?
    @Published var isLoggingIn: Bool = false
    @Published var isAwaitingMachineAuth: Bool = false
    @Published var browseToURL: String?

    // MARK: - AWG State

    /// Per-peer AWG config status: normalizedHostname → hasAwgConfig
    @Published var awgPeersStatus: [String: Bool] = [:]
    /// Per-peer AWG config data: normalizedHostname → AwgPeerResult
    @Published var awgPeersData: [String: AwgPeerResult] = [:]
    /// Whether the local machine has non-default AWG config
    @Published var localAwgStatus: Bool = false
    /// Local AWG config from prefs, if present.
    @Published var currentAwgConfig: AmneziaWGPrefs?
    /// Toast-style status message for AWG operations
    @Published var awgStatusMessage: String?
    /// Hostname of peer currently being synced (nil if no sync in progress)
    @Published var awgSyncInProgress: String?
    /// Whether AWG peers have been loaded (prevent duplicate requests)
    private var awgPeersLoaded = false
    private var awgPeersLoading = false
    private var awgLastRefresh: Date?
    private let awgRefreshInterval: TimeInterval = 30

    /// Reference to VPNManager for IPC. Set by TailscaleApp at launch.
    weak var vpnManager: VPNManager?
    private let loginBackend = AppLoginBackend()
    private var isCompletingAppLogin = false
    private var loginCompletionPollTask: Task<Void, Never>?
    private var loginMayRequireMachineAuth = false

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.1"
    }

    var hasVisibleSession: Bool {
        currentProfile != nil || selfNode != nil || !peers.isEmpty || awgSyncInProgress != nil
    }

    var shouldShowLoginView: Bool {
        !hasVisibleSession && (ipnState == .noState || ipnState == .needsLogin || ipnState == .needsMachineAuth)
    }

    // MARK: - Initialization

    init() {
        resetPersistedStateAfterFreshInstallIfNeeded()

        // Load initial state from App Group
        loadSharedState()

        // Observe Darwin notifications from Extension
        observeDarwinNotification(IPCConstants.notifyStateChanged) { [weak self] in
            Task { @MainActor in
                self?.loadSharedState()
            }
        }
    }

    // MARK: - Shared State Reading (from App Group UserDefaults)

    private func resetPersistedStateAfterFreshInstallIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: appInstallMarkerKey) else { return }

        clearSharedLoginState()
        clearPersistedGoState()
        defaults.set(true, forKey: appInstallMarkerKey)
    }

    private func clearSharedLoginState() {
        guard let defaults = sharedDefaults else { return }
        let keys = [
            IPCConstants.keyPrefsJSON,
            IPCConstants.keyNetMapJSON,
            IPCConstants.keyBrowseToURL,
            IPCConstants.keyLoginFinished,
            IPCConstants.keyHealthJSON,
            IPCConstants.keySelfNodeJSON,
            IPCConstants.keyLastError,
            IPCConstants.keyCurrentProfileID,
        ]
        keys.forEach { defaults.removeObject(forKey: $0) }
        defaults.set(IpnState.needsLogin.rawValue, forKey: IPCConstants.keyIPNState)
        defaults.synchronize()
        postDarwinNotification(IPCConstants.notifyStateChanged)
    }

    private func clearInMemorySessionState() {
        ipnState = .needsLogin
        currentProfile = nil
        prefs = nil
        selfNode = nil
        peers = []
        health = nil
        lastError = nil
        browseToURL = nil
        isLoggingIn = false
        isAwaitingMachineAuth = false
        isCompletingAppLogin = false
        loginMayRequireMachineAuth = false
        awgPeersStatus = [:]
        awgPeersData = [:]
        localAwgStatus = false
        currentAwgConfig = nil
        awgStatusMessage = nil
        awgSyncInProgress = nil
        awgPeersLoaded = false
        awgPeersLoading = false
        awgLastRefresh = nil
    }

    /// Read state written by the Packet Tunnel Extension.
    func loadSharedState() {
        guard let defaults = sharedDefaults else { return }

        // ipn.State
        let stateRaw = defaults.integer(forKey: IPCConstants.keyIPNState)
        if let state = IpnState(rawValue: stateRaw) {
            ipnState = state
        }

        // Prefs
        if let prefsStr = defaults.string(forKey: IPCConstants.keyPrefsJSON),
           let prefsData = prefsStr.data(using: .utf8) {
            prefs = try? JSONDecoder().decode(IpnPrefs.self, from: prefsData)
        }

        // NetMap
        if let netMapStr = defaults.string(forKey: IPCConstants.keyNetMapJSON),
           let netMapData = netMapStr.data(using: .utf8) {
            if let netMap = try? JSONDecoder().decode(NetworkMap.self, from: netMapData) {
                updatePeers(from: netMap)
            }
        }

        // BrowseToURL (login)
        let newBrowseURL = defaults.string(forKey: IPCConstants.keyBrowseToURL)
        if newBrowseURL != browseToURL {
            browseToURL = newBrowseURL
        }

        // LoginFinished
        if defaults.bool(forKey: IPCConstants.keyLoginFinished) {
            isLoggingIn = false
            browseToURL = nil
            defaults.removeObject(forKey: IPCConstants.keyLoginFinished)
            finishAppLogin()
        }

        // Health
        if let healthStr = defaults.string(forKey: IPCConstants.keyHealthJSON),
           let healthData = healthStr.data(using: .utf8) {
            health = try? JSONDecoder().decode(HealthState.self, from: healthData)
        }

        // Last error
        lastError = defaults.string(forKey: IPCConstants.keyLastError)
    }

    // MARK: - Notify Processing (direct, for Extension-side use)

    /// Process an ipn.Notify JSON payload from Go backend.
    func handleNotify(_ data: Data) {
        do {
            let notify = try JSONDecoder().decode(IpnNotify.self, from: data)
            applyNotify(notify)
        } catch {
            lastError = "Failed to decode notification: \(error.localizedDescription)"
        }
    }

    private func applyNotify(_ notify: IpnNotify, fromLoginBackend: Bool = false) {
        if let stateInt = notify.State, let state = IpnState(rawValue: stateInt) {
            ipnState = state
            if state == .needsMachineAuth && fromLoginBackend {
                isAwaitingMachineAuth = true
                startLoginCompletionPolling()
            }
        }

        if let prefs = notify.Prefs {
            self.prefs = prefs
        }

        if let netMap = notify.NetMap {
            updatePeers(from: netMap)
        }

        if let url = notify.BrowseToURL {
            browseToURL = url
        }

        if notify.LoginFinished != nil {
            isLoggingIn = false
            browseToURL = nil
            finishAppLogin()
        }

        if let health = notify.Health, !fromLoginBackend || vpnManager?.isTunnelActive == true {
            self.health = health
        }
    }

    private func updatePeers(from netMap: NetworkMap) {
        var allPeers: [PeerNode] = []

        // Self node
        if let selfData = netMap.SelfNode {
            let userProfile = selfData.UserID.flatMap { uid in
                netMap.UserProfiles?[String(uid)]
            }
            let self_ = PeerNode(from: selfData, isSelf: true, userProfile: userProfile)
            selfNode = self_
            allPeers.append(self_)
        }

        // Peer nodes
        if let peerNodes = netMap.Peers {
            for peerData in peerNodes {
                let userProfile = peerData.UserID.flatMap { uid in
                    netMap.UserProfiles?[String(uid)]
                }
                allPeers.append(PeerNode(from: peerData, isSelf: false, userProfile: userProfile))
            }
        }

        peers = allPeers

        if !allPeers.isEmpty {
            loadAwgStatusIfNeeded()
        }
    }

    private func callActiveLocalAPI(method: String, endpoint: String, body: Data? = nil, timeout: Int = 30000) async throws -> IPCResponse {
        if let vpn = vpnManager {
            _ = await vpn.refreshStatus()
            if vpn.isTunnelActive {
                return try await vpn.callLocalAPI(method: method, endpoint: endpoint, body: body, timeout: timeout)
            }
        }

        if loginBackend.isRunning {
            return try await loginBackend.callLocalAPI(method: method, endpoint: endpoint, body: body, timeout: timeout)
        }

        try await ensureAppBackendReadyForControlPlane()
        return try await loginBackend.callLocalAPI(method: method, endpoint: endpoint, body: body, timeout: timeout)
    }

    private func ensureAppBackendReadyForControlPlane() async throws {
        if loginBackend.isRunning { return }

        try await loginBackend.start { [weak self] data in
            self?.handleLoginBackendNotify(data)
        }

        guard let backendState = await loginBackendState() else {
            loginBackend.stop()
            throw LoginFlowError.localAPI("No active backend")
        }

        ipnState = backendState
        switch backendState {
        case .needsLogin, .noState:
            loginBackend.stop()
            throw LoginFlowError.localAPI("No active backend")
        case .needsMachineAuth:
            loginBackend.stop()
            throw LoginFlowError.localAPI("Machine authorization pending")
        default:
            isAwaitingMachineAuth = false
            loginMayRequireMachineAuth = false
            await fetchCurrentProfileFromLoginBackend()
        }
    }

    // MARK: - User Actions (via VPNManager IPC)

    /// Start interactive login flow without enabling the system VPN tunnel.
    /// Login runs a temporary in-app Go backend so the browser auth flow can
    /// complete before the user chooses to turn Tailscale on.
    func startLogin(controlURL: String = "") {
        guard !isLoggingIn else { return }

        loginBackend.stop()
        loginCompletionPollTask?.cancel()
        loginCompletionPollTask = nil
        isLoggingIn = true
        isAwaitingMachineAuth = false
        loginMayRequireMachineAuth = !controlURL.isEmpty
        lastError = nil

        Task {
            do {
                try await loginBackend.start { [weak self] data in
                    self?.handleLoginBackendNotify(data)
                }
            } catch {
                lastError = "Login backend failed to start: \(describeError(error))"
                isLoggingIn = false
                return
            }

            await setLoginBackendWantRunning(false)

            // If a custom control URL is provided, set it before login
            if !controlURL.isEmpty {
                do {
                    let prefs = MaskedPrefs.setControlURL(controlURL)
                    let updatedPrefsData = try await editLoginBackendPrefs(prefs)
                    try await startLoginBackend(updatePrefsData: updatedPrefsData)
                } catch {
                    lastError = "Failed to set control server: \(describeError(error))"
                    isLoggingIn = false
                    loginBackend.stop()
                    return
                }
            }

            do {
                let resp = try await loginBackend.startLoginInteractive()
                if let error = resp.error {
                    lastError = "Login request failed: \(error)"
                    isLoggingIn = false
                    loginBackend.stop()
                }
            } catch {
                lastError = "Login request failed: \(describeError(error))"
                isLoggingIn = false
                loginBackend.stop()
            }
        }
    }

    private func editLoginBackendPrefs(_ prefs: MaskedPrefs) async throws -> Data {
        let body = try JSONEncoder().encode(prefs)
        let resp = try await loginBackend.callLocalAPI(method: "PATCH", endpoint: "/localapi/v0/prefs", body: body)
        if let error = resp.error {
            throw LoginFlowError.localAPI(error)
        }
        guard (200..<300).contains(resp.statusCode) else {
            throw LoginFlowError.localAPI("HTTP \(resp.statusCode)")
        }
        guard let bodyB64 = resp.bodyBase64, let bodyData = Data(base64Encoded: bodyB64) else {
            throw LoginFlowError.missingPrefsResponse
        }
        return bodyData
    }

    private func startLoginBackend(updatePrefsData: Data) async throws {
        let updatePrefs = try JSONSerialization.jsonObject(with: updatePrefsData)
        let body = try JSONSerialization.data(withJSONObject: ["UpdatePrefs": updatePrefs])
        let resp = try await loginBackend.callLocalAPI(method: "POST", endpoint: "/localapi/v0/start", body: body, readBody: false)
        if let error = resp.error {
            throw LoginFlowError.localAPI(error)
        }
        guard (200..<300).contains(resp.statusCode) else {
            throw LoginFlowError.localAPI("HTTP \(resp.statusCode)")
        }
    }

    private func describeError(_ error: Error) -> String {
        let nsError = error as NSError
        var parts = [nsError.localizedDescription]
        parts.append("domain=\(nsError.domain)")
        parts.append("code=\(nsError.code)")
        if !nsError.userInfo.isEmpty {
            parts.append("userInfo=\(nsError.userInfo)")
        }
        parts.append("debug=\(String(reflecting: error))")
        return parts.joined(separator: "; ")
    }

    private func handleLoginBackendNotify(_ data: Data) {
        do {
            let notify = try JSONDecoder().decode(IpnNotify.self, from: data)
            applyNotify(notify, fromLoginBackend: true)
        } catch {
            lastError = "Failed to decode notification: \(error.localizedDescription)"
        }
    }

    func loginBrowserDidDismiss() {
        browseToURL = nil
        if loginMayRequireMachineAuth {
            isAwaitingMachineAuth = true
            ipnState = .needsMachineAuth
        }
        startLoginCompletionPolling()
    }

    private func finishAppLogin() {
        guard loginBackend.isRunning else {
            fetchCurrentProfile()
            return
        }
        guard !isCompletingAppLogin else { return }

        loginCompletionPollTask?.cancel()
        loginCompletionPollTask = nil
        isCompletingAppLogin = true
        Task {
            let backendState = await loginBackendState()
            if backendState == .needsMachineAuth ||
                (loginMayRequireMachineAuth && (backendState == .needsLogin || backendState == .noState)) {
                ipnState = .needsMachineAuth
                isAwaitingMachineAuth = true
                isCompletingAppLogin = false
                startLoginCompletionPolling()
                return
            }

            await fetchCurrentProfileFromLoginBackend()
            var finalBackendState = backendState
            if finalBackendState == nil {
                finalBackendState = await loginBackendState()
            }
            if let finalBackendState = finalBackendState {
                ipnState = finalBackendState
            }
            isAwaitingMachineAuth = false
            loginMayRequireMachineAuth = false
            isLoggingIn = false
            isCompletingAppLogin = false
        }
    }

    func resumeAppBackendIfNeeded(vpnActive: Bool) {
        guard !vpnActive, !loginBackend.isRunning, !isLoggingIn else { return }

        Task {
            do {
                try await loginBackend.start { [weak self] data in
                    self?.handleLoginBackendNotify(data)
                }
            } catch {
                return
            }

            guard let backendState = await loginBackendState() else {
                loginBackend.stop()
                return
            }

            ipnState = backendState

            switch backendState {
            case .needsLogin, .noState:
                loginBackend.stop()
            case .needsMachineAuth:
                isAwaitingMachineAuth = true
                startLoginCompletionPolling()
            default:
                isAwaitingMachineAuth = false
                loginMayRequireMachineAuth = false
                await fetchCurrentProfileFromLoginBackend()
            }
        }
    }

    func foregroundResume(vpnActive: Bool) {
        if vpnActive {
            loginCompletionPollTask?.cancel()
            loginCompletionPollTask = nil
            isLoggingIn = false
            browseToURL = nil
            loginBackend.stop()
            Task {
                await refreshTunnelStatus()
            }
            return
        }

        resumeAppBackendIfNeeded(vpnActive: false)
    }

    func refreshTunnelStatus() async {
        guard let vpn = vpnManager else { return }

        do {
            let resp = try await vpn.callLocalAPI(method: "GET", endpoint: "/localapi/v0/status", timeout: 3000)
            guard resp.statusCode == 200,
                  let bodyB64 = resp.bodyBase64,
                  let bodyData = Data(base64Encoded: bodyB64),
                  let json = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
                return
            }

            if let backendState = json["BackendState"] as? String,
               let state = IpnState(backendState: backendState) {
                ipnState = state
            }

            if ipnState != .needsLogin && ipnState != .noState {
                await fetchCurrentProfileFromVPNBackend()
            }

            lastError = nil
        } catch {
            // The tunnel can be connecting when the app first becomes active.
        }
    }

    private func startLoginCompletionPolling() {
        guard loginCompletionPollTask == nil else { return }

        loginCompletionPollTask = Task { [weak self] in
            guard let self else { return }

            for _ in 0..<120 {
                guard !Task.isCancelled,
                      self.loginBackend.isRunning,
                      self.isLoggingIn || self.ipnState == .needsMachineAuth else { break }

                if await self.loginBackendHasCompletedLogin() {
                    self.browseToURL = nil
                    self.finishAppLogin()
                    return
                }

                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }

            if !Task.isCancelled {
                self.loginCompletionPollTask = nil
            }
        }
    }

    private func loginBackendHasCompletedLogin() async -> Bool {
        guard let backendState = await loginBackendState() else { return false }

        switch backendState {
        case .needsLogin, .noState, .needsMachineAuth:
            return false
        default:
            return true
        }
    }

    private func loginBackendState() async -> IpnState? {
        guard let status = await loginBackendStatusJSON(),
              let backendState = status["BackendState"] as? String else {
            return nil
        }

        return IpnState(backendState: backendState)
    }

    private func loginBackendStatusJSON(timeout: Int = 3000) async -> [String: Any]? {
        do {
            let resp = try await loginBackend.callLocalAPI(method: "GET", endpoint: "/localapi/v0/status", timeout: timeout)
            guard resp.statusCode == 200,
                  let bodyB64 = resp.bodyBase64,
                  let bodyData = Data(base64Encoded: bodyB64),
                  let json = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
                return nil
            }

            return json
        } catch {
            return nil
        }
    }

    func refreshMachineAuthStatus() async -> Bool {
        if loginBackend.isRunning {
            guard let backendState = await loginBackendState() else { return false }
            ipnState = backendState

            switch backendState {
            case .needsMachineAuth:
                isAwaitingMachineAuth = true
                return false
            case .needsLogin, .noState:
                return false
            default:
                isLoggingIn = false
                isAwaitingMachineAuth = false
                loginMayRequireMachineAuth = false
                browseToURL = nil
                finishAppLogin()
                return true
            }
        }

        loadSharedState()
        return ipnState != .needsMachineAuth
    }

    func loadMachineAuthDeviceInfo() async -> (hostname: String, nodeKey: String?)? {
        if loginBackend.isRunning,
           let status = await loginBackendStatusJSON(),
           let selfStatus = status["Self"] as? [String: Any] {
            return (
                hostname: selfStatus["HostName"] as? String ?? "Unknown",
                nodeKey: selfStatus["PublicKey"] as? String
            )
        }

        guard let vpn = vpnManager else { return nil }

        do {
            let resp = try await vpn.callLocalAPI(method: "GET", endpoint: "/localapi/v0/status")
            guard resp.statusCode == 200,
                  let bodyB64 = resp.bodyBase64,
                  let bodyData = Data(base64Encoded: bodyB64),
                  let json = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
                  let selfStatus = json["Self"] as? [String: Any] else { return nil }

            return (
                hostname: selfStatus["HostName"] as? String ?? "Unknown",
                nodeKey: selfStatus["PublicKey"] as? String
            )
        } catch {
            return nil
        }
    }

    private func setLoginBackendWantRunning(_ wantRunning: Bool) async {
        do {
            let prefs = MaskedPrefs.setWantRunning(wantRunning)
            let body = try JSONEncoder().encode(prefs)
            let _ = try await loginBackend.callLocalAPI(method: "PATCH", endpoint: "/localapi/v0/prefs", body: body)
        } catch {
            lastError = "Failed to update login preferences: \(error.localizedDescription)"
        }
    }

    private func waitForBackendReady(_ vpn: VPNManager) async -> String? {
        var lastReadinessError = vpn.lastError

        for _ in 0..<75 {
            if let extensionError = sharedDefaults?.string(forKey: IPCConstants.keyLastError), !extensionError.isEmpty {
                lastReadinessError = extensionError
            }

            do {
                let resp = try await vpn.callLocalAPI(
                    method: "GET",
                    endpoint: "/localapi/v0/status",
                    timeout: 1000
                )
                if resp.error == nil {
                    return nil
                }
                lastReadinessError = resp.error
            } catch {
                lastReadinessError = error.localizedDescription
            }

            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        return lastReadinessError ?? "timed out waiting for LocalAPI"
    }

    /// Log out and clear all state.
    func logout() {
        loginCompletionPollTask?.cancel()
        loginCompletionPollTask = nil
        clearInMemorySessionState()
        clearSharedLoginState()
        clearPersistedGoState()
        loginBackend.stop()

        Task {
            if let vpn = vpnManager {
                _ = try? await vpn.callLocalAPI(method: "POST", endpoint: "/localapi/v0/logout")
                vpn.disconnect()
            }

            clearSharedLoginState()
            clearPersistedGoState()
            clearInMemorySessionState()
        }
    }

    func cancelLogin() {
        logout()
    }

    /// Toggle VPN on/off via prefs edit.
    func setWantRunning(_ wantRunning: Bool) {
        guard let vpn = vpnManager else { return }

        // Also tell Go backend about the preference change
        Task {
            do {
                if wantRunning {
                    lastError = nil
                    ipnState = .starting
                    sharedDefaults?.removeObject(forKey: IPCConstants.keyLastError)
                    sharedDefaults?.set(IpnState.starting.rawValue, forKey: IPCConstants.keyIPNState)
                    loginCompletionPollTask?.cancel()
                    loginCompletionPollTask = nil
                    loginBackend.stop()
                    try await vpn.connectTunnel()
                    if let readinessError = await waitForBackendReady(vpn) {
                        throw VPNError.backendNotReady(readinessError)
                    }
                }

                let prefs = MaskedPrefs.setWantRunning(wantRunning)
                let body = try JSONEncoder().encode(prefs)
                let _ = try await vpn.callLocalAPI(method: "PATCH", endpoint: "/localapi/v0/prefs", body: body)

                if wantRunning {
                    await refreshTunnelStatus()
                } else {
                    vpn.disconnect()
                    resumeAppBackendIfNeeded(vpnActive: false)
                }
            } catch {
                lastError = "Failed to update preferences: \(error.localizedDescription)"
                if wantRunning {
                    vpn.disconnect()
                }
            }
        }
    }

    /// Fetch the current login profile from the backend.
    func fetchCurrentProfile() {
        guard let vpn = vpnManager else { return }

        Task {
            do {
                let resp = try await vpn.callLocalAPI(method: "GET", endpoint: "/localapi/v0/profiles/current")
                if resp.statusCode == 200,
                   let bodyB64 = resp.bodyBase64,
                   let bodyData = Data(base64Encoded: bodyB64) {
                    let profile = try JSONDecoder().decode(LoginProfile.self, from: bodyData)
                    currentProfile = profile
                }
            } catch {
                // Profile fetch is best-effort; don't show error to user
            }
        }
    }

    private func fetchCurrentProfileFromVPNBackend() async {
        guard let vpn = vpnManager else { return }

        do {
            let resp = try await vpn.callLocalAPI(method: "GET", endpoint: "/localapi/v0/profiles/current")
            if resp.statusCode == 200,
               let bodyB64 = resp.bodyBase64,
               let bodyData = Data(base64Encoded: bodyB64) {
                let profile = try JSONDecoder().decode(LoginProfile.self, from: bodyData)
                currentProfile = profile
            }
        } catch {
            // Profile fetch is best-effort; the tunnel status is authoritative for routing.
        }
    }

    private func fetchCurrentProfileFromLoginBackend() async {
        do {
            let resp = try await loginBackend.callLocalAPI(method: "GET", endpoint: "/localapi/v0/profiles/current")
            if resp.statusCode == 200,
               let bodyB64 = resp.bodyBase64,
               let bodyData = Data(base64Encoded: bodyB64) {
                let profile = try JSONDecoder().decode(LoginProfile.self, from: bodyData)
                currentProfile = profile
            }
        } catch {
            // Profile fetch is best-effort; login state has already been saved by the backend.
        }
    }

    // MARK: - AWG Sync

    /// Load AWG config status for all peers via awg-sync-peers endpoint.
    func loadAwgPeersStatus() {
        refreshAwgStatus(showMessages: true, force: true)
    }

    /// Load local machine AWG configuration status from prefs.
    func loadLocalAwgStatus() {
        refreshAwgStatus(showMessages: true, force: true)
    }

    func refreshAwgStatus(showMessages: Bool = true, force: Bool = true) {
        guard !peers.isEmpty else { return }
        if !force, awgPeersLoaded, let awgLastRefresh,
           Date().timeIntervalSince(awgLastRefresh) < awgRefreshInterval {
            return
        }
        guard !awgPeersLoading else { return }

        awgPeersLoading = true
        Task {
            let loadedPeers = await loadAwgPeersStatusOnce(showMessages: showMessages)
            _ = await loadLocalAwgStatusOnce(showMessages: showMessages)
            if loadedPeers {
                awgPeersLoaded = true
                awgLastRefresh = Date()
            }
            awgPeersLoading = false
        }
    }

    private func loadAwgPeersStatusOnce(showMessages: Bool) async -> Bool {
        do {
            let resp = try await callActiveLocalAPI(method: "GET", endpoint: "/localapi/v0/awg-sync-peers")
            guard resp.statusCode == 200,
                  let bodyB64 = resp.bodyBase64,
                  let bodyData = Data(base64Encoded: bodyB64) else {
                if showMessages {
                    awgStatusMessage = responseErrorMessage(resp)
                }
                return false
            }

            let awgPeers = try JSONDecoder().decode([AwgPeerResult].self, from: bodyData)

            var statusMap: [String: Bool] = [:]
            var dataMap: [String: AwgPeerResult] = [:]

            for peer in awgPeers {
                for key in awgKeyCandidates(peer.nodeKey) {
                    statusMap[key] = (statusMap[key] == true) || peer.hasAwgConfig
                    dataMap[key] = preferredAwgPeer(existing: dataMap[key], new: peer)
                }
                for key in peerKeyCandidates(peer.hostname) {
                    statusMap[key] = (statusMap[key] == true) || peer.hasAwgConfig
                    dataMap[key] = preferredAwgPeer(existing: dataMap[key], new: peer)
                }
            }

            mergeAwgPeerStatus(statusMap: statusMap, dataMap: dataMap)

            if showMessages {
                let awgCount = awgPeers.filter(\.hasAwgConfig).count
                let total = awgPeers.count
                if total > 0 {
                    awgStatusMessage = awgCount > 0
                        ? "Found \(awgCount)/\(total) peers with AWG config"
                        : "Checked \(total) peers, no AWG config found"
                } else {
                    awgStatusMessage = "No peers found"
                }
            }
            return true
        } catch {
            if showMessages {
                awgStatusMessage = "Failed to get AWG config info: \(error.localizedDescription)"
            }
            return false
        }
    }

    private func loadLocalAwgStatusOnce(showMessages: Bool) async -> Bool {
        do {
            let resp = try await callActiveLocalAPI(method: "GET", endpoint: "/localapi/v0/prefs")
            guard resp.statusCode == 200,
                  let bodyB64 = resp.bodyBase64,
                  let bodyData = Data(base64Encoded: bodyB64) else {
                localAwgStatus = false
                return false
            }

            let prefs = try JSONDecoder().decode(LocalPrefs.self, from: bodyData)
            currentAwgConfig = prefs.AmneziaWG
            localAwgStatus = currentAwgConfig?.hasNonDefaultValues == true
            return true
        } catch {
            localAwgStatus = false
            currentAwgConfig = nil
            if showMessages {
                awgStatusMessage = "Failed to get local AWG status: \(error.localizedDescription)"
            }
            return false
        }
    }

    func refreshLocalAwgStatusNow(showMessages: Bool = true) async {
        _ = await loadLocalAwgStatusOnce(showMessages: showMessages)
    }

    /// Load AWG status once per session when the network map is available.
    func loadAwgStatusIfNeeded() {
        guard !peers.isEmpty else { return }
        refreshAwgStatus(showMessages: false, force: false)
    }

    func refreshAwgStatusForTunnelChange() {
        guard !peers.isEmpty else { return }
        refreshAwgStatus(showMessages: false, force: true)
    }

    func peerHasAwgConfig(_ peer: PeerNode) -> Bool {
        if peer.isCurrentDevice {
            return localAwgStatus
        }
        return awgData(for: peer)?.hasAwgConfig == true
    }

    /// Sync AWG config from a remote peer to the local machine.
    func syncAwgConfigFromPeer(_ peer: PeerNode, timeout: Int = 10) {
        let hostname = peer.displayName

        // Verify peer has AWG config
        let peerData = awgData(for: peer)

        if let peerData, !peerData.hasAwgConfig {
            awgStatusMessage = "Peer \(hostname) has no AWG config"
            return
        }

        let fullNodeKey = fullNodeKeyForAwgSync(peer: peer, peerData: peerData)

        guard let nodeKey = fullNodeKey, !nodeKey.isEmpty else {
            awgStatusMessage = "Cannot find nodeKey for peer \(hostname)"
            return
        }

        awgSyncInProgress = hostname

        Task {
            do {
                let vpn = try await ensureVPNBackendReadyForAwgSync()
                let request = AwgSyncApplyRequest(nodeKey: nodeKey, timeout: timeout)
                let body = try JSONEncoder().encode(request)
                let resp = try await vpn.callLocalAPI(method: "POST", endpoint: "/localapi/v0/awg-sync-apply", body: body)

                guard resp.statusCode == 200,
                      let bodyB64 = resp.bodyBase64,
                      let bodyData = Data(base64Encoded: bodyB64) else {
                    let errMsg = responseErrorMessage(resp)
                    awgStatusMessage = parseAwgApplyError(errMsg, hostname: hostname)
                    awgSyncInProgress = nil
                    return
                }

                let appliedConfig = try JSONDecoder().decode(AmneziaWGPrefs.self, from: bodyData)
                currentAwgConfig = appliedConfig
                localAwgStatus = appliedConfig.hasNonDefaultValues
                awgStatusMessage = "AWG config from \(hostname) applied, restarting VPN..."
                let restarted = await autoReconnectForAwgConfig()
                _ = await loadLocalAwgStatusOnce(showMessages: false)
                if restarted {
                    awgStatusMessage = "AWG config from \(hostname) applied successfully"
                }
                awgSyncInProgress = nil
            } catch {
                awgSyncInProgress = nil
                awgStatusMessage = parseAwgApplyError(error.localizedDescription, hostname: hostname)
            }
        }
    }

    func clearAwgStatusMessage() {
        awgStatusMessage = nil
    }

    func applyManualAwgConfig(_ config: AmneziaWGPrefs) async throws {
        let prefs = MaskedPrefs.setAmneziaWG(config)
        let body = try JSONEncoder().encode(prefs)
        awgStatusMessage = config.hasNonDefaultValues ? "Applying AWG config..." : "Clearing AWG config..."

        var restartAttempted = false
        var resp: IPCResponse
        if let vpn = vpnManager {
            _ = await vpn.refreshStatus()
            if vpn.isTunnelActive {
                restartAttempted = true
                resp = try await vpn.callLocalAPI(method: "PATCH", endpoint: "/localapi/v0/prefs", body: body)
            } else {
                resp = try await callActiveLocalAPI(method: "PATCH", endpoint: "/localapi/v0/prefs", body: body)
            }
        } else {
            resp = try await callActiveLocalAPI(method: "PATCH", endpoint: "/localapi/v0/prefs", body: body)
        }

        guard resp.statusCode == 200 else {
            throw LoginFlowError.localAPI(responseErrorMessage(resp))
        }

        currentAwgConfig = config
        localAwgStatus = config.hasNonDefaultValues

        var restarted = false
        if restartAttempted {
            restarted = await autoReconnectForAwgConfig()
        }

        _ = await loadLocalAwgStatusOnce(showMessages: false)

        if restartAttempted && !restarted {
            throw LoginFlowError.localAPI(awgStatusMessage ?? "VPN restart failed")
        }

        if !restartAttempted || restarted {
            awgStatusMessage = config.hasNonDefaultValues ? "AWG config applied successfully" : "AWG config cleared"
        }
    }

    // MARK: - AWG Helpers

    private func autoReconnectForAwgConfig() async -> Bool {
        guard let vpn = vpnManager else { return false }
        vpn.disconnect()
        for _ in 0..<25 {
            _ = await vpn.refreshStatus()
            if !vpn.isTunnelActive { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        do {
            try await vpn.connectTunnel()
            if let readinessError = await waitForBackendReady(vpn) {
                awgStatusMessage = "AWG config applied but VPN restart failed: \(readinessError)"
                return false
            }
            await refreshTunnelStatus()
            return true
        } catch {
            awgStatusMessage = "AWG config applied but VPN restart failed: \(error.localizedDescription)"
            return false
        }
    }

    private func ensureVPNBackendReadyForAwgSync() async throws -> VPNManager {
        guard let vpn = vpnManager else {
            throw LoginFlowError.localAPI("VPN manager not available")
        }

        lastError = nil
        awgStatusMessage = "Preparing VPN for AWG sync..."
        loginBackend.stop()

        try await vpn.connectTunnel()
        if let readinessError = await waitForBackendReady(vpn) {
            throw VPNError.backendNotReady(readinessError)
        }
        await refreshTunnelStatus()
        return vpn
    }

    private func peerKeyCandidates(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let short = trimmed.components(separatedBy: ".").first ?? trimmed
        return uniqueAwgKeys([
            trimmed,
            trimmed.lowercased(),
            short,
            short.lowercased(),
        ])
    }

    private func awgKeyCandidates(_ value: String?) -> [String] {
        guard let value = value, !value.isEmpty else { return [] }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutPrefix = trimmed.hasPrefix("nodekey:") ? String(trimmed.dropFirst("nodekey:".count)) : trimmed
        let withoutBrackets = withoutPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var candidates = [trimmed, trimmed.lowercased(), withoutPrefix, withoutPrefix.lowercased(), withoutBrackets, withoutBrackets.lowercased()]
        if withoutBrackets.count >= 5 {
            let short = String(withoutBrackets.prefix(5))
            candidates.append(short)
            candidates.append(short.lowercased())
            candidates.append("[\(short)]")
            candidates.append("[\(short.lowercased())]")
        }
        return uniqueAwgKeys(candidates)
    }

    private func uniqueAwgKeys(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }

    private func awgData(for peer: PeerNode) -> AwgPeerResult? {
        let candidates = awgKeyCandidates(peer.nodeKey)
            + peerKeyCandidates(peer.hostname)
            + peerKeyCandidates(peer.displayName)
            + peerKeyCandidates(peer.normalizedHostname)
            + peerKeyCandidates(peer.computedName)
            + peerKeyCandidates(peer.hostinfoHostname)
        return candidates.lazy.compactMap { self.awgPeersData[$0] }.first
    }

    private func fullNodeKeyForAwgSync(peer: PeerNode, peerData: AwgPeerResult?) -> String? {
        let targetKey = peer.normalizedHostname
        let matchingPeerNodeKey = peers.first(where: {
            $0.normalizedHostname == targetKey
        })?.nodeKey

        let candidates = [
            peer.nodeKey,
            matchingPeerNodeKey,
            peerData?.nodeKey,
        ]

        return candidates.compactMap { $0 }
            .first { !$0.isEmpty && $0.hasPrefix("nodekey:") }
            ?? candidates.compactMap { $0 }.first { !$0.isEmpty }
    }

    private func responseErrorMessage(_ response: IPCResponse) -> String {
        if let bodyB64 = response.bodyBase64,
           let bodyData = Data(base64Encoded: bodyB64),
           let body = String(data: bodyData, encoding: .utf8),
           !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return body
        }
        return response.error ?? "Unknown error (status \(response.statusCode))"
    }

    private func preferredAwgPeer(existing: AwgPeerResult?, new: AwgPeerResult) -> AwgPeerResult {
        guard let existing = existing else { return new }
        if new.hasAwgConfig && !existing.hasAwgConfig {
            return new
        }
        return existing
    }

    private func mergeAwgPeerStatus(statusMap: [String: Bool], dataMap: [String: AwgPeerResult]) {
        for (key, value) in statusMap {
            awgPeersStatus[key] = (awgPeersStatus[key] == true) || value
        }
        for (key, peer) in dataMap {
            awgPeersData[key] = preferredAwgPeer(existing: awgPeersData[key], new: peer)
        }
    }

    private func parseAwgApplyError(_ message: String, hostname: String) -> String {
        if message.contains("405") || message.contains("only POST allowed") {
            return "Request method error"
        } else if message.contains("403") || message.contains("access denied") {
            return "Access denied"
        } else if message.contains("404") || message.contains("peer not found") {
            return "Peer \(hostname) not found or offline"
        } else if message.contains("409") || message.contains("no Amnezia-WG config") {
            return "Peer \(hostname) has no AWG config"
        } else if message.contains("500") {
            if message.contains("no netmap available") {
                return "Network map unavailable"
            } else if message.contains("failed to fetch config") {
                return "Cannot fetch config from peer"
            } else if message.contains("failed to apply config") {
                return "Config apply failed"
            }
            return "Server error: \(message)"
        } else if message.contains("timeout") || message.contains("Timeout") {
            return "Operation timeout, please retry"
        }
        return "AWG config apply failed: \(message)"
    }

    // MARK: - Exit Node
    // Note: iOS does not support running AS an exit node (only using exit nodes).
    // See: https://tailscale.com/kb/1103/exit-nodes

    /// Set the exit node to use for routing traffic.
    func setExitNode(_ peer: PeerNode) {
        Task {
            do {
                var maskedPrefs = MaskedPrefs()
                maskedPrefs.ExitNodeID = peer.id
                maskedPrefs.ExitNodeIDSet = true
                let body = try JSONEncoder().encode(maskedPrefs)
                let resp = try await callActiveLocalAPI(method: "PATCH", endpoint: "/localapi/v0/prefs", body: body)
                guard resp.statusCode == 200 else {
                    lastError = responseErrorMessage(resp)
                    return
                }
                await refreshPrefsFromActiveBackend()
            } catch {
                lastError = "Failed to set exit node: \(error.localizedDescription)"
            }
        }
    }

    /// Clear the current exit node (stop using any exit node).
    func clearExitNode() {
        Task {
            do {
                var maskedPrefs = MaskedPrefs()
                maskedPrefs.ExitNodeID = ""
                maskedPrefs.ExitNodeIDSet = true
                let body = try JSONEncoder().encode(maskedPrefs)
                let resp = try await callActiveLocalAPI(method: "PATCH", endpoint: "/localapi/v0/prefs", body: body)
                guard resp.statusCode == 200 else {
                    lastError = responseErrorMessage(resp)
                    return
                }
                await refreshPrefsFromActiveBackend()
            } catch {
                lastError = "Failed to clear exit node: \(error.localizedDescription)"
            }
        }
    }

    /// Set allow LAN access when using exit node.
    func setExitNodeAllowLANAccess(_ allow: Bool) {
        Task {
            do {
                var maskedPrefs = MaskedPrefs()
                maskedPrefs.ExitNodeAllowLANAccess = allow
                maskedPrefs.ExitNodeAllowLANAccessSet = true
                let body = try JSONEncoder().encode(maskedPrefs)
                let resp = try await callActiveLocalAPI(method: "PATCH", endpoint: "/localapi/v0/prefs", body: body)
                guard resp.statusCode == 200 else {
                    lastError = responseErrorMessage(resp)
                    return
                }
                await refreshPrefsFromActiveBackend()
            } catch {
                lastError = "Failed to update LAN access setting: \(error.localizedDescription)"
            }
        }
    }

    private func refreshPrefsFromActiveBackend() async {
        do {
            let resp = try await callActiveLocalAPI(method: "GET", endpoint: "/localapi/v0/prefs")
            guard resp.statusCode == 200,
                  let bodyB64 = resp.bodyBase64,
                  let bodyData = Data(base64Encoded: bodyB64) else {
                return
            }
            prefs = try JSONDecoder().decode(IpnPrefs.self, from: bodyData)
        } catch {
            // Notify updates from the backend will refresh prefs shortly.
        }
    }

    // Note: setRunAsExitNode removed - iOS does not support advertising as an exit node.
}
