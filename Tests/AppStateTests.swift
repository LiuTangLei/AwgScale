import Foundation
import XCTest
@testable import AwgScale

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

        state.logout()

        XCTAssertEqual(state.ipnState, .needsLogin)
        XCTAssertTrue(state.peers.isEmpty)
        XCTAssertNil(state.selfNode)
        XCTAssertNil(state.currentProfile)
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
