import XCTest
@testable import Tailscale

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
