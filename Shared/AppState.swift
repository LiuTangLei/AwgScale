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

private let appInstallMarkerKey = "top.yesican.awgscale.install-marker.v3"
private let vpnPermissionEnabledKey = "top.yesican.awgscale.vpn-permission-enabled.v1"

private func defaultVPNPermissionEnabled() -> Bool {
    if let stored = UserDefaults.standard.object(forKey: vpnPermissionEnabledKey) as? Bool {
        return stored
    }
    return true
}

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
    @Published var usesVPNPermission: Bool = defaultVPNPermissionEnabled()
    @Published var isAwaitingMachineAuth: Bool = false
    @Published var browseToURL: String?
    @Published var pendingWantRunning: Bool?
    @Published var isUpdatingExitNode: Bool = false
    @Published var pendingExitNodeID: String?
    @Published var pendingExitNodeAllowLANAccess: Bool?
    @Published var outgoingTaildropFiles: [TaildropOutgoingFile] = []
    @Published var incomingTaildropFiles: [TaildropIncomingFile] = []
    @Published var taildropFilesWaiting: Bool = false
    @Published var taildropInboxRevision: Int = 0
    @Published var taildropPromptedInboxRevision: Int = 0
    @Published var latestTaildropFileName: String?

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
    @Published var isAwgStatusRefreshing = false
    /// Hostname of peer currently being synced (nil if no sync in progress)
    @Published var awgSyncInProgress: String?
    private var isAwgOperationInProgress = false
    /// Whether AWG peers have been loaded (prevent duplicate requests)
    private var awgPeersLoaded = false
    private var awgPeersLoading = false
    private var awgLastRefresh: Date?
    private let awgRefreshInterval: TimeInterval = 30

    /// Reference to VPNManager for IPC. Set by the app at launch.
    weak var vpnManager: VPNManager?
    private let loginBackend = AppLoginBackend()
    private var isCompletingAppLogin = false
    private var loginCompletionPollTask: Task<Void, Never>?
    private var loginMayRequireMachineAuth = false
    private var loginBrowserWasPresented = false

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.1"
    }

    var tailscaleAwgVersion: String {
        Bundle.main.infoDictionary?["TailscaleAWGVersion"] as? String ?? "unknown"
    }

    var taildropPromptMessage: String {
        if let latestTaildropFileName, !latestTaildropFileName.isEmpty {
            return "Received \(latestTaildropFileName). Open Taildrop to view or share it."
        }
        return "A file was received over Taildrop. Open Taildrop to view or share it."
    }

    var hasVisibleSession: Bool {
        currentProfile != nil || selfNode != nil || !peers.isEmpty || pendingWantRunning != nil || awgSyncInProgress != nil || isAwgOperationInProgress || isUpdatingExitNode
    }

    var shouldShowLoginView: Bool {
        !hasVisibleSession && (ipnState == .noState || ipnState == .needsLogin || ipnState == .needsMachineAuth)
    }

    var effectiveExitNodeID: String? {
        pendingExitNodeID ?? prefs?.ExitNodeID
    }

    var effectiveExitNodeAllowLANAccess: Bool {
        pendingExitNodeAllowLANAccess ?? prefs?.ExitNodeAllowLANAccess ?? false
    }

    var appNetworkIsActive: Bool {
        ipnState == .running || ipnState == .starting
    }

    func effectiveVPNIsActive(systemActive: Bool) -> Bool {
        pendingWantRunning ?? (usesVPNPermission ? systemActive : appNetworkIsActive)
    }

    func setUsesVPNPermission(_ enabled: Bool) {
        guard usesVPNPermission != enabled else { return }
        let currentNetworkActive = usesVPNPermission ? vpnManager?.isTunnelActive == true : appNetworkIsActive
        guard pendingWantRunning == nil, !currentNetworkActive else {
            lastError = "Disconnect before changing VPN permission mode."
            return
        }

        usesVPNPermission = enabled
        UserDefaults.standard.set(enabled, forKey: vpnPermissionEnabledKey)

        if enabled, !isLoggingIn, !isAwaitingMachineAuth {
            loginBackend.stop()
        }
    }

    private var hasBackendSnapshot: Bool {
        currentProfile != nil || selfNode != nil || !peers.isEmpty
    }

    private var isBackendTransitionInProgress: Bool {
        pendingWantRunning != nil || awgSyncInProgress != nil || isAwgOperationInProgress || isUpdatingExitNode
    }

    private var isPreservingSnapshotForBackendTransition: Bool {
        hasBackendSnapshot && (pendingWantRunning == true || awgSyncInProgress != nil || isAwgOperationInProgress || isUpdatingExitNode)
    }

    private var isAppLoginBackendExpected: Bool {
        !usesVPNPermission || isLoggingIn || isAwaitingMachineAuth || loginMayRequireMachineAuth
    }

    private var shouldProtectExistingSessionFromLoginStart: Bool {
        hasBackendSnapshot || vpnManager?.isTunnelActive == true || isBackendTransitionInProgress
    }

    private var canShowMachineAuthDuringLogin: Bool {
        loginMayRequireMachineAuth || loginBrowserWasPresented || !isLoggingIn
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
        defaults.synchronize()
    }

    private func resetStaleLoginState() {
        loginCompletionPollTask?.cancel()
        loginCompletionPollTask = nil
        loginBackend.stop()
        guard !shouldProtectExistingSessionFromLoginStart else { return }
        clearSharedLoginState()
        clearPersistedGoState()
        clearInMemorySessionState()
    }

    private var shouldResumeLoginBackendOnForeground: Bool {
        !usesVPNPermission && hasBackendSnapshot || isLoggingIn || isAwaitingMachineAuth || loginMayRequireMachineAuth
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
            IPCConstants.keyTunnelHasDefaultRoute,
            IPCConstants.keyCurrentProfileID,
            IPCConstants.keyOutgoingFilesJSON,
            IPCConstants.keyIncomingFilesJSON,
            IPCConstants.keyTaildropFilesWaiting,
            IPCConstants.keyTaildropInboxRevision,
            IPCConstants.keyTaildropPromptedInboxRevision,
            IPCConstants.keyTaildropLastFileName,
        ]
        keys.forEach { defaults.removeObject(forKey: $0) }
        defaults.set(IpnState.needsLogin.rawValue, forKey: IPCConstants.keyIPNState)
        defaults.synchronize()
        postDarwinNotification(IPCConstants.notifyStateChanged)
    }

    private func clearSharedBackendSnapshot(_ defaults: UserDefaults) {
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
        keys.forEach { defaults.removeObject(forKey: $0) }
    }

    private func persistLoginBackendSnapshot(_ notify: IpnNotify) {
        guard let defaults = sharedDefaults else { return }

        let state = notify.State.flatMap(IpnState.init(rawValue:))
        let shouldClearBackendSnapshot = state?.clearsBackendSnapshot ?? false

        if let stateInt = notify.State {
            defaults.set(stateInt, forKey: IPCConstants.keyIPNState)
            if shouldClearBackendSnapshot {
                clearSharedBackendSnapshot(defaults)
            }
        }

        if !shouldClearBackendSnapshot, let prefs = notify.Prefs,
           let prefsData = try? JSONEncoder().encode(prefs) {
            defaults.set(String(data: prefsData, encoding: .utf8), forKey: IPCConstants.keyPrefsJSON)
        }

        if !shouldClearBackendSnapshot, let netMap = notify.NetMap,
           let netMapData = try? JSONEncoder().encode(netMap) {
            defaults.set(String(data: netMapData, encoding: .utf8), forKey: IPCConstants.keyNetMapJSON)
        }

        if let url = notify.BrowseToURL {
            defaults.set(url, forKey: IPCConstants.keyBrowseToURL)
        }

        if notify.LoginFinished != nil {
            defaults.removeObject(forKey: IPCConstants.keyBrowseToURL)
        }

        if !shouldClearBackendSnapshot, let health = notify.Health,
           let healthData = try? JSONEncoder().encode(health) {
            defaults.set(String(data: healthData, encoding: .utf8), forKey: IPCConstants.keyHealthJSON)
        }

        defaults.synchronize()
    }

    private func clearInMemorySessionState() {
        ipnState = .needsLogin
        clearBackendSnapshotState()
        lastError = nil
        browseToURL = nil
        isLoggingIn = false
        isAwaitingMachineAuth = false
        isCompletingAppLogin = false
        loginMayRequireMachineAuth = false
        loginBrowserWasPresented = false
        pendingWantRunning = nil
        isUpdatingExitNode = false
        pendingExitNodeID = nil
        pendingExitNodeAllowLANAccess = nil
        outgoingTaildropFiles = []
        incomingTaildropFiles = []
        taildropFilesWaiting = false
        taildropInboxRevision = 0
        taildropPromptedInboxRevision = 0
        latestTaildropFileName = nil
        isAwgOperationInProgress = false
    }

    private func clearBackendSnapshotState() {
        currentProfile = nil
        prefs = nil
        selfNode = nil
        peers = []
        health = nil
        awgPeersStatus = [:]
        awgPeersData = [:]
        localAwgStatus = false
        currentAwgConfig = nil
        awgStatusMessage = nil
        awgSyncInProgress = nil
        isAwgOperationInProgress = false
        awgPeersLoaded = false
        awgPeersLoading = false
        awgLastRefresh = nil
        isUpdatingExitNode = false
        pendingExitNodeID = nil
        pendingExitNodeAllowLANAccess = nil
    }

    private func shouldClearBackendSnapshot(for state: IpnState) -> Bool {
        state.clearsBackendSnapshot && !isPreservingSnapshotForBackendTransition
    }

    private func updateCachedPrefs(
        wantRunning: Bool? = nil,
        exitNodeID: String? = nil,
        routeAll: Bool? = nil,
        exitNodeAllowLANAccess: Bool? = nil
    ) {
        prefs = IpnPrefs(
            WantRunning: wantRunning ?? prefs?.WantRunning,
            RouteAll: routeAll ?? prefs?.RouteAll,
            CorpDNS: prefs?.CorpDNS,
            AmneziaWG: prefs?.AmneziaWG,
            ExitNodeID: exitNodeID ?? prefs?.ExitNodeID,
            ExitNodeAllowLANAccess: exitNodeAllowLANAccess ?? prefs?.ExitNodeAllowLANAccess,
            ControlURL: prefs?.ControlURL,
            Hostname: prefs?.Hostname
        )
    }

    /// Read state written by the Packet Tunnel Extension.
    func loadSharedState() {
        guard let defaults = sharedDefaults else { return }

        // ipn.State
        let stateRaw = defaults.integer(forKey: IPCConstants.keyIPNState)
        var clearsBackendSnapshot = false
        if let state = IpnState(rawValue: stateRaw) {
            ipnState = state
            clearsBackendSnapshot = shouldClearBackendSnapshot(for: state)
            if clearsBackendSnapshot {
                clearBackendSnapshotState()
            }
        }

        // Prefs
        if !clearsBackendSnapshot,
           let prefsStr = defaults.string(forKey: IPCConstants.keyPrefsJSON),
           let prefsData = prefsStr.data(using: .utf8) {
            prefs = try? JSONDecoder().decode(IpnPrefs.self, from: prefsData)
            updateLocalAwgStatusFromCachedPrefs()
        }

        // NetMap
        if !clearsBackendSnapshot,
           let netMapStr = defaults.string(forKey: IPCConstants.keyNetMapJSON),
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
        if newBrowseURL != nil {
            loginBrowserWasPresented = true
        }

        // LoginFinished
        if defaults.bool(forKey: IPCConstants.keyLoginFinished) {
            isLoggingIn = false
            browseToURL = nil
            defaults.removeObject(forKey: IPCConstants.keyLoginFinished)
            finishAppLogin()
        }

        // Health
        if !clearsBackendSnapshot,
           let healthStr = defaults.string(forKey: IPCConstants.keyHealthJSON),
           let healthData = healthStr.data(using: .utf8) {
            if let health = try? JSONDecoder().decode(HealthState.self, from: healthData) {
                self.health = visibleHealth(from: health)
            }
        }

        if !clearsBackendSnapshot,
           let outgoingStr = defaults.string(forKey: IPCConstants.keyOutgoingFilesJSON),
           let outgoingData = outgoingStr.data(using: .utf8),
           let outgoingFiles = try? JSONDecoder().decode([TaildropOutgoingFile].self, from: outgoingData) {
            outgoingTaildropFiles = outgoingFiles
        }

        if !clearsBackendSnapshot,
           let incomingStr = defaults.string(forKey: IPCConstants.keyIncomingFilesJSON),
           let incomingData = incomingStr.data(using: .utf8),
           let incomingFiles = try? JSONDecoder().decode([TaildropIncomingFile].self, from: incomingData) {
            incomingTaildropFiles = incomingFiles
        }

        if !clearsBackendSnapshot {
            taildropFilesWaiting = defaults.bool(forKey: IPCConstants.keyTaildropFilesWaiting)
            taildropInboxRevision = defaults.integer(forKey: IPCConstants.keyTaildropInboxRevision)
            taildropPromptedInboxRevision = defaults.integer(forKey: IPCConstants.keyTaildropPromptedInboxRevision)
            latestTaildropFileName = defaults.string(forKey: IPCConstants.keyTaildropLastFileName)
        }

        // Last error
        let sharedLastError = defaults.string(forKey: IPCConstants.keyLastError)
        if shouldSuppressSharedLastError(sharedLastError) {
            lastError = nil
            defaults.removeObject(forKey: IPCConstants.keyLastError)
        } else {
            lastError = sharedLastError
        }
    }

    private func shouldSuppressSharedLastError(_ message: String?) -> Bool {
        guard let message else { return false }
        guard pendingWantRunning == false else { return false }
        return message.localizedCaseInsensitiveContains("setTunnelNetworkSettings")
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
        var clearsBackendSnapshot = false
        if let stateInt = notify.State, let state = IpnState(rawValue: stateInt) {
            ipnState = state
            clearsBackendSnapshot = shouldClearBackendSnapshot(for: state)
            if clearsBackendSnapshot {
                clearBackendSnapshotState()
            }
            if state == .needsMachineAuth && fromLoginBackend && canShowMachineAuthDuringLogin {
                isAwaitingMachineAuth = true
                startLoginCompletionPolling()
            }
        }

        if !clearsBackendSnapshot, let prefs = notify.Prefs {
            self.prefs = prefs
            updateLocalAwgStatusFromCachedPrefs()
        }

        if !clearsBackendSnapshot, let netMap = notify.NetMap {
            updatePeers(from: netMap)
        }

        if let url = notify.BrowseToURL {
            browseToURL = url
            loginBrowserWasPresented = true
        }

        if notify.LoginFinished != nil {
            isLoggingIn = false
            browseToURL = nil
            finishAppLogin()
        }

        if !clearsBackendSnapshot,
           let health = notify.Health,
           !fromLoginBackend || vpnManager?.isTunnelActive == true {
            self.health = visibleHealth(from: health)
        }

        if !clearsBackendSnapshot, let outgoingFiles = notify.OutgoingFiles {
            outgoingTaildropFiles = outgoingFiles
        }

        if !clearsBackendSnapshot, let incomingFiles = notify.IncomingFiles {
            incomingTaildropFiles = incomingFiles
        }

        if !clearsBackendSnapshot, notify.FilesWaiting != nil {
            taildropFilesWaiting = true
        }
    }

    private func updateLocalAwgStatusFromCachedPrefs() {
        currentAwgConfig = prefs?.AmneziaWG
        localAwgStatus = currentAwgConfig?.hasNonDefaultValues == true
    }

    func markTaildropFilesSeen() {
        taildropFilesWaiting = false
        taildropPromptedInboxRevision = max(taildropPromptedInboxRevision, taildropInboxRevision)
        sharedDefaults?.set(false, forKey: IPCConstants.keyTaildropFilesWaiting)
        sharedDefaults?.set(taildropPromptedInboxRevision, forKey: IPCConstants.keyTaildropPromptedInboxRevision)
    }

    func markTaildropPromptPresented(revision: Int) {
        guard revision > taildropPromptedInboxRevision else { return }
        taildropPromptedInboxRevision = revision
        sharedDefaults?.set(revision, forKey: IPCConstants.keyTaildropPromptedInboxRevision)
    }

    private var shouldSuppressTransientLoginStateHealthWarning: Bool {
        hasVisibleSession && (ipnState == .noState || ipnState == .starting || isBackendTransitionInProgress)
    }

    private func visibleHealth(from health: HealthState) -> HealthState {
        guard shouldSuppressTransientLoginStateHealthWarning,
              let warnings = health.Warnings,
              !warnings.isEmpty else {
            return health
        }

        let filteredWarnings = warnings.filter { code, state in
            code != "login-state" && state.WarnableCode != "login-state"
        }
        return HealthState(Warnings: filteredWarnings)
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

    }

    private func activeLocalAPIClient() async throws -> LocalAPIClient {
        if usesVPNPermission, let vpn = vpnManager, vpn.isTunnelActive {
            return .vpn(vpn)
        }

        if isBackendTransitionInProgress {
            throw LoginFlowError.localAPI("VPN backend is restarting")
        }

        if loginBackend.isRunning {
            guard isAppLoginBackendExpected else {
                loginBackend.stop()
                throw LoginFlowError.localAPI("VPN backend is not active")
            }
            return .login(loginBackend)
        }

        guard isAppLoginBackendExpected || !hasBackendSnapshot else {
            throw LoginFlowError.localAPI("VPN backend is not active")
        }

        try await ensureAppBackendReadyForControlPlane()
        return .login(loginBackend)
    }

    func fetchInAppBrowserPage(_ urlString: String) async throws -> InAppBrowserPage {
        let endpoint = "/localapi/v0/awgscale/http-fetch"
        let request = InAppBrowserRequest(url: urlString, timeoutMillis: 30000)
        let body = try JSONEncoder().encode(request)
        let client = try await activeLocalAPIClient()
        try await ensureSelectedExitNodeRoutesInternet(client)
        let response = try await client.raw(
            method: "POST",
            endpoint: endpoint,
            body: body,
            timeout: 35000
        )
        return try response.decodedBody(InAppBrowserPage.self, endpoint: endpoint)
    }

    func inAppBrowserProxy() async throws -> InAppBrowserProxy {
        let endpoint = "/localapi/v0/awgscale/browser-proxy"
        let client = try await activeLocalAPIClient()
        try await ensureSelectedExitNodeRoutesInternet(client)
        let response = try await client.raw(
            method: "GET",
            endpoint: endpoint,
            timeout: 5000
        )
        return try response.decodedBody(InAppBrowserProxy.self, endpoint: endpoint)
    }

    private func ensureSelectedExitNodeRoutesInternet(_ client: LocalAPIClient) async throws {
        let currentPrefs = try await client.ipnPrefs(timeout: 3000)
        guard let exitNodeID = currentPrefs.ExitNodeID,
              !exitNodeID.isEmpty,
              currentPrefs.RouteAll != true else { return }

        var routePrefs = MaskedPrefs()
        routePrefs.ExitNodeID = exitNodeID
        routePrefs.ExitNodeIDSet = true
        routePrefs.RouteAll = true
        routePrefs.RouteAllSet = true
        try await client.patchPrefs(routePrefs, timeout: 30000)
        var lastPrefsError: String?
        for _ in 0..<30 {
            do {
                let checkedPrefs = try await client.ipnPrefs(timeout: 1000)
                if (checkedPrefs.ExitNodeID ?? "") == exitNodeID && checkedPrefs.RouteAll == true {
                    return
                }
            } catch {
                lastPrefsError = error.localizedDescription
            }

            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        if let lastPrefsError {
            throw LoginFlowError.localAPI("Timed out waiting for exit node internet routing: \(lastPrefsError)")
        }
        throw LoginFlowError.localAPI("Timed out waiting for exit node internet routing")
    }

    func sendInAppTerminalInput(host: String, port: Int, payload: String) async throws -> InAppTerminalResponse {
        let endpoint = "/localapi/v0/awgscale/tcp-console"
        let request = InAppTerminalRequest(
            host: host,
            port: port,
            payload: payload,
            appendNewline: true,
            timeoutMillis: 8000
        )
        let body = try JSONEncoder().encode(request)
        let response = try await activeLocalAPIClient().raw(
            method: "POST",
            endpoint: endpoint,
            body: body,
            timeout: 10000
        )
        return try response.decodedBody(InAppTerminalResponse.self, endpoint: endpoint)
    }

    func openInAppSSHSession(host: String, port: Int, username: String, password: String, privateKey: String = "", passphrase: String = "") async throws -> InAppSSHResponse {
        let endpoint = "/localapi/v0/awgscale/ssh/open"
        let request = InAppSSHOpenRequest(
            host: host,
            port: port,
            username: username,
            password: password,
            privateKey: privateKey,
            passphrase: passphrase,
            terminal: "xterm-256color",
            columns: 80,
            rows: 24,
            timeoutMillis: 15000
        )
        let body = try JSONEncoder().encode(request)
        let response = try await activeLocalAPIClient().raw(
            method: "POST",
            endpoint: endpoint,
            body: body,
            timeout: 20000
        )
        return try response.decodedBody(InAppSSHResponse.self, endpoint: endpoint)
    }

    func sendInAppSSHInput(sessionID: String, input: String) async throws -> InAppSSHResponse {
        let endpoint = "/localapi/v0/awgscale/ssh/send"
        let request = InAppSSHSendRequest(sessionID: sessionID, input: input)
        let body = try JSONEncoder().encode(request)
        let response = try await activeLocalAPIClient().raw(
            method: "POST",
            endpoint: endpoint,
            body: body,
            timeout: 5000
        )
        return try response.decodedBody(InAppSSHResponse.self, endpoint: endpoint)
    }

    func readInAppSSHSession(sessionID: String) async throws -> InAppSSHResponse {
        let endpoint = "/localapi/v0/awgscale/ssh/read"
        let request = InAppSSHSessionRequest(sessionID: sessionID)
        let body = try JSONEncoder().encode(request)
        let response = try await activeLocalAPIClient().raw(
            method: "POST",
            endpoint: endpoint,
            body: body,
            timeout: 5000
        )
        return try response.decodedBody(InAppSSHResponse.self, endpoint: endpoint)
    }

    func closeInAppSSHSession(sessionID: String) async {
        let endpoint = "/localapi/v0/awgscale/ssh/close"
        let request = InAppSSHSessionRequest(sessionID: sessionID)
        guard let body = try? JSONEncoder().encode(request) else { return }
        _ = try? await activeLocalAPIClient().raw(
            method: "POST",
            endpoint: endpoint,
            body: body,
            timeout: 5000
        )
    }

    private func ensureAppBackendReadyForControlPlane() async throws {
        if loginBackend.isRunning { return }
        guard isAppLoginBackendExpected || !hasBackendSnapshot else {
            throw LoginFlowError.localAPI("VPN backend is not active")
        }
        let tolerateStartupTransient = hasBackendSnapshot || isBackendTransitionInProgress

        try await loginBackend.start { [weak self] data in
            self?.handleLoginBackendNotify(data)
        }

        guard let backendState = await loginBackendState() else {
            if tolerateStartupTransient { return }
            loginBackend.stop()
            throw LoginFlowError.localAPI("No active backend")
        }

        ipnState = backendState
        switch backendState {
        case .needsLogin, .noState:
            if tolerateStartupTransient { return }
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
    /// complete before the user chooses to turn AwgScale on.
    func startLogin(controlURL: String = "") {
        guard !isLoggingIn else { return }
        guard !shouldProtectExistingSessionFromLoginStart else {
            lastError = "Already signed in. Disconnect or log out before starting a new login."
            return
        }

        loginBackend.stop()
        clearSharedLoginState()
        clearPersistedGoState()
        loginCompletionPollTask?.cancel()
        loginCompletionPollTask = nil
        isLoggingIn = true
        isAwaitingMachineAuth = false
        loginMayRequireMachineAuth = !controlURL.isEmpty
        loginBrowserWasPresented = false
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
        try await LocalAPIClient.login(loginBackend).patchPrefsReturningBody(prefs)
    }

    private func startLoginBackend(updatePrefsData: Data) async throws {
        try await LocalAPIClient.login(loginBackend).start(updatePrefsData: updatePrefsData)
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
            persistLoginBackendSnapshot(notify)
            applyNotify(notify, fromLoginBackend: true)
        } catch {
            lastError = "Failed to decode notification: \(error.localizedDescription)"
        }
    }

    func loginBrowserDidDismiss() {
        loginBrowserWasPresented = true
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
            if (backendState == .needsMachineAuth && canShowMachineAuthDuringLogin) ||
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
            if usesVPNPermission {
                loginBackend.stop()
            }
            isAwaitingMachineAuth = false
            loginMayRequireMachineAuth = false
            loginBrowserWasPresented = false
            isLoggingIn = false
            isCompletingAppLogin = false
        }
    }

    func resumeAppBackendIfNeeded(vpnActive: Bool) {
        guard !vpnActive,
              !loginBackend.isRunning,
              !isLoggingIn,
              shouldResumeLoginBackendOnForeground,
              !isBackendTransitionInProgress else { return }

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
                guard isLoggingIn || loginMayRequireMachineAuth else {
                    resetStaleLoginState()
                    return
                }
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
        if !usesVPNPermission {
            guard !isBackendTransitionInProgress else { return }
            resumeAppBackendIfNeeded(vpnActive: false)
            return
        }

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

        guard !isBackendTransitionInProgress else {
            loginBackend.stop()
            return
        }

        guard shouldResumeLoginBackendOnForeground else {
            loginBackend.stop()
            return
        }

        resumeAppBackendIfNeeded(vpnActive: false)
    }

    func refreshTunnelStatus() async {
        guard let vpn = vpnManager else { return }

        do {
            let json = try await LocalAPIClient.vpn(vpn).statusObject(timeout: 3000)

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
            return try await LocalAPIClient.login(loginBackend).statusObject(timeout: timeout)
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
            let json = try await LocalAPIClient.vpn(vpn).statusObject()
            guard let selfStatus = json["Self"] as? [String: Any] else { return nil }

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
            try await LocalAPIClient.login(loginBackend).setWantRunning(wantRunning)
        } catch {
            lastError = "Failed to update login preferences: \(error.localizedDescription)"
        }
    }

    private func waitForBackendReady(_ vpn: VPNManager) async -> String? {
        var lastReadinessError = vpn.lastError

        for _ in 0..<25 {
            let status = vpn.updateStatusFromConnection()
            if status == .connected || status == .reasserting {
                break
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        let deadline = Date().addingTimeInterval(35)

        while Date() < deadline {
            switch vpn.updateStatusFromConnection() {
            case .disconnected, .invalid:
                return "VPN tunnel stopped before LocalAPI became ready"
            case .disconnecting:
                return "VPN tunnel is disconnecting before LocalAPI became ready"
            default:
                break
            }

            if let extensionError = sharedDefaults?.string(forKey: IPCConstants.keyLastError), !extensionError.isEmpty {
                lastReadinessError = extensionError
            }

            do {
                let resp = try await LocalAPIClient.vpn(vpn).statusResponse(timeout: 1000)
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

    private func waitForBackendRunning(_ vpn: VPNManager, requireNetMap: Bool = false) async -> String? {
        var lastState = "Starting"
        let tolerateTransientUnauthenticated = hasBackendSnapshot || isBackendTransitionInProgress
        let transientUnauthenticatedDeadline = Date().addingTimeInterval(12)

        let deadline = Date().addingTimeInterval(60)

        while Date() < deadline {
            switch vpn.updateStatusFromConnection() {
            case .disconnected, .invalid:
                return "VPN tunnel stopped before backend reached Running"
            case .disconnecting:
                return "VPN tunnel is disconnecting before backend reached Running"
            default:
                break
            }

            do {
                let json = try await LocalAPIClient.vpn(vpn).statusObject(timeout: 1000)
                if let backendState = json["BackendState"] as? String {
                    lastState = backendState
                    if let state = IpnState(backendState: backendState) {
                        ipnState = state
                    }
                    switch backendState {
                    case "Running":
                        if !requireNetMap || statusHasNetworkMap(json) {
                            return nil
                        }
                        lastState = "Running without network map"
                    case "NeedsLogin":
                        if tolerateTransientUnauthenticated && Date() < transientUnauthenticatedDeadline {
                            break
                        }
                        return "login is required"
                    case "NeedsMachineAuth":
                        if tolerateTransientUnauthenticated && Date() < transientUnauthenticatedDeadline {
                            break
                        }
                        isAwaitingMachineAuth = true
                        return "machine authorization is pending"
                    default:
                        break
                    }
                }
            } catch {
                lastState = error.localizedDescription
            }

            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        return "timed out waiting for backend to run; last state: \(lastState)"
    }

    private func statusHasNetworkMap(_ status: [String: Any]) -> Bool {
        if let selfStatus = status["Self"] as? [String: Any], !selfStatus.isEmpty {
            return true
        }
        if let peers = status["Peer"] as? [String: Any], !peers.isEmpty {
            return true
        }
        return false
    }

    private func waitForVPNStopped(_ vpn: VPNManager) async {
        for _ in 0..<25 {
            let status = vpn.updateStatusFromConnection()
            if status != .connected && status != .connecting && status != .reasserting && status != .disconnecting {
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// Log out and clear all state.
    func logout() {
        loginCompletionPollTask?.cancel()
        loginCompletionPollTask = nil
        clearInMemorySessionState()
        clearSharedLoginState()
        loginBackend.stop()

        Task {
            if let vpn = vpnManager {
                _ = try? await LocalAPIClient.vpn(vpn).logout()
                vpn.disconnect()
                await waitForVPNStopped(vpn)
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
        if !usesVPNPermission {
            setAppBackendWantRunning(wantRunning)
            return
        }

        guard let vpn = vpnManager else { return }
        guard pendingWantRunning != wantRunning else { return }

        pendingWantRunning = wantRunning
        updateCachedPrefs(wantRunning: wantRunning)

        Task {
            defer { pendingWantRunning = nil }

            do {
                lastError = nil

                if !wantRunning {
                    sharedDefaults?.removeObject(forKey: IPCConstants.keyLastError)
                    if vpn.isTunnelActive {
                        do {
                            try await LocalAPIClient.vpn(vpn).setWantRunning(false, timeout: 1000)
                        } catch {
                            NSLog("Ignoring WantRunning=false persistence during VPN stop: \(error)")
                        }
                        await vpn.prepareToDisconnect()
                    }
                    vpn.disconnect()
                    loginBackend.stop()
                    ipnState = .stopped
                    await waitForVPNStopped(vpn)
                    sharedDefaults?.removeObject(forKey: IPCConstants.keyLastError)
                    lastError = nil
                    return
                }

                ipnState = .starting
                sharedDefaults?.removeObject(forKey: IPCConstants.keyLastError)
                sharedDefaults?.set(IpnState.starting.rawValue, forKey: IPCConstants.keyIPNState)
                loginCompletionPollTask?.cancel()
                loginCompletionPollTask = nil
                loginBackend.stop()

                try await connectVPNAndSetWantRunningWithRetry(vpn)
                await refreshTunnelStatus()
            } catch {
                lastError = "Failed to update preferences: \(error.localizedDescription)"
                if wantRunning {
                    await cleanupVPNStartFailure(vpn, error: error)
                } else {
                    vpn.disconnect()
                    loginBackend.stop()
                    ipnState = .stopped
                }
            }
        }
    }

    private func setAppBackendWantRunning(_ wantRunning: Bool) {
        guard pendingWantRunning != wantRunning else { return }

        pendingWantRunning = wantRunning
        updateCachedPrefs(wantRunning: wantRunning)

        Task {
            defer { pendingWantRunning = nil }

            do {
                lastError = nil
                sharedDefaults?.removeObject(forKey: IPCConstants.keyLastError)

                if !wantRunning {
                    if loginBackend.isRunning {
                        do {
                            try await LocalAPIClient.login(loginBackend).setWantRunning(false, timeout: 1000)
                        } catch {
                            NSLog("Ignoring WantRunning=false persistence during app-only stop: \(error)")
                        }
                    }
                    loginBackend.stop()
                    ipnState = .stopped
                    sharedDefaults?.set(IpnState.stopped.rawValue, forKey: IPCConstants.keyIPNState)
                    sharedDefaults?.synchronize()
                    return
                }

                ipnState = .starting
                sharedDefaults?.set(IpnState.starting.rawValue, forKey: IPCConstants.keyIPNState)
                sharedDefaults?.synchronize()
                loginCompletionPollTask?.cancel()
                loginCompletionPollTask = nil

                try await ensureAppBackendReadyForControlPlane()
                try await LocalAPIClient.login(loginBackend).setWantRunning(true)

                if let runningError = await waitForAppBackendRunning(requireNetMap: true) {
                    throw VPNError.backendNotReady(runningError)
                }

                await fetchCurrentProfileFromLoginBackend()
            } catch {
                lastError = "Failed to update app-only connection: \(error.localizedDescription)"
                updateCachedPrefs(wantRunning: false)
                ipnState = .stopped
                sharedDefaults?.set(IpnState.stopped.rawValue, forKey: IPCConstants.keyIPNState)
                sharedDefaults?.synchronize()
                if wantRunning {
                    loginBackend.stop()
                }
            }
        }
    }

    private func waitForAppBackendRunning(requireNetMap: Bool = false) async -> String? {
        var lastState = "Starting"
        let tolerateTransientUnauthenticated = hasBackendSnapshot || isBackendTransitionInProgress
        let transientUnauthenticatedDeadline = Date().addingTimeInterval(12)
        let deadline = Date().addingTimeInterval(60)

        while Date() < deadline {
            guard loginBackend.isRunning else {
                return "app backend stopped before reaching Running"
            }

            do {
                let json = try await LocalAPIClient.login(loginBackend).statusObject(timeout: 1000)
                if let backendState = json["BackendState"] as? String {
                    lastState = backendState
                    if let state = IpnState(backendState: backendState) {
                        ipnState = state
                    }
                    switch backendState {
                    case "Running":
                        if !requireNetMap || statusHasNetworkMap(json) {
                            return nil
                        }
                        lastState = "Running without network map"
                    case "NeedsLogin":
                        if tolerateTransientUnauthenticated && Date() < transientUnauthenticatedDeadline {
                            break
                        }
                        return "login is required"
                    case "NeedsMachineAuth":
                        if tolerateTransientUnauthenticated && Date() < transientUnauthenticatedDeadline {
                            break
                        }
                        isAwaitingMachineAuth = true
                        return "machine authorization is pending"
                    default:
                        break
                    }
                }
            } catch {
                lastState = error.localizedDescription
            }

            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        return "timed out waiting for app backend to run; last state: \(lastState)"
    }

    private func connectVPNAndSetWantRunning(_ vpn: VPNManager, requireNetMap: Bool = false) async throws {
        try await vpn.connectTunnel()
        if let readinessError = await waitForBackendReady(vpn) {
            throw VPNError.backendNotReady(readinessError)
        }

        try await LocalAPIClient.vpn(vpn).setWantRunning(true)

        if let runningError = await waitForBackendRunning(vpn, requireNetMap: requireNetMap) {
            throw VPNError.backendNotReady(runningError)
        }
    }

    private func connectVPNAndSetWantRunningWithRetry(_ vpn: VPNManager, requireNetMap: Bool = false) async throws {
        do {
            try await connectVPNAndSetWantRunning(vpn, requireNetMap: requireNetMap)
        } catch {
            guard shouldRetryVPNStartAfterFailure(error) else { throw error }
            NSLog("Retrying VPN start after recoverable first-start failure: \(error)")
            vpn.disconnect()
            await waitForVPNStopped(vpn)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            sharedDefaults?.removeObject(forKey: IPCConstants.keyLastError)
            try await connectVPNAndSetWantRunning(vpn, requireNetMap: requireNetMap)
        }
    }

    private func cleanupVPNStartFailure(_ vpn: VPNManager, error: Error) async {
        vpn.disconnect()
        await waitForVPNStopped(vpn)
        if shouldClearSessionAfterVPNStartFailure(error) {
            clearBackendSnapshotState()
            ipnState = .needsLogin
            sharedDefaults?.set(IpnState.needsLogin.rawValue, forKey: IPCConstants.keyIPNState)
        } else {
            updateCachedPrefs(wantRunning: false)
            ipnState = .stopped
            sharedDefaults?.set(IpnState.stopped.rawValue, forKey: IPCConstants.keyIPNState)
        }
        sharedDefaults?.synchronize()
    }

    private func shouldRetryVPNStartAfterFailure(_ error: Error) -> Bool {
        if case VPNError.ipcTimeout = error {
            return true
        }

        guard case VPNError.backendNotReady(let message) = error else { return false }
        let lowercased = message.lowercased()
        if lowercased.contains("login is required") || lowercased.contains("machine authorization") {
            return false
        }
        return lowercased.contains("tunnel stopped") ||
            lowercased.contains("disconnecting") ||
            lowercased.contains("packet tunnel ipc") ||
            lowercased.contains("no active vpn session") ||
            lowercased.contains("timed out waiting for localapi") ||
            lowercased.contains("timed out waiting for backend")
    }

    private func shouldClearSessionAfterVPNStartFailure(_ error: Error) -> Bool {
        guard case VPNError.backendNotReady(let message) = error else { return false }
        let lowercased = message.lowercased()
        return lowercased.contains("login is required") || lowercased.contains("machine authorization")
    }

    /// Fetch the current login profile from the backend.
    func fetchCurrentProfile() {
        guard let vpn = vpnManager else { return }

        Task {
            do {
                currentProfile = try await LocalAPIClient.vpn(vpn).currentProfile()
            } catch {
                // Profile fetch is best-effort; don't show error to user
            }
        }
    }

    private func fetchCurrentProfileFromVPNBackend() async {
        guard let vpn = vpnManager else { return }

        do {
            currentProfile = try await LocalAPIClient.vpn(vpn).currentProfile()
        } catch {
            // Profile fetch is best-effort; the tunnel status is authoritative for routing.
        }
    }

    private func fetchCurrentProfileFromLoginBackend() async {
        do {
            currentProfile = try await LocalAPIClient.login(loginBackend).currentProfile()
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
        guard !peers.isEmpty else {
            if showMessages { awgStatusMessage = "No peers available to check" }
            return
        }
        guard !isBackendTransitionInProgress else {
            if showMessages { awgStatusMessage = "Network is busy, try refreshing again shortly" }
            return
        }
        if usesVPNPermission && vpnManager?.isTunnelActive != true && hasBackendSnapshot {
            if showMessages { awgStatusMessage = "Connect VPN to refresh AWG status" }
            return
        }
        if !usesVPNPermission && !appNetworkIsActive && hasBackendSnapshot {
            if showMessages { awgStatusMessage = "Connect app network to refresh AWG status" }
            return
        }
        if !force, awgPeersLoaded, let awgLastRefresh,
           Date().timeIntervalSince(awgLastRefresh) < awgRefreshInterval {
            if showMessages { awgStatusMessage = "AWG status is already up to date" }
            return
        }
        guard !awgPeersLoading else {
            if showMessages { awgStatusMessage = "AWG status refresh already in progress" }
            return
        }

        awgPeersLoading = true
        isAwgStatusRefreshing = true
        if showMessages { awgStatusMessage = "Refreshing AWG status..." }
        Task {
            defer {
                awgPeersLoading = false
                isAwgStatusRefreshing = false
            }
            let loadedPeers = await loadAwgPeersStatusOnce(showMessages: showMessages)
            _ = await loadLocalAwgStatusOnce(showMessages: showMessages)
            if loadedPeers {
                awgPeersLoaded = true
                awgLastRefresh = Date()
            }
        }
    }

    private func loadAwgPeersStatusOnce(showMessages: Bool) async -> Bool {
        do {
            let awgPeers = try await activeLocalAPIClient().awgPeers()

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
            let prefs = try await activeLocalAPIClient().localPrefs()
            currentAwgConfig = prefs.AmneziaWG
            localAwgStatus = currentAwgConfig?.hasNonDefaultValues == true
            return true
        } catch {
            if !isBackendTransitionInProgress {
                localAwgStatus = false
                currentAwgConfig = nil
            }
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
    func syncAwgConfigFromPeer(_ peer: PeerNode, timeout: Int = 30) {
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
        isAwgOperationInProgress = true

        Task {
            defer {
                awgSyncInProgress = nil
                isAwgOperationInProgress = false
            }

            do {
                let (client, vpn) = try await ensureBackendReadyForAwgSync()
                if usesVPNPermission {
                    awgStatusMessage = "Waiting for peer connectivity..."
                    if let peerReadinessError = await waitForPeerReachableForAwgSync(client, vpn: vpn, peer: peer) {
                        throw LoginFlowError.localAPI(peerReadinessError)
                    }
                }
                awgStatusMessage = "Syncing AWG config from \(hostname)..."
                let request = AwgSyncApplyRequest(nodeKey: nodeKey, timeout: timeout)
                let appliedConfig = try await client.awgSyncApply(request)
                currentAwgConfig = appliedConfig
                localAwgStatus = appliedConfig.hasNonDefaultValues
                awgStatusMessage = usesVPNPermission
                    ? "AWG config from \(hostname) applied, restarting VPN..."
                    : "AWG config from \(hostname) applied, restarting app network..."
                let restarted = await refreshBackendForAwgConfig()
                _ = await loadLocalAwgStatusOnce(showMessages: false)
                if restarted {
                    awgStatusMessage = "AWG config from \(hostname) applied successfully"
                }
            } catch {
                awgStatusMessage = parseAwgApplyError(error.localizedDescription, hostname: hostname)
            }
        }
    }

    func clearAwgStatusMessage() {
        awgStatusMessage = nil
    }

    func applyManualAwgConfig(_ config: AmneziaWGPrefs) async throws {
        isAwgOperationInProgress = true
        defer { isAwgOperationInProgress = false }

        awgStatusMessage = config.hasNonDefaultValues ? "Applying AWG config..." : "Clearing AWG config..."

        let (client, _) = try await ensureBackendReadyForAwgSync()
        try await client.patchPrefs(.setAmneziaWG(config))

        currentAwgConfig = config
        localAwgStatus = config.hasNonDefaultValues

        let restarted = await refreshBackendForAwgConfig()

        _ = await loadLocalAwgStatusOnce(showMessages: false)

        if !restarted {
            throw LoginFlowError.localAPI(awgStatusMessage ?? "Network restart failed")
        }

        awgStatusMessage = config.hasNonDefaultValues ? "AWG config applied successfully" : "AWG config cleared"
    }

    // MARK: - AWG Helpers

      private func ensureBackendReadyForAwgSync() async throws -> (client: LocalAPIClient, vpn: VPNManager?) {
          if usesVPNPermission {
              let vpn = try await ensureVPNBackendReadyForAwgSync()
              return (.vpn(vpn), vpn)
          }

          lastError = nil
          awgStatusMessage = "Preparing app network for AWG sync..."

          try await ensureAppBackendReadyForControlPlane()
          try await LocalAPIClient.login(loginBackend).setWantRunning(true)
          if let runningError = await waitForAppBackendRunning(requireNetMap: true) {
              throw VPNError.backendNotReady(runningError)
          }
          await fetchCurrentProfileFromLoginBackend()
          return (.login(loginBackend), nil)
      }

      private func refreshBackendForAwgConfig() async -> Bool {
          if usesVPNPermission {
              return await autoReconnectForAwgConfig()
          }
          return await restartAppBackendForAwgConfig()
      }

      private func restartAppBackendForAwgConfig() async -> Bool {
          awgStatusMessage = "AWG config applied, restarting app network..."
          loginBackend.stop()

          do {
              try await ensureAppBackendReadyForControlPlane()
              try await LocalAPIClient.login(loginBackend).setWantRunning(true)
              if let runningError = await waitForAppBackendRunning(requireNetMap: true) {
                  throw VPNError.backendNotReady(runningError)
              }
              await fetchCurrentProfileFromLoginBackend()
              return true
          } catch {
              awgStatusMessage = "AWG config applied but app network restart failed: \(error.localizedDescription)"
              return false
          }
      }

    private func autoReconnectForAwgConfig() async -> Bool {
        guard let vpn = vpnManager else { return false }
        let wasAwgOperationInProgress = isAwgOperationInProgress
        isAwgOperationInProgress = true
        defer {
            if !wasAwgOperationInProgress {
                isAwgOperationInProgress = false
            }
        }

        await vpn.prepareToDisconnect()
        vpn.disconnect()
        for _ in 0..<25 {
            _ = vpn.updateStatusFromConnection()
            if !vpn.isTunnelActive { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        do {
            try await connectVPNAndSetWantRunningWithRetry(vpn)
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

        let wasTunnelActive = vpn.isTunnelActive
        let ownsConnectIntent = !wasTunnelActive && pendingWantRunning == nil
        if ownsConnectIntent {
            pendingWantRunning = true
            updateCachedPrefs(wantRunning: true)
            ipnState = .starting
            sharedDefaults?.set(IpnState.starting.rawValue, forKey: IPCConstants.keyIPNState)
            sharedDefaults?.removeObject(forKey: IPCConstants.keyLastError)
        }
        defer {
            if ownsConnectIntent {
                pendingWantRunning = nil
            }
        }

        do {
            awgStatusMessage = "Waiting for VPN network map..."
            try await connectVPNAndSetWantRunningWithRetry(vpn, requireNetMap: true)
        } catch {
            if !wasTunnelActive {
                await cleanupVPNStartFailure(vpn, error: error)
            }
            throw error
        }
        _ = await vpn.refreshStatus()
        await refreshTunnelStatus()
        return vpn
    }

    private func waitForPeerReachableForAwgSync(_ client: LocalAPIClient, vpn: VPNManager?, peer: PeerNode) async -> String? {
        guard let ip = peer.primaryIPv4Address else { return nil }

        let deadline = Date().addingTimeInterval(30)
        var lastPingError = "peer did not respond"

        while Date() < deadline {
            if let vpn {
                switch vpn.updateStatusFromConnection() {
                case .disconnected, .invalid:
                    return "VPN tunnel stopped before AWG sync could reach peer"
                case .disconnecting:
                    return "VPN tunnel is disconnecting before AWG sync could reach peer"
                default:
                    break
                }
            }

            do {
                let response = try await client.ping(ip: ip, timeout: 5000)
                if response.Err?.isEmpty ?? true {
                    return nil
                }
                lastPingError = response.Err ?? "peer did not respond"
            } catch {
                lastPingError = error.localizedDescription
            }

            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        return "Peer \(peer.displayName) is not reachable for AWG sync yet: \(lastPingError)"
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
        if let bodyPreview = response.bodyPreview() {
            return bodyPreview
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
        } else if message.contains("not reachable for AWG sync yet") {
            return "Peer \(hostname) is not reachable yet, please retry after VPN stabilizes"
        } else if message.contains("VPN tunnel stopped before AWG sync") || message.contains("disconnecting before AWG sync") {
            return "VPN disconnected before AWG sync completed"
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

    /// Set the exit node to use for routing traffic.
    func setExitNode(_ peer: PeerNode) {
        guard !isUpdatingExitNode else { return }

        let previousPrefs = prefs
        let targetID = peer.id
        isUpdatingExitNode = true
        pendingExitNodeID = targetID
        updateCachedPrefs(exitNodeID: targetID, routeAll: true)
        lastError = nil
        sharedDefaults?.removeObject(forKey: IPCConstants.keyLastError)

        Task {
            defer {
                isUpdatingExitNode = false
                pendingExitNodeID = nil
            }

            do {
                let (client, usesSystemTunnel) = try await ensureBackendRunningForExitNode()
                try await client.setExitNode(id: targetID)
                _ = try await waitForPrefs(client, description: "exit node selection") { prefs in
                    (prefs.ExitNodeID ?? "") == targetID && prefs.RouteAll == true
                }
                if usesSystemTunnel {
                    try await waitForTunnelDefaultRoute(enabled: true)
                }
                lastError = nil
            } catch {
                prefs = previousPrefs
                lastError = "Failed to set exit node: \(error.localizedDescription)"
            }
        }
    }

    /// Clear the current exit node (stop using any exit node).
    func clearExitNode() {
        guard !isUpdatingExitNode else { return }

        let previousPrefs = prefs
        isUpdatingExitNode = true
        pendingExitNodeID = ""
        updateCachedPrefs(exitNodeID: "", routeAll: false)
        lastError = nil
        sharedDefaults?.removeObject(forKey: IPCConstants.keyLastError)

        Task {
            defer {
                isUpdatingExitNode = false
                pendingExitNodeID = nil
            }

            do {
                let (client, usesSystemTunnel) = try await ensureBackendRunningForExitNode()
                try await client.setExitNode(id: "")
                _ = try await waitForPrefs(client, description: "exit node clearing") { prefs in
                    (prefs.ExitNodeID ?? "").isEmpty && prefs.RouteAll != true
                }
                if usesSystemTunnel {
                    try await waitForTunnelDefaultRoute(enabled: false)
                }
                lastError = nil
            } catch {
                prefs = previousPrefs
                lastError = "Failed to clear exit node: \(error.localizedDescription)"
            }
        }
    }

    /// Set allow LAN access when using exit node.
    func setExitNodeAllowLANAccess(_ allow: Bool) {
        guard !isUpdatingExitNode else { return }

        let previousPrefs = prefs
        isUpdatingExitNode = true
        pendingExitNodeAllowLANAccess = allow
        updateCachedPrefs(exitNodeAllowLANAccess: allow)
        lastError = nil
        sharedDefaults?.removeObject(forKey: IPCConstants.keyLastError)

        Task {
            defer {
                isUpdatingExitNode = false
                pendingExitNodeAllowLANAccess = nil
            }

            do {
                let (client, _) = try await ensureBackendRunningForExitNode()
                try await client.setExitNodeAllowLANAccess(allow)
                _ = try await waitForPrefs(client, description: "exit node LAN access") { prefs in
                    (prefs.ExitNodeAllowLANAccess ?? false) == allow
                }
                lastError = nil
            } catch {
                prefs = previousPrefs
                lastError = "Failed to update LAN access setting: \(error.localizedDescription)"
            }
        }
    }

    private func refreshPrefsFromActiveBackend(timeout: Int = 3000) async {
        do {
            prefs = try await activeLocalAPIClient().ipnPrefs(timeout: timeout)
        } catch {
            // Notify updates from the backend will refresh prefs shortly.
        }
    }

    private func ensureBackendRunningForExitNode() async throws -> (client: LocalAPIClient, usesSystemTunnel: Bool) {
        if usesVPNPermission {
            let vpn = try await ensureVPNBackendRunningForExitNode()
            return (.vpn(vpn), true)
        }

        try await ensureAppBackendReadyForControlPlane()
        try await LocalAPIClient.login(loginBackend).setWantRunning(true)
        if let runningError = await waitForAppBackendRunning(requireNetMap: true) {
            throw VPNError.backendNotReady(runningError)
        }
        await fetchCurrentProfileFromLoginBackend()
        return (.login(loginBackend), false)
    }

    private func ensureVPNBackendRunningForExitNode() async throws -> VPNManager {
        guard let vpn = vpnManager else {
            throw LoginFlowError.localAPI("VPN manager not available")
        }

        loginBackend.stop()
        try await vpn.connectTunnel()
        if let readinessError = await waitForBackendReady(vpn) {
            throw VPNError.backendNotReady(readinessError)
        }
        if let runningError = await waitForBackendRunning(vpn) {
            throw VPNError.backendNotReady(runningError)
        }
        await refreshTunnelStatus()
        return vpn
    }

    private func waitForPrefs(
        _ client: LocalAPIClient,
        description: String,
        matches: (IpnPrefs) -> Bool
    ) async throws -> IpnPrefs {
        var lastPrefsError: String?

        for _ in 0..<30 {
            do {
                let currentPrefs = try await client.ipnPrefs(timeout: 1000)
                prefs = currentPrefs
                if matches(currentPrefs) {
                    return currentPrefs
                }
            } catch {
                lastPrefsError = error.localizedDescription
            }

            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        if let lastPrefsError {
            throw LoginFlowError.localAPI("Timed out waiting for \(description): \(lastPrefsError)")
        }
        throw LoginFlowError.localAPI("Timed out waiting for \(description)")
    }

    private func waitForTunnelDefaultRoute(enabled: Bool) async throws {
        guard let defaults = sharedDefaults else {
            throw LoginFlowError.localAPI("App Group state is not available")
        }

        for _ in 0..<40 {
            defaults.synchronize()
            if defaults.bool(forKey: IPCConstants.keyTunnelHasDefaultRoute) == enabled {
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        throw LoginFlowError.localAPI(enabled
            ? "Default route did not become active"
            : "Default route did not clear")
    }

    // Note: setRunAsExitNode removed - iOS does not support advertising as an exit node.
}
