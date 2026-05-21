import XCTest
@testable import AwgScale

@MainActor
final class AppStateTests: XCTestCase {

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
}
