import XCTest
@testable import AwgScale

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

    func testIpnStateBackendSnapshotClearing() {
        XCTAssertFalse(IpnState.noState.clearsBackendSnapshot)
        XCTAssertTrue(IpnState.needsLogin.clearsBackendSnapshot)
        XCTAssertTrue(IpnState.needsMachineAuth.clearsBackendSnapshot)
        XCTAssertFalse(IpnState.stopped.clearsBackendSnapshot)
        XCTAssertFalse(IpnState.starting.clearsBackendSnapshot)
        XCTAssertFalse(IpnState.running.clearsBackendSnapshot)
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
        let object = try JSONSerialization.jsonObject(with: data)
        let dict = try XCTUnwrap(object as? [String: Any])

        XCTAssertEqual(dict["WantRunning"] as? Bool, true)
        XCTAssertEqual(dict["WantRunningSet"] as? Bool, true)
        // Fields not set should not appear (nil encoding)
        XCTAssertNil(dict["ExitNodeID"])
        XCTAssertNil(dict["ExitNodeIDSet"])
    }

    // MARK: - AWG v2/v3 compatibility

    func testDecodeAWGV3SnakeCaseAndLegacyScalarRanges() throws {
        let key = String(repeating: "42", count: 32)
        let json = """
        {
            "jc": 4,
            "h1": 123456,
            "header_protection_key": "\(key)",
            "content_padding_addition": "5-31",
            "rekey_after_time": 120,
            "max_handshake_attempts": {"min": 8, "max": 12}
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(AmneziaWGPrefs.self, from: json)
        XCTAssertEqual(config.JC, 4)
        XCTAssertEqual(config.H1?.min, 123456)
        XCTAssertEqual(config.H1?.max, 123456)
        XCTAssertEqual(config.HeaderProtectionKey, key)
        XCTAssertEqual(config.ContentPaddingAddition?.min, 5)
        XCTAssertEqual(config.ContentPaddingAddition?.max, 31)
        XCTAssertEqual(config.RekeyAfterTime?.min, 120)
        XCTAssertEqual(config.RekeyAfterTime?.max, 120)
        XCTAssertEqual(config.MaxHandshakeAttempts?.min, 8)
        XCTAssertEqual(config.MaxHandshakeAttempts?.max, 12)
        XCTAssertTrue(config.isV3)
        XCTAssertEqual(config.profileVersion, "AWG v3")
    }

    func testDecodeLegacyAWGV2AndPrefsWrapper() throws {
        let json = """
        {
            "AmneziaWG": {
                "JC": 3,
                "JMin": 40,
                "JMax": 70,
                "H1": 123456,
                "I1": "<b 0xc0><r 32>"
            }
        }
        """.data(using: .utf8)!

        let config = try decodeAmneziaWGConfigJSON(json)
        XCTAssertEqual(config.JC, 3)
        XCTAssertEqual(config.H1?.min, 123456)
        XCTAssertEqual(config.I1, "<b 0xc0><r 32>")
        XCTAssertFalse(config.isV3)
        XCTAssertTrue(config.hasNonDefaultValues)
        XCTAssertEqual(config.profileVersion, "AWG v2")
    }

    func testAWGV3CanonicalEncodingPreservesAllFields() throws {
        let config = AmneziaWGPrefs(
            S1: 12,
            S2: 12,
            S3: 12,
            S4: 12,
            HeaderProtectionKey: String(repeating: "ab", count: 32),
            ContentPaddingAddition: .init(min: 5, max: 31),
            RekeyAfterTime: .init(min: 120, max: 180),
            RekeyTimeout: .init(min: 5, max: 8),
            RejectAfterTime: .init(min: 180, max: 240),
            KeepaliveTimeout: .init(min: 10, max: 20),
            MaxHandshakeAttempts: .init(min: 8, max: 12)
        )

        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AmneziaWGPrefs.self, from: encoded)
        XCTAssertEqual(decoded.HeaderProtectionKey, config.HeaderProtectionKey)
        XCTAssertEqual(decoded.ContentPaddingAddition?.max, 31)
        XCTAssertEqual(decoded.RekeyAfterTime?.max, 180)
        XCTAssertEqual(decoded.RekeyTimeout?.min, 5)
        XCTAssertEqual(decoded.RejectAfterTime?.max, 240)
        XCTAssertEqual(decoded.KeepaliveTimeout?.min, 10)
        XCTAssertEqual(decoded.MaxHandshakeAttempts?.max, 12)
        XCTAssertTrue(decoded.isV3)
    }

    func testAWGAllZeroProtectionKeyRemainsStandardWireGuard() throws {
        let json = """
        {"header_protection_key": "\(String(repeating: "0", count: 64))"}
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(AmneziaWGPrefs.self, from: json)
        XCTAssertFalse(config.isV3)
        XCTAssertFalse(config.hasNonDefaultValues)
        XCTAssertEqual(config.profileVersion, "Standard WireGuard")
    }

    func testAWGDecoderRejectsUnrelatedObject() {
        let json = #"{"unrelated": true}"#.data(using: .utf8)!
        XCTAssertThrowsError(try decodeAmneziaWGConfigJSON(json))
    }

    func testAWGPeerResultDistinguishesStandardFromUnavailable() {
        let standard = AwgPeerResult(nodeKey: "nodekey:standard", hostname: "standard", config: nil, error: nil)
        XCTAssertTrue(standard.isStandardWireGuard)
        XCTAssertFalse(standard.hasAwgConfig)

        let unavailable = AwgPeerResult(
            nodeKey: "nodekey:offline",
            hostname: "offline",
            config: nil,
            error: "request timed out"
        )
        XCTAssertFalse(unavailable.isStandardWireGuard)
        XCTAssertFalse(unavailable.hasAwgConfig)
        XCTAssertEqual(unavailable.lookupError, "request timed out")

        let v3 = AwgPeerResult(
            nodeKey: "nodekey:v3",
            hostname: "v3",
            config: .init(RekeyAfterTime: .init(min: 120, max: 180)),
            error: nil
        )
        XCTAssertTrue(v3.hasAwgConfig)
        XCTAssertFalse(v3.isStandardWireGuard)
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
        // Tailscale 1.102 requires PeerChanges for non-Windows updates and
        // rejects combining it with the legacy RateLimit option.
        let expected = 8 | 4 | 2 | 64 | 128 | (1 << 12)  // = 4302
        XCTAssertEqual(NotifyWatchOpt.defaultMask, expected)
        XCTAssertEqual(NotifyWatchOpt.defaultMask & NotifyWatchOpt.rateLimitNetmaps, 0)
        XCTAssertNotEqual(NotifyWatchOpt.defaultMask & NotifyWatchOpt.peerChanges, 0)
    }
}
