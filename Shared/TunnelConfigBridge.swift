import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Tunnel Config Bridge Types
//
// These helpers are placed in the Shared target so both the PacketTunnel
// extension and the unit-test target can use them. They are intentionally
// free of NetworkExtension types so they can be exercised in tests.

/// JSON shape produced by Go's `TunnelConfig` (see ios/libtailscale/tunnelconfig.go).
struct TunnelConfigFromGo: Codable, Equatable {
    let localAddresses: [String]
    let routes: [String]
    let excludeRoutes: [String]?
    let dnsServers: [String]
    let dnsDomains: [String]
    let dnsMatchDomains: [String]?
    let mtu: Int
}

/// CIDR prefix length -> IPv4 dotted-decimal subnet mask (e.g. 24 -> "255.255.255.0").
/// Values outside [0, 32] are clamped.
func ipv4PrefixLenToMask(_ prefixLen: Int) -> String {
    let clamped = max(0, min(prefixLen, 32))
    var mask: UInt32 = 0
    if clamped > 0 {
        mask = UInt32.max << (32 - clamped)
    }
    let b0 = UInt8((mask >> 24) & 0xFF)
    let b1 = UInt8((mask >> 16) & 0xFF)
    let b2 = UInt8((mask >> 8) & 0xFF)
    let b3 = UInt8(mask & 0xFF)
    return "\(b0).\(b1).\(b2).\(b3)"
}

/// Detects the IP version of a packet by looking at the first nibble.
/// Returns AF_INET / AF_INET6 (as NSNumber for NEPacketTunnelFlow), or nil
/// for unknown / empty packets.
func ipPacketProtocolFamily(for packet: Data) -> NSNumber? {
    guard let firstByte = packet.first else { return nil }
    switch firstByte >> 4 {
    case 4:
        return NSNumber(value: AF_INET)
    case 6:
        return NSNumber(value: AF_INET6)
    default:
        return nil
    }
}

/// Splits a "addr/prefixLen" string. Returns nil on malformed input.
func parseCIDR(_ cidr: String) -> (address: String, prefixLen: Int)? {
    let parts = cidr.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }
    guard let prefix = Int(parts[1]) else { return nil }
    let addr = String(parts[0])
    if addr.isEmpty { return nil }
    return (addr, prefix)
}

func isIPv4DefaultRoute(address: String, prefixLen: Int) -> Bool {
    address == "0.0.0.0" && prefixLen == 0
}

func isIPv6DefaultRoute(address: String, prefixLen: Int) -> Bool {
    address == "::" && prefixLen == 0
}
