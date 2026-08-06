import Foundation
import XCTest
@testable import AwgScale

private actor LocalPrefsResponseGate {
    private var nextRequestID = 0
    private var responses: [Int: CheckedContinuation<IPCResponse, Never>] = [:]
    private var requestWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func response() async -> IPCResponse {
        let requestID = nextRequestID
        nextRequestID += 1

        let readyWaiters = requestWaiters.filter { nextRequestID >= $0.count }
        requestWaiters.removeAll { nextRequestID >= $0.count }
        readyWaiters.forEach { $0.continuation.resume() }

        return await withCheckedContinuation { continuation in
            responses[requestID] = continuation
        }
    }

    func waitForRequestCount(_ count: Int) async {
        guard nextRequestID < count else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append((count, continuation))
        }
    }

    func resume(requestID: Int, jc: Int) {
        let body = Data(#"{"AmneziaWG":{"JC":\#(jc)}}"#.utf8)
        responses.removeValue(forKey: requestID)?.resume(
            returning: .success(statusCode: 200, body: body)
        )
    }
}

@MainActor
final class AppStateTests: XCTestCase {

    func testLoginControlServerResolutionUsesExplicitOfficialDefault() {
        XCTAssertEqual(resolvedLoginControlServerURL(nil), officialControlServerURL)
        XCTAssertEqual(resolvedLoginControlServerURL("   "), officialControlServerURL)
        XCTAssertEqual(
            resolvedLoginControlServerURL("headscale.example.com"),
            "https://headscale.example.com"
        )
        XCTAssertEqual(
            resolvedLoginControlServerURL("http://localhost:8080/control"),
            "http://localhost:8080/control"
        )
    }

    func testCustomControlServerValidationRejectsNonOriginComponents() {
        XCTAssertNil(normalizedCustomControlServerURL("ftp://headscale.example.com"))
        XCTAssertNil(normalizedCustomControlServerURL("https://user:secret@headscale.example.com"))
        XCTAssertNil(normalizedCustomControlServerURL("https://headscale.example.com?server=other"))
        XCTAssertNil(normalizedCustomControlServerURL("https://headscale.example.com/#callback"))
        XCTAssertNil(normalizedCustomControlServerURL("https://"))
    }

    func testOfficialLoginRejectsHeadscaleAndUnsafeAuthenticationURLs() {
        XCTAssertTrue(
            isAuthenticationURLAllowed(
                "https://login.tailscale.com/a/example",
                controlServerURL: officialControlServerURL
            )
        )
        XCTAssertTrue(
            isAuthenticationURLAllowed(
                "https://controlplane.tailscale.com/a/example",
                controlServerURL: officialControlServerURL
            )
        )
        XCTAssertTrue(
            isAuthenticationURLAllowed(
                "https://console.tailscale.com/admin",
                controlServerURL: officialControlServerURL
            )
        )
        XCTAssertTrue(
            isAuthenticationURLAllowed(
                "https://tailscale.com/login",
                controlServerURL: officialControlServerURL
            )
        )
        XCTAssertFalse(
            isAuthenticationURLAllowed(
                "https://headscale.example.com/register/example",
                controlServerURL: officialControlServerURL
            )
        )
        XCTAssertFalse(
            isAuthenticationURLAllowed(
                "https://tailscale.com.attacker.example/login",
                controlServerURL: officialControlServerURL
            )
        )
        XCTAssertFalse(
            isAuthenticationURLAllowed(
                "http://login.tailscale.com/a/example",
                controlServerURL: officialControlServerURL
            )
        )
        XCTAssertFalse(
            isAuthenticationURLAllowed(
                "awgscale://auth/callback",
                controlServerURL: officialControlServerURL
            )
        )

        // A custom control plane can legitimately hand off to an external IdP.
        XCTAssertTrue(
            isAuthenticationURLAllowed(
                "https://accounts.example.org/oauth",
                controlServerURL: "https://headscale.example.com"
            )
        )
        XCTAssertFalse(
            isAuthenticationURLAllowed(
                "http://accounts.example.org/oauth",
                controlServerURL: "https://headscale.example.com"
            )
        )
        XCTAssertTrue(
            isAuthenticationURLAllowed(
                "http://accounts.example.org/oauth",
                controlServerURL: "http://headscale.example.com"
            )
        )
    }

    func testSharedCallbackStateCannotReplaceActiveInAppLogin() throws {
        let defaults = try XCTUnwrap(sharedDefaults)
        let oldBrowseURL = defaults.object(forKey: IPCConstants.keyBrowseToURL)
        let oldLoginFinished = defaults.object(forKey: IPCConstants.keyLoginFinished)
        defer {
            if let oldBrowseURL {
                defaults.set(oldBrowseURL, forKey: IPCConstants.keyBrowseToURL)
            } else {
                defaults.removeObject(forKey: IPCConstants.keyBrowseToURL)
            }
            if let oldLoginFinished {
                defaults.set(oldLoginFinished, forKey: IPCConstants.keyLoginFinished)
            } else {
                defaults.removeObject(forKey: IPCConstants.keyLoginFinished)
            }
        }

        let state = AppState(vpnPermissionCapability: false)
        state.isLoggingIn = true
        state.browseToURL = "https://login.tailscale.com/a/current"
        defaults.set(
            "https://headscale.example.com/register/stale",
            forKey: IPCConstants.keyBrowseToURL
        )
        defaults.set(true, forKey: IPCConstants.keyLoginFinished)

        state.loadSharedState()

        XCTAssertTrue(state.isLoggingIn)
        XCTAssertEqual(state.browseToURL, "https://login.tailscale.com/a/current")
        XCTAssertNil(defaults.object(forKey: IPCConstants.keyBrowseToURL))
        XCTAssertNil(defaults.object(forKey: IPCConstants.keyLoginFinished))
    }

    func testDefaultVPNPermissionRequiresCurrentCapability() {
        XCTAssertFalse(defaultVPNPermissionEnabled(hasVPNCapability: false, stored: true))
        XCTAssertFalse(defaultVPNPermissionEnabled(hasVPNCapability: false, stored: nil))
        XCTAssertTrue(defaultVPNPermissionEnabled(hasVPNCapability: true, stored: nil))
        XCTAssertTrue(defaultVPNPermissionEnabled(hasVPNCapability: true, stored: true))
        XCTAssertFalse(defaultVPNPermissionEnabled(hasVPNCapability: true, stored: false))
    }

    func testVPNPermissionModeIsSharedWithExtensions() throws {
        let suiteName = "top.yesican.awgscale.tests.mode.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(sharedVPNPermissionModeEnabled(defaults: defaults))
        XCTAssertTrue(
            sharedVPNPermissionModeEnabled(defaultValue: true, defaults: defaults)
        )
        persistSharedVPNPermissionMode(false, defaults: defaults)
        XCTAssertFalse(
            sharedVPNPermissionModeEnabled(defaultValue: true, defaults: defaults)
        )
        persistSharedVPNPermissionMode(true, defaults: defaults)
        XCTAssertTrue(
            sharedVPNPermissionModeEnabled(defaultValue: false, defaults: defaults)
        )
    }

    func testNetworkExtensionEntitlementParsingRequiresPacketTunnelProvider() {
        XCTAssertTrue(entitlementAllowsPacketTunnelProvider(["packet-tunnel-provider"]))
        XCTAssertTrue(entitlementAllowsPacketTunnelProvider(["dns-proxy", "packet-tunnel-provider"] as NSArray))
        XCTAssertTrue(entitlementAllowsPacketTunnelProvider(true))
        XCTAssertFalse(entitlementAllowsPacketTunnelProvider(["dns-proxy"]))
        XCTAssertFalse(entitlementAllowsPacketTunnelProvider(false))
        XCTAssertFalse(entitlementAllowsPacketTunnelProvider(nil))
    }

    func testUnavailableSystemVPNCannotBeEnabled() {
        let state = AppState(vpnPermissionCapability: false)

        XCTAssertFalse(state.canUseVPNPermission)
        XCTAssertFalse(state.usesVPNPermission)

        state.setUsesVPNPermission(true)

        XCTAssertFalse(state.usesVPNPermission)
        XCTAssertEqual(state.lastError, systemVPNUnavailableMessage)
    }

    func testHandleNotifyStateChange() {
        let state = AppState()

        let json = """
        {"State": 5}
        """.data(using: .utf8)!

        state.handleNotify(json)
        XCTAssertEqual(state.ipnState, .running)
    }

    func testHandleNotifyBrowseToURL() {
        let state = AppState()

        let json = """
        {"BrowseToURL": "https://login.tailscale.com/test"}
        """.data(using: .utf8)!

        state.handleNotify(json)
        XCTAssertEqual(state.browseToURL, "https://login.tailscale.com/test")
    }

    func testHandleNotifyLoginFinished() {
        let state = AppState()
        state.isLoggingIn = true
        state.browseToURL = "https://login.tailscale.com/test"

        let json = """
        {"LoginFinished": {}}
        """.data(using: .utf8)!

        state.handleNotify(json)
        XCTAssertFalse(state.isLoggingIn)
        XCTAssertNil(state.browseToURL)
    }

    func testHandleNotifyNetMapUpdatesPeers() {
        let state = AppState()

        let json = """
        {
            "NetMap": {
                "SelfNode": {
                    "ID": 1,
                    "StableID": "self-1",
                    "Name": "my-phone.",
                    "Addresses": ["100.64.0.1/32"],
                    "Online": true,
                    "OS": "iOS"
                },
                "Peers": [
                    {
                        "ID": 2,
                        "StableID": "peer-1",
                        "Name": "server.",
                        "Addresses": ["100.64.0.2/32"],
                        "Online": true,
                        "OS": "linux"
                    },
                    {
                        "ID": 3,
                        "StableID": "peer-2",
                        "Name": "laptop.",
                        "Addresses": ["100.64.0.3/32"],
                        "Online": false,
                        "OS": "macOS"
                    }
                ]
            }
        }
        """.data(using: .utf8)!

        state.handleNotify(json)

        XCTAssertNotNil(state.selfNode)
        XCTAssertEqual(state.selfNode?.displayName, "my-phone")
        XCTAssertTrue(state.selfNode?.isCurrentDevice ?? false)
        // 1 self + 2 peers = 3
        XCTAssertEqual(state.peers.count, 3)
    }

    func testUnauthenticatedNotifyClearsBackendSnapshot() {
        let state = AppState()
        state.currentProfile = LoginProfile(ID: "profile-1", Name: "lei", Key: nil, UserProfile: nil, NetworkProfile: nil, LocalUserID: nil, ControlURL: "https://ctl.example")
        state.prefs = IpnPrefs(WantRunning: true, ExitNodeID: "67", ExitNodeAllowLANAccess: false, ControlURL: "https://ctl.example", Hostname: "phone")
        state.selfNode = PeerNode(from: .init(ID: 1, StableID: "self", Key: nil, Name: "phone.", ComputedName: nil, Hostinfo: nil, Addresses: ["100.64.0.1/32"], Online: true, OS: nil, UserID: nil, KeyExpiry: nil, IsExitNode: nil, AllowedIPs: nil), isSelf: true, userProfile: nil)
        state.peers = [state.selfNode!]
        state.health = HealthState(Warnings: [:])

        let json = """
        {"State": 1}
        """.data(using: .utf8)!

        state.handleNotify(json)

        XCTAssertEqual(state.ipnState, .needsLogin)
        XCTAssertNil(state.currentProfile)
        XCTAssertNil(state.prefs)
        XCTAssertNil(state.selfNode)
        XCTAssertTrue(state.peers.isEmpty)
        XCTAssertNil(state.health)
    }

    func testNoStateNotifyPreservesBackendSnapshot() {
        let state = AppState()
        state.currentProfile = LoginProfile(ID: "profile-1", Name: "lei", Key: nil, UserProfile: nil, NetworkProfile: nil, LocalUserID: nil, ControlURL: "https://ctl.example")
        state.prefs = IpnPrefs(WantRunning: true, ExitNodeID: "67", ExitNodeAllowLANAccess: false, ControlURL: "https://ctl.example", Hostname: "phone")
        state.selfNode = PeerNode(from: .init(ID: 1, StableID: "self", Key: nil, Name: "phone.", ComputedName: nil, Hostinfo: nil, Addresses: ["100.64.0.1/32"], Online: true, OS: nil, UserID: nil, KeyExpiry: nil, IsExitNode: nil, AllowedIPs: nil), isSelf: true, userProfile: nil)
        state.peers = [state.selfNode!]

        let json = """
        {"State": 0}
        """.data(using: .utf8)!

        state.handleNotify(json)

        XCTAssertEqual(state.ipnState, .noState)
        XCTAssertNotNil(state.currentProfile)
        XCTAssertNotNil(state.prefs)
        XCTAssertNotNil(state.selfNode)
        XCTAssertFalse(state.peers.isEmpty)
    }

    func testTransientLoginStateHealthWarningIsHiddenDuringStartup() {
        let state = AppState()
        state.ipnState = .starting
        state.currentProfile = LoginProfile(ID: "profile-1", Name: "lei", Key: nil, UserProfile: nil, NetworkProfile: nil, LocalUserID: nil, ControlURL: "https://ctl.example")

        let json = """
        {
            "Health": {
                "Warnings": {
                    "login-state": {
                        "WarnableCode": "login-state",
                        "Severity": "high",
                        "Title": "You are logged out"
                    },
                    "dns-broken": {
                        "WarnableCode": "dns-broken",
                        "Severity": "high",
                        "Title": "DNS not working"
                    }
                }
            }
        }
        """.data(using: .utf8)!

        state.handleNotify(json)

        XCTAssertNil(state.health?.Warnings?["login-state"])
        XCTAssertNotNil(state.health?.Warnings?["dns-broken"])
    }

    func testLoginStateHealthWarningIsShownWhenRunning() {
        let state = AppState()
        state.ipnState = .running
        state.currentProfile = LoginProfile(ID: "profile-1", Name: "lei", Key: nil, UserProfile: nil, NetworkProfile: nil, LocalUserID: nil, ControlURL: "https://ctl.example")

        let json = """
        {
            "Health": {
                "Warnings": {
                    "login-state": {
                        "WarnableCode": "login-state",
                        "Severity": "high",
                        "Title": "You are logged out"
                    }
                }
            }
        }
        """.data(using: .utf8)!

        state.handleNotify(json)

        XCTAssertNotNil(state.health?.Warnings?["login-state"])
    }

    func testUnauthenticatedNotifyPreservesSnapshotDuringVPNStart() {
        let state = AppState()
        state.currentProfile = LoginProfile(ID: "profile-1", Name: "lei", Key: nil, UserProfile: nil, NetworkProfile: nil, LocalUserID: nil, ControlURL: "https://ctl.example")
        state.prefs = IpnPrefs(WantRunning: false, ExitNodeID: nil, ExitNodeAllowLANAccess: nil, ControlURL: "https://ctl.example", Hostname: "phone")
        state.selfNode = PeerNode(from: .init(ID: 1, StableID: "self", Key: nil, Name: "phone.", ComputedName: nil, Hostinfo: nil, Addresses: ["100.64.0.1/32"], Online: true, OS: nil, UserID: nil, KeyExpiry: nil, IsExitNode: nil, AllowedIPs: nil), isSelf: true, userProfile: nil)
        state.peers = [state.selfNode!]
        state.pendingWantRunning = true

        let json = """
        {"State": 1}
        """.data(using: .utf8)!

        state.handleNotify(json)

        XCTAssertEqual(state.ipnState, .needsLogin)
        XCTAssertNotNil(state.currentProfile)
        XCTAssertNotNil(state.prefs)
        XCTAssertNotNil(state.selfNode)
        XCTAssertFalse(state.peers.isEmpty)
    }

    func testPendingVPNStartKeepsLoginViewHidden() {
        let state = AppState()
        state.ipnState = .needsLogin
        state.pendingWantRunning = true

        XCTAssertFalse(state.shouldShowLoginView)
    }

    func testUnauthenticatedNotifyPreservesSnapshotDuringAwgSync() {
        let state = AppState()
        state.currentProfile = LoginProfile(ID: "profile-1", Name: "lei", Key: nil, UserProfile: nil, NetworkProfile: nil, LocalUserID: nil, ControlURL: "https://ctl.example")
        state.prefs = IpnPrefs(WantRunning: true, ExitNodeID: nil, ExitNodeAllowLANAccess: nil, ControlURL: "https://ctl.example", Hostname: "phone")
        state.selfNode = PeerNode(from: .init(ID: 1, StableID: "self", Key: nil, Name: "phone.", ComputedName: nil, Hostinfo: nil, Addresses: ["100.64.0.1/32"], Online: true, OS: nil, UserID: nil, KeyExpiry: nil, IsExitNode: nil, AllowedIPs: nil), isSelf: true, userProfile: nil)
        state.peers = [state.selfNode!]
        state.awgSyncInProgress = "server"

        let json = """
        {"State": 1}
        """.data(using: .utf8)!

        state.handleNotify(json)

        XCTAssertEqual(state.ipnState, .needsLogin)
        XCTAssertNotNil(state.currentProfile)
        XCTAssertNotNil(state.prefs)
        XCTAssertNotNil(state.selfNode)
        XCTAssertFalse(state.peers.isEmpty)
    }

    func testUnauthenticatedNotifyPreservesSnapshotDuringExitNodeUpdate() {
        let state = AppState()
        state.currentProfile = LoginProfile(ID: "profile-1", Name: "lei", Key: nil, UserProfile: nil, NetworkProfile: nil, LocalUserID: nil, ControlURL: "https://ctl.example")
        state.prefs = IpnPrefs(WantRunning: true, ExitNodeID: nil, ExitNodeAllowLANAccess: nil, ControlURL: "https://ctl.example", Hostname: "phone")
        state.selfNode = PeerNode(from: .init(ID: 1, StableID: "self", Key: nil, Name: "phone.", ComputedName: nil, Hostinfo: nil, Addresses: ["100.64.0.1/32"], Online: true, OS: nil, UserID: nil, KeyExpiry: nil, IsExitNode: nil, AllowedIPs: nil), isSelf: true, userProfile: nil)
        state.peers = [state.selfNode!]
        state.isUpdatingExitNode = true

        let json = """
        {"State": 1}
        """.data(using: .utf8)!

        state.handleNotify(json)

        XCTAssertEqual(state.ipnState, .needsLogin)
        XCTAssertNotNil(state.currentProfile)
        XCTAssertNotNil(state.prefs)
        XCTAssertNotNil(state.selfNode)
        XCTAssertFalse(state.peers.isEmpty)
    }

    func testUnauthenticatedNotifyPreservesAwgSnapshotDuringPermissionModeSwitch() {
        let state = AppState()
        state.currentProfile = LoginProfile(ID: "profile-1", Name: "lei", Key: nil, UserProfile: nil, NetworkProfile: nil, LocalUserID: nil, ControlURL: "https://ctl.example")
        state.prefs = IpnPrefs(WantRunning: true, AmneziaWG: .empty, ExitNodeID: nil, ExitNodeAllowLANAccess: nil, ControlURL: "https://ctl.example", Hostname: "phone")
        state.selfNode = PeerNode(from: .init(ID: 1, StableID: "self", Key: nil, Name: "phone.", ComputedName: nil, Hostinfo: nil, Addresses: ["100.64.0.1/32"], Online: true, OS: nil, UserID: nil, KeyExpiry: nil, IsExitNode: nil, AllowedIPs: nil), isSelf: true, userProfile: nil)
        state.peers = [state.selfNode!]
        state.isSwitchingNetworkMode = true

        let json = """
        {"State": 1}
        """.data(using: .utf8)!

        state.handleNotify(json)

        XCTAssertEqual(state.ipnState, .needsLogin)
        XCTAssertNotNil(state.currentProfile)
        XCTAssertNotNil(state.prefs?.AmneziaWG)
        XCTAssertNotNil(state.selfNode)
        XCTAssertFalse(state.peers.isEmpty)
    }

    func testLocalAWGLookupFailurePreservesLastKnownGoodConfig() async {
        enum LookupFailure: Error { case unavailable }

        let state = AppState(vpnPermissionCapability: false)
        state.currentAwgConfig = AmneziaWGPrefs(JC: 3, S1: 10)
        state.localAwgStatus = true
        let failingClient = LocalAPIClient { _, _, _, _, _ in
            throw LookupFailure.unavailable
        }

        let loaded = await state.loadLocalAwgStatusOnce(
            showMessages: false,
            clientOverride: failingClient
        )

        XCTAssertFalse(loaded)
        XCTAssertTrue(state.localAwgStatus)
        XCTAssertEqual(state.currentAwgConfig?.JC, 3)
        XCTAssertEqual(state.currentAwgConfig?.S1, 10)
    }

    func testOlderStandaloneAWGReadCannotOverwriteNewerResult() async {
        let state = AppState(vpnPermissionCapability: false)
        let gate = LocalPrefsResponseGate()
        let client = LocalAPIClient { _, _, _, _, _ in
            await gate.response()
        }

        let olderRead = Task {
            await state.loadLocalAwgStatusOnce(
                showMessages: false,
                clientOverride: client
            )
        }
        await gate.waitForRequestCount(1)

        let newerRead = Task {
            await state.loadLocalAwgStatusOnce(
                showMessages: false,
                clientOverride: client
            )
        }
        await gate.waitForRequestCount(2)

        await gate.resume(requestID: 1, jc: 7)
        let newerLoaded = await newerRead.value
        XCTAssertTrue(newerLoaded)
        XCTAssertEqual(state.currentAwgConfig?.JC, 7)

        await gate.resume(requestID: 0, jc: 3)
        let olderLoaded = await olderRead.value
        XCTAssertFalse(olderLoaded)
        XCTAssertEqual(state.currentAwgConfig?.JC, 7)
    }

    func testProfileMutationInvalidatesDelayedAWGReadAndClearsOldSnapshot() async {
        let state = AppState(vpnPermissionCapability: false)
        let gate = LocalPrefsResponseGate()
        let client = LocalAPIClient { _, _, _, _, _ in
            await gate.response()
        }
        let oldPeerResult = AwgPeerResult(
            nodeKey: "nodekey:" + String(repeating: "1", count: 64),
            hostname: "old-profile-peer",
            config: .init(JC: 3),
            error: nil
        )
        state.currentAwgConfig = .init(JC: 3)
        state.localAwgStatus = true
        state.awgPeersData["old-profile-peer"] = oldPeerResult
        state.awgPeersStatus["old-profile-peer"] = true
        state.isAwgStatusRefreshing = true

        let delayedOldProfileRead = Task {
            await state.loadLocalAwgStatusOnce(
                showMessages: false,
                clientOverride: client
            )
        }
        await gate.waitForRequestCount(1)

        state.prepareAwgStateForProfileMutation()

        XCTAssertFalse(state.isAwgStatusRefreshing)
        XCTAssertFalse(state.localAwgStatus)
        XCTAssertNil(state.currentAwgConfig)
        XCTAssertTrue(state.awgPeersData.isEmpty)
        XCTAssertTrue(state.awgPeersStatus.isEmpty)

        await gate.resume(requestID: 0, jc: 9)
        let loaded = await delayedOldProfileRead.value
        XCTAssertFalse(loaded)
        XCTAssertNil(state.currentAwgConfig)
        XCTAssertFalse(state.localAwgStatus)
    }

    func testAWGCacheRejectsReusedHostnameFromDifferentNodeKey() {
        let state = AppState(vpnPermissionCapability: false)
        let newPeer = PeerNode(
            from: .init(
                ID: 2,
                StableID: "new-peer",
                Key: "nodekey:new-key",
                Name: "server.",
                ComputedName: nil,
                Hostinfo: .init(Hostname: "server"),
                Addresses: ["100.64.0.2/32"],
                Online: true,
                OS: "linux",
                UserID: nil,
                KeyExpiry: nil,
                IsExitNode: nil,
                AllowedIPs: nil
            ),
            isSelf: false,
            userProfile: nil
        )
        state.peers = [newPeer]
        let stale = AwgPeerResult(
            nodeKey: "nodekey:old-key",
            hostname: "server",
            config: .init(JC: 3),
            error: nil
        )
        state.awgPeersData["server"] = stale
        state.awgPeersStatus["server"] = true

        XCTAssertFalse(state.peerHasAwgConfig(newPeer))

        state.pruneAwgPeerCache(to: ["new-key"])
        XCTAssertTrue(state.awgPeersData.isEmpty)
        XCTAssertTrue(state.awgPeersStatus.isEmpty)
    }

    func testAWGSyncDoesNotGuessBetweenDuplicateHostnames() {
        func makePeer(stableID: String, nodeKey: String?) -> PeerNode {
            PeerNode(
                from: .init(
                    ID: 2,
                    StableID: stableID,
                    Key: nodeKey,
                    Name: "server.",
                    ComputedName: nil,
                    Hostinfo: .init(Hostname: "server"),
                    Addresses: ["100.64.0.2/32"],
                    Online: true,
                    OS: "linux",
                    UserID: nil,
                    KeyExpiry: nil,
                    IsExitNode: nil,
                    AllowedIPs: nil
                ),
                isSelf: false,
                userProfile: nil
            )
        }

        let state = AppState(vpnPermissionCapability: false)
        let firstKey = "nodekey:" + String(repeating: "1", count: 64)
        let secondKey = "nodekey:" + String(repeating: "2", count: 64)
        let target = makePeer(stableID: "target", nodeKey: nil)
        state.peers = [
            target,
            makePeer(stableID: "duplicate-1", nodeKey: firstKey),
            makePeer(stableID: "duplicate-2", nodeKey: secondKey),
        ]

        XCTAssertNil(state.fullNodeKeyForAwgSync(peer: target, peerData: nil))

        let discovered = AwgPeerResult(
            nodeKey: secondKey,
            hostname: "server",
            config: .init(JC: 3),
            error: nil
        )
        state.awgPeersData["server"] = discovered
        XCTAssertFalse(state.peerHasAwgConfig(target))
        XCTAssertEqual(
            state.fullNodeKeyForAwgSync(peer: target, peerData: discovered),
            nil
        )

        state.peers = [target]
        XCTAssertEqual(
            state.fullNodeKeyForAwgSync(peer: target, peerData: discovered),
            secondKey
        )

        let selectedRawKey = String(repeating: "a", count: 64)
        let rawTarget = makePeer(stableID: "raw-target", nodeKey: selectedRawKey)
        state.peers = [
            rawTarget,
            makePeer(stableID: "duplicate-1", nodeKey: firstKey),
        ]
        let matchingDiscovery = AwgPeerResult(
            nodeKey: "nodekey:\(selectedRawKey)",
            hostname: "server",
            config: .init(JC: 3),
            error: nil
        )
        XCTAssertEqual(
            state.fullNodeKeyForAwgSync(peer: rawTarget, peerData: matchingDiscovery),
            "nodekey:\(selectedRawKey)"
        )
        XCTAssertNil(
            state.fullNodeKeyForAwgSync(peer: rawTarget, peerData: discovered)
        )
    }

    func testAWGRefreshFingerprintTracksNodeKeyAndReachability() {
        func makePeer(nodeKey: String, online: Bool) -> PeerNode {
            PeerNode(
                from: .init(
                    ID: 2,
                    StableID: "same-stable-id",
                    Key: nodeKey,
                    Name: "server.",
                    ComputedName: nil,
                    Hostinfo: .init(Hostname: "server"),
                    Addresses: ["100.64.0.2/32"],
                    Online: online,
                    OS: "linux",
                    UserID: nil,
                    KeyExpiry: nil,
                    IsExitNode: nil,
                    AllowedIPs: nil
                ),
                isSelf: false,
                userProfile: nil
            )
        }

        let state = AppState(vpnPermissionCapability: false)
        state.peers = [makePeer(nodeKey: "nodekey:first", online: false)]
        let initial = state.awgPeerRefreshFingerprint()

        state.peers = [makePeer(nodeKey: "nodekey:second", online: false)]
        let rotatedKey = state.awgPeerRefreshFingerprint()
        XCTAssertNotEqual(initial, rotatedKey)

        state.peers = [makePeer(nodeKey: "nodekey:second", online: true)]
        let reachable = state.awgPeerRefreshFingerprint()
        XCTAssertNotEqual(rotatedKey, reachable)

        XCTAssertFalse(
            awgRefreshNeedsFollowUp(
                force: false,
                activePeerFingerprint: reachable,
                currentPeerFingerprint: reachable
            )
        )
        XCTAssertTrue(
            awgRefreshNeedsFollowUp(
                force: false,
                activePeerFingerprint: rotatedKey,
                currentPeerFingerprint: reachable
            )
        )
        XCTAssertTrue(
            awgRefreshNeedsFollowUp(
                force: true,
                activePeerFingerprint: reachable,
                currentPeerFingerprint: reachable
            )
        )

        state.isAwgStatusRefreshing = true
        XCTAssertTrue(state.isAnyAwgOperationInProgress)
    }

    func testAWGOperationCoordinatorQueuesOnceAndRejectsStaleCompletion() {
        var coordinator = AwgOperationCoordinator()

        let first = coordinator.begin()
        coordinator.queueRefresh()
        XCTAssertEqual(coordinator.finish(first), true)
        XCTAssertFalse(coordinator.hasPendingRefresh)
        XCTAssertFalse(coordinator.isCurrent(first))

        let stale = coordinator.begin()
        coordinator.queueRefresh()
        coordinator.invalidate()
        XCTAssertNil(coordinator.finish(stale))
        XCTAssertFalse(coordinator.hasPendingRefresh)

        let current = coordinator.begin()
        XCTAssertEqual(coordinator.finish(current), false)
    }

    func testAWGOperationStartPolicyRejectsBackendTransitions() {
        XCTAssertNil(
            awgOperationStartBlockReason(
                isAnyAwgOperationInProgress: false,
                isBackendTransitionInProgress: false
            )
        )
        XCTAssertEqual(
            awgOperationStartBlockReason(
                isAnyAwgOperationInProgress: false,
                isBackendTransitionInProgress: true
            ),
            "Network backend is busy"
        )
        XCTAssertEqual(
            awgOperationStartBlockReason(
                isAnyAwgOperationInProgress: true,
                isBackendTransitionInProgress: true
            ),
            "Another AWG operation is already in progress"
        )
    }

    func testStartLoginDoesNotClearVisibleSession() {
        let state = AppState()
        state.ipnState = .running
        state.currentProfile = LoginProfile(ID: "profile-1", Name: "lei", Key: nil, UserProfile: nil, NetworkProfile: nil, LocalUserID: nil, ControlURL: "https://ctl.example")
        state.selfNode = PeerNode(from: .init(ID: 1, StableID: "self", Key: nil, Name: "phone.", ComputedName: nil, Hostinfo: nil, Addresses: ["100.64.0.1/32"], Online: true, OS: nil, UserID: nil, KeyExpiry: nil, IsExitNode: nil, AllowedIPs: nil), isSelf: true, userProfile: nil)
        state.peers = [state.selfNode!]

        state.startLogin(controlURL: "https://ctl.example")

        XCTAssertFalse(state.isLoggingIn)
        XCTAssertEqual(state.ipnState, .running)
        XCTAssertNotNil(state.currentProfile)
        XCTAssertNotNil(state.selfNode)
        XCTAssertFalse(state.peers.isEmpty)
    }

    func testLoginBrowserDismissDoesNotAssumeMachineAuth() {
        let state = AppState()
        state.isLoggingIn = true
        state.ipnState = .needsLogin
        state.browseToURL = "https://login.tailscale.com/a/test"

        state.loginBrowserDidDismiss()

        XCTAssertFalse(state.isAwaitingMachineAuth)
        XCTAssertEqual(state.ipnState, .needsLogin)
        XCTAssertNil(state.browseToURL)
    }

    func testLogoutResetsState() {
        let state = AppState()
        state.ipnState = .running
        state.peers = [PeerNode(from: .init(ID: 1, StableID: "x", Key: nil, Name: "test.", ComputedName: nil, Hostinfo: nil, Addresses: [], Online: true, OS: nil, UserID: nil, KeyExpiry: nil, IsExitNode: nil, AllowedIPs: nil), isSelf: false, userProfile: nil)]
        state.currentAwgConfig = .init(JC: 3)
        state.localAwgStatus = true
        state.awgPeersStatus["test"] = true

        state.logout()

        XCTAssertEqual(state.ipnState, .needsLogin)
        XCTAssertTrue(state.peers.isEmpty)
        XCTAssertNil(state.selfNode)
        XCTAssertNil(state.currentProfile)
        XCTAssertNil(state.currentAwgConfig)
        XCTAssertFalse(state.localAwgStatus)
        XCTAssertTrue(state.awgPeersStatus.isEmpty)
    }

    func testHandleNotifyInvalidJSON() {
        let state = AppState()

        let badData = "not json".data(using: .utf8)!
        state.handleNotify(badData)

        XCTAssertNotNil(state.lastError)
    }

    func testTailnetLockSigningQRPayloadValidation() throws {
        let payload = """
          tailscale://sign-device/v1/?nk=nodekey%3Aabc&tp=tlpub%3Adef&dn=iPhone&os=iOS&em=user%40example.com&hm=0123456789abcdef
        """

        XCTAssertEqual(
            try validatedTailnetLockSigningURL(from: payload),
            payload.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        XCTAssertTrue(
            try validatedTailnetLockSigningURL(
                from: "TAILSCALE://SIGN-DEVICE/v1/?nk=x&tp=x&dn=x&os=x&em=x&hm=x"
            ).hasPrefix("tailscale://sign-device/")
        )
        XCTAssertThrowsError(
            try validatedTailnetLockSigningURL(
                from: "https://sign-device/v1/?nk=x&tp=x&dn=x&os=x&em=x&hm=x"
            )
        )
        XCTAssertThrowsError(
            try validatedTailnetLockSigningURL(
                from: "tailscale://sign-device/v2/?nk=x&tp=x&dn=x&os=x&em=x&hm=x"
            )
        )
        XCTAssertThrowsError(
            try validatedTailnetLockSigningURL(
                from: "tailscale://sign-device/v1/?nk=x&tp=x&dn=x&os=x&em=x"
            )
        ) { error in
            XCTAssertEqual(
                error as? TailnetLockSigningURLValidationError,
                .missingParameter("hm")
            )
        }
    }

    func testTailscaleTimestampParserSupportsFractionalAndWholeSeconds() {
        XCTAssertNotNil(parsedTailscaleTimestamp("2026-07-31T12:34:56Z"))
        XCTAssertNotNil(parsedTailscaleTimestamp("2026-07-31T12:34:56.123456789Z"))
        XCTAssertNil(parsedTailscaleTimestamp(""))
        XCTAssertNil(parsedTailscaleTimestamp("not-a-date"))
    }

    func testHighSeverityHealthNotificationsAreStableAndFiltered() {
        let health = HealthState(Warnings: [
            "dns-broken": UnhealthyState(
                WarnableCode: "dns-broken",
                Severity: "high",
                Title: "DNS unavailable",
                Text: "MagicDNS cannot resolve names.",
                BrokenSince: nil,
                ImpactsConnectivity: true
            ),
            "minor": UnhealthyState(
                WarnableCode: "minor",
                Severity: "low",
                Title: "Minor issue",
                Text: "No action required.",
                BrokenSince: nil,
                ImpactsConnectivity: false
            ),
        ])

        let first = highSeverityHealthNotifications(from: health)
        let second = highSeverityHealthNotifications(from: health)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(
            first.first?.identifier,
            healthNotificationIdentifier(
                for: "dns-broken",
                title: "DNS unavailable",
                message: "MagicDNS cannot resolve names."
            )
        )
        XCTAssertEqual(first.first?.title, "DNS unavailable")
        XCTAssertNotEqual(
            first.first?.identifier,
            healthNotificationIdentifier(
                for: "dns-broken",
                title: "DNS unavailable",
                message: "Updated warning text."
            )
        )
        XCTAssertTrue(
            highSeverityHealthNotifications(from: Optional<HealthState>.none).isEmpty
        )
    }
}
