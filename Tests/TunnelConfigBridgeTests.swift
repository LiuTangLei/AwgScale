import XCTest
@testable import Tailscale

final class TunnelConfigBridgeTests: XCTestCase {

    // MARK: - ipv4PrefixLenToMask

    func testIPv4PrefixLenToMaskCommonValues() {
        XCTAssertEqual(ipv4PrefixLenToMask(0), "0.0.0.0")
        XCTAssertEqual(ipv4PrefixLenToMask(8), "255.0.0.0")
        XCTAssertEqual(ipv4PrefixLenToMask(10), "255.192.0.0") // Tailscale CGNAT
        XCTAssertEqual(ipv4PrefixLenToMask(16), "255.255.0.0")
        XCTAssertEqual(ipv4PrefixLenToMask(24), "255.255.255.0")
        XCTAssertEqual(ipv4PrefixLenToMask(32), "255.255.255.255")
    }

    func testIPv4PrefixLenToMaskClampsOutOfRange() {
        XCTAssertEqual(ipv4PrefixLenToMask(-5), "0.0.0.0")
        XCTAssertEqual(ipv4PrefixLenToMask(64), "255.255.255.255")
    }

    // MARK: - ipPacketProtocolFamily

    func testProtocolFamilyIPv4() {
        // First nibble 4 -> IPv4 header
        let packet = Data([0x45, 0x00, 0x00, 0x00])
        XCTAssertEqual(ipPacketProtocolFamily(for: packet), NSNumber(value: AF_INET))
    }

    func testProtocolFamilyIPv6() {
        // First nibble 6 -> IPv6 header
        let packet = Data([0x60, 0x00, 0x00, 0x00])
        XCTAssertEqual(ipPacketProtocolFamily(for: packet), NSNumber(value: AF_INET6))
    }

    func testProtocolFamilyEmpty() {
        XCTAssertNil(ipPacketProtocolFamily(for: Data()))
    }

    func testProtocolFamilyUnknownVersion() {
        let packet = Data([0x12, 0x34])
        XCTAssertNil(ipPacketProtocolFamily(for: packet))
    }

    // MARK: - parseCIDR

    func testParseCIDRIPv4() {
        let parsed = parseCIDR("100.64.0.1/32")
        XCTAssertEqual(parsed?.address, "100.64.0.1")
        XCTAssertEqual(parsed?.prefixLen, 32)
    }

    func testParseCIDRIPv6() {
        let parsed = parseCIDR("fd7a:115c:a1e0::1/128")
        XCTAssertEqual(parsed?.address, "fd7a:115c:a1e0::1")
        XCTAssertEqual(parsed?.prefixLen, 128)
    }

    func testParseCIDRMalformed() {
        XCTAssertNil(parseCIDR("not-a-cidr"))
        XCTAssertNil(parseCIDR("/24"))
        XCTAssertNil(parseCIDR("10.0.0.1/abc"))
        XCTAssertNil(parseCIDR(""))
    }

    func testDefaultRouteDetection() {
        XCTAssertTrue(isIPv4DefaultRoute(address: "0.0.0.0", prefixLen: 0))
        XCTAssertTrue(isIPv6DefaultRoute(address: "::", prefixLen: 0))
        XCTAssertFalse(isIPv4DefaultRoute(address: "100.64.0.0", prefixLen: 10))
        XCTAssertFalse(isIPv6DefaultRoute(address: "fd7a:115c:a1e0::", prefixLen: 48))
    }

    // MARK: - TunnelConfigFromGo decoding

    /// JSON shape produced by the Go side: must round-trip without loss.
    func testDecodeTunnelConfigFromGoFull() throws {
        let json = """
        {
          "localAddresses": ["100.64.0.2/32", "fd7a:115c:a1e0::1/128"],
          "routes": ["10.1.0.0/16", "fd00::/8"],
          "excludeRoutes": ["192.168.1.0/24"],
          "dnsServers": ["100.100.100.100"],
          "dnsDomains": ["example.com"],
          "dnsMatchDomains": ["ts.net"],
          "mtu": 1380
        }
        """.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(TunnelConfigFromGo.self, from: json)
        XCTAssertEqual(cfg.localAddresses, ["100.64.0.2/32", "fd7a:115c:a1e0::1/128"])
        XCTAssertEqual(cfg.routes, ["10.1.0.0/16", "fd00::/8"])
        XCTAssertEqual(cfg.excludeRoutes, ["192.168.1.0/24"])
        XCTAssertEqual(cfg.dnsServers, ["100.100.100.100"])
        XCTAssertEqual(cfg.dnsDomains, ["example.com"])
        XCTAssertEqual(cfg.dnsMatchDomains, ["ts.net"])
        XCTAssertEqual(cfg.mtu, 1380)
    }

    /// Optional fields in the JSON should be `nil` after decoding.
    func testDecodeTunnelConfigFromGoOmittedOptionals() throws {
        let json = """
        {
          "localAddresses": ["100.64.0.2/32"],
          "routes": ["100.64.0.0/10"],
          "dnsServers": ["100.100.100.100"],
          "dnsDomains": [],
          "mtu": 1280
        }
        """.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(TunnelConfigFromGo.self, from: json)
        XCTAssertNil(cfg.excludeRoutes)
        XCTAssertNil(cfg.dnsMatchDomains)
        XCTAssertEqual(cfg.dnsDomains, [])
        XCTAssertEqual(cfg.mtu, 1280)
    }

    func testDecodeTunnelConfigFromGoMissingRequiredFails() {
        // Missing "routes" → required by the struct, must fail.
        let json = """
        {
          "localAddresses": [],
          "dnsServers": [],
          "dnsDomains": [],
          "mtu": 1280
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(TunnelConfigFromGo.self, from: json))
    }
}
