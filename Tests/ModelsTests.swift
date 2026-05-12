import XCTest
@testable import Tailscale

final class ModelsTests: XCTestCase {

    // MARK: - IpnState

    func testIpnStateFromRawValue() {
        XCTAssertEqual(IpnState(rawValue: 0), .noState)
        XCTAssertEqual(IpnState(rawValue: 1), .needsLogin)
        XCTAssertEqual(IpnState(rawValue: 2), .needsMachineAuth)
        XCTAssertEqual(IpnState(rawValue: 3), .stopped)
        XCTAssertEqual(IpnState(rawValue: 4), .starting)
        XCTAssertEqual(IpnState(rawValue: 5), .running)
        XCTAssertNil(IpnState(rawValue: 99))
    }

    // MARK: - Notify Decoding

    func testDecodeNotifyWithState() throws {
        let json = """
        {"State": 5}
        """.data(using: .utf8)!

        let notify = try JSONDecoder().decode(IpnNotify.self, from: json)
        XCTAssertEqual(notify.State, 5)
        XCTAssertNil(notify.BrowseToURL)
        XCTAssertNil(notify.LoginFinished)
    }

    func testDecodeNotifyWithBrowseToURL() throws {
        let json = """
        {"BrowseToURL": "https://login.tailscale.com/a/xyz"}
        """.data(using: .utf8)!

        let notify = try JSONDecoder().decode(IpnNotify.self, from: json)
        XCTAssertEqual(notify.BrowseToURL, "https://login.tailscale.com/a/xyz")
        XCTAssertNil(notify.State)
    }

    func testDecodeNotifyWithLoginFinished() throws {
        let json = """
        {"LoginFinished": {}}
        """.data(using: .utf8)!

        let notify = try JSONDecoder().decode(IpnNotify.self, from: json)
        XCTAssertNotNil(notify.LoginFinished)
    }

    func testDecodeNotifyWithPrefs() throws {
        let json = """
        {"Prefs": {"WantRunning": true, "ExitNodeID": "", "ControlURL": "https://controlplane.tailscale.com"}}
        """.data(using: .utf8)!

        let notify = try JSONDecoder().decode(IpnNotify.self, from: json)
        XCTAssertEqual(notify.Prefs?.WantRunning, true)
        XCTAssertEqual(notify.Prefs?.ControlURL, "https://controlplane.tailscale.com")
    }

    // MARK: - MaskedPrefs

    func testMaskedPrefsEncoding() throws {
        let prefs = MaskedPrefs.setWantRunning(true)
        let data = try JSONEncoder().encode(prefs)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(dict["WantRunning"] as? Bool, true)
        XCTAssertEqual(dict["WantRunningSet"] as? Bool, true)
        // Fields not set should not appear (nil encoding)
        XCTAssertNil(dict["ExitNodeID"])
        XCTAssertNil(dict["ExitNodeIDSet"])
    }

    // MARK: - LoginProfile

    func testDecodeLoginProfile() throws {
        let json = """
        {
            "ID": "prof-123",
            "Name": "user@example.com",
            "Key": "key-abc",
            "ControlURL": "https://controlplane.tailscale.com",
            "LocalUserID": "local-1"
        }
        """.data(using: .utf8)!

        let profile = try JSONDecoder().decode(LoginProfile.self, from: json)
        XCTAssertEqual(profile.ID, "prof-123")
        XCTAssertEqual(profile.Name, "user@example.com")
        XCTAssertEqual(profile.ControlURL, "https://controlplane.tailscale.com")
    }

    // MARK: - NetworkMap

    func testDecodeNetworkMap() throws {
        let json = """
        {
            "SelfNode": {
                "ID": 1,
                "StableID": "stable-1",
                "Name": "my-iphone.",
                "Addresses": ["100.64.0.1/32"],
                "Online": true,
                "OS": "iOS"
            },
            "Peers": [
                {
                    "ID": 2,
                    "StableID": "stable-2",
                    "Name": "my-laptop.",
                    "Addresses": ["100.64.0.2/32"],
                    "Online": true,
                    "OS": "macOS"
                }
            ],
            "Domain": "example.com"
        }
        """.data(using: .utf8)!

        let netMap = try JSONDecoder().decode(NetworkMap.self, from: json)
        XCTAssertEqual(netMap.SelfNode?.Name, "my-iphone.")
        XCTAssertEqual(netMap.SelfNode?.Online, true)
        XCTAssertEqual(netMap.Peers?.count, 1)
        XCTAssertEqual(netMap.Peers?.first?.Name, "my-laptop.")
        XCTAssertEqual(netMap.Domain, "example.com")
    }

    func testPeerDisplayNameOnlyRemovesTrailingDot() {
        let peer = PeerNode(
            from: .init(
                ID: 1,
                StableID: "stable-1",
                Key: nil,
                Name: "server",
                ComputedName: nil,
                Hostinfo: nil,
                Addresses: [],
                Online: true,
                OS: nil,
                UserID: nil,
                KeyExpiry: nil,
                IsExitNode: nil,
                AllowedIPs: nil
            ),
            isSelf: false,
            userProfile: nil
        )

        XCTAssertEqual(peer.displayName, "server")
    }

    func testPeerExitNodeFromAllowedIPs() {
        let peer = PeerNode(
            from: .init(
                ID: 2,
                StableID: "stable-2",
                Key: nil,
                Name: "router.",
                ComputedName: nil,
                Hostinfo: nil,
                Addresses: ["100.64.0.2/32"],
                Online: true,
                OS: "linux",
                UserID: nil,
                KeyExpiry: nil,
                IsExitNode: nil,
                AllowedIPs: ["0.0.0.0/0", "::/0"]
            ),
            isSelf: false,
            userProfile: nil
        )

        XCTAssertTrue(peer.isExitNode)
    }

    func testPeerHostnamePrefersHostinfoForMatching() {
        let peer = PeerNode(
            from: .init(
                ID: 3,
                StableID: "stable-3",
                Key: nil,
                Name: "display-name.tailnet.ts.net",
                ComputedName: "computed-name",
                Hostinfo: .init(Hostname: "hostinfo-name"),
                Addresses: [],
                Online: true,
                OS: nil,
                UserID: nil,
                KeyExpiry: nil,
                IsExitNode: nil,
                AllowedIPs: nil
            ),
            isSelf: false,
            userProfile: nil
        )

        XCTAssertEqual(peer.hostname, "hostinfo-name")
        XCTAssertEqual(peer.normalizedHostname, "hostinfo-name")
    }

    // MARK: - Health

    func testDecodeHealthState() throws {
        let json = """
        {
            "Warnings": {
                "dns-broken": {
                    "WarnableCode": "dns-broken",
                    "Severity": "high",
                    "Title": "DNS not working",
                    "Text": "DNS resolution is failing",
                    "ImpactsConnectivity": true
                }
            }
        }
        """.data(using: .utf8)!

        let health = try JSONDecoder().decode(HealthState.self, from: json)
        XCTAssertEqual(health.Warnings?.count, 1)
        let warning = health.Warnings?["dns-broken"]
        XCTAssertEqual(warning?.Severity, "high")
        XCTAssertEqual(warning?.ImpactsConnectivity, true)
    }

    // MARK: - NotifyWatchOpt

    func testDefaultMask() {
        // Should match: Netmap(8) | Prefs(4) | InitialState(2) | InitialHealthState(128) | RateLimitNetmaps(256)
        let expected = 8 | 4 | 2 | 128 | 256  // = 398
        XCTAssertEqual(NotifyWatchOpt.defaultMask, expected)
    }
}
