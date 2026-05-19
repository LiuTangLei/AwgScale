import Foundation

// MARK: - ipn.State

/// Maps to Go's ipn.State.
/// Values match the Go constants exactly.
enum IpnState: Int, Codable {
    case noState = 0
    case needsLogin = 1
    case needsMachineAuth = 2
    case stopped = 3
    case starting = 4
    case running = 5

    var displayName: String {
        switch self {
        case .noState: return "Initializing"
        case .needsLogin: return "Not Signed In"
        case .needsMachineAuth: return "Awaiting Approval"
        case .stopped: return "Disconnected"
        case .starting: return "Connecting"
        case .running: return "Connected"
        }
    }

    var clearsBackendSnapshot: Bool {
        self == .needsLogin || self == .needsMachineAuth
    }
}

// MARK: - ipn.Notify

/// Maps to Go's ipn.Notify — the primary event type from WatchNotifications.
struct IpnNotify: Codable {
    let Version: String?
    let State: Int?
    let Prefs: IpnPrefs?
    let NetMap: NetworkMap?
    let BrowseToURL: String?
    let LoginFinished: LoginFinished?
    let Health: HealthState?
    let FilesWaiting: EmptyMessage?
    let IncomingFiles: [TaildropIncomingFile]?
    let OutgoingFiles: [TaildropOutgoingFile]?

    struct LoginFinished: Codable {}
}

struct EmptyMessage: Codable {}

// MARK: - ipn.Prefs

/// Maps to Go's ipn.Prefs.
struct IpnPrefs: Codable {
    let WantRunning: Bool?
    var RouteAll: Bool? = nil
    var CorpDNS: Bool? = nil
    var AdvertiseRoutes: [String]? = nil
    var AmneziaWG: AmneziaWGPrefs? = nil
    let ExitNodeID: String?
    let ExitNodeAllowLANAccess: Bool?
    let ControlURL: String?
    let Hostname: String?
}

struct TaildropOutgoingFile: Codable, Identifiable {
    let transferID: String
    let PeerID: String?
    let Name: String
    let Started: String?
    let DeclaredSize: Int64
    let Sent: Int64
    let Finished: Bool
    let Succeeded: Bool

    var id: String { transferID }

    enum CodingKeys: String, CodingKey {
        case transferID = "ID"
        case PeerID
        case Name
        case Started
        case DeclaredSize
        case Sent
        case Finished
        case Succeeded
    }
}

struct TaildropIncomingFile: Codable, Identifiable {
    let Name: String
    let Started: String?
    let DeclaredSize: Int64?
    let Received: Int64?
    let PartialPath: String?
    let FinalPath: String?
    let Done: Bool?

    var id: String { FinalPath ?? PartialPath ?? Name }
    var isDone: Bool { Done == true }
}

// MARK: - ipn.MaskedPrefs

/// Maps to Go's ipn.MaskedPrefs — only set fields with corresponding *Set flags.
struct MaskedPrefs: Codable {
    var WantRunning: Bool?
    var WantRunningSet: Bool?
    var RouteAll: Bool?
    var RouteAllSet: Bool?
    var CorpDNS: Bool?
    var CorpDNSSet: Bool?
    var AdvertiseRoutes: [String]?
    var AdvertiseRoutesSet: Bool?
    var ExitNodeID: String?
    var ExitNodeIDSet: Bool?
    var ExitNodeAllowLANAccess: Bool?
    var ExitNodeAllowLANAccessSet: Bool?
    var ControlURL: String?
    var ControlURLSet: Bool?
    var AmneziaWG: AmneziaWGPrefs?
    var AmneziaWGSet: Bool?

    /// Helper to create a "set WantRunning" pref update.
    static func setWantRunning(_ value: Bool) -> MaskedPrefs {
        MaskedPrefs(WantRunning: value, WantRunningSet: true)
    }

    /// Helper to set a custom control server URL.
    static func setControlURL(_ url: String) -> MaskedPrefs {
        MaskedPrefs(ControlURL: url, ControlURLSet: true)
    }

    /// Helper to set local subnet routes advertised by this device.
    static func setAdvertiseRoutes(_ routes: [String]) -> MaskedPrefs {
        MaskedPrefs(AdvertiseRoutes: routes, AdvertiseRoutesSet: true)
    }

    /// Helper to set or clear the local AWG configuration.
    static func setAmneziaWG(_ config: AmneziaWGPrefs) -> MaskedPrefs {
        MaskedPrefs(AmneziaWG: config, AmneziaWGSet: true)
    }
}

// MARK: - ipn.LoginProfile

/// Maps to Go's ipn.LoginProfile (IpnLocal.LoginProfile).
struct LoginProfile: Codable, Identifiable {
    let ID: String
    let Name: String
    let Key: String?
    let UserProfile: UserProfile?
    let NetworkProfile: NetworkProfile?
    let LocalUserID: String?
    let ControlURL: String

    var id: String { self.ID }
    var name: String { Name }
    var controlURL: String { ControlURL }

    struct UserProfile: Codable {
        let ID: Int64?
        let LoginName: String?
        let DisplayName: String?
        let ProfilePicURL: String?
    }

    struct NetworkProfile: Codable {
        let MagicDNSSuffix: String?
        let DomainName: String?
    }
}

// MARK: - netmap.NetworkMap

struct NetworkMap: Codable {
    let SelfNode: NodeData?
    let Peers: [NodeData]?
    let Domain: String?
    let UserProfiles: [String: LoginProfile.UserProfile]?

    struct HostinfoData: Codable {
        let Hostname: String?
        let Location: LocationData?
        let sshHostKeys: [String]?

        enum CodingKeys: String, CodingKey {
            case Hostname
            case Location
            case sshHostKeys
        }

        init(Hostname: String?, Location: LocationData? = nil, sshHostKeys: [String]? = nil) {
            self.Hostname = Hostname
            self.Location = Location
            self.sshHostKeys = sshHostKeys
        }

        struct LocationData: Codable {
            let Country: String?
            let CountryCode: String?
            let City: String?
            let CityCode: String?
        }
    }

    struct NodeData: Codable, Identifiable {
        let ID: Int64?
        let StableID: String?
        let Key: String?
        let Name: String?
        let ComputedName: String?
        let Hostinfo: HostinfoData?
        let Addresses: [String]?
        let Online: Bool?
        let OS: String?
        let UserID: Int64?
        let KeyExpiry: String?
        let IsExitNode: Bool?
        let AllowedIPs: [String]?

        var id: String { StableID ?? "\(self.ID ?? 0)" }
    }
}

// MARK: - Health

struct HealthState: Codable {
    let Warnings: [String: UnhealthyState]?
}

struct UnhealthyState: Codable {
    let WarnableCode: String?
    let Severity: String? // "low", "medium", "high"
    let Title: String?
    let Text: String?
    let BrokenSince: String?
    let ImpactsConnectivity: Bool?
}

// MARK: - Amnezia WireGuard (AWG)

/// Maps to Go's AmneziaWGPrefs — AWG obfuscation parameters.
struct AmneziaWGPrefs: Codable {
    let JC: Int?    // Junk packet count
    let JMin: Int?  // Junk packet min size
    let JMax: Int?  // Junk packet max size
    let S1: Int?    // Init packet junk size
    let S2: Int?    // Response packet junk size
    let S3: Int?    // New junk size parameter
    let S4: Int?    // New junk size parameter
    let I1: String? // Init packet static content
    let I2: String? // Response packet static content
    let I3: String? // Reserved
    let I4: String? // Reserved
    let I5: String? // Reserved
    let H1: MagicHeaderRange?
    let H2: MagicHeaderRange?
    let H3: MagicHeaderRange?
    let H4: MagicHeaderRange?

    static let empty = AmneziaWGPrefs(
        JC: nil, JMin: nil, JMax: nil,
        S1: nil, S2: nil, S3: nil, S4: nil,
        I1: nil, I2: nil, I3: nil, I4: nil, I5: nil,
        H1: nil, H2: nil, H3: nil, H4: nil
    )

    /// Returns true if any AWG parameter has a non-default value.
    var hasNonDefaultValues: Bool {
        (JC != nil && JC != 0) ||
        (JMin != nil && JMin != 0) ||
        (JMax != nil && JMax != 0) ||
        (S1 != nil && S1 != 0) ||
        (S2 != nil && S2 != 0) ||
        (S3 != nil && S3 != 0) ||
        (S4 != nil && S4 != 0) ||
        (I1 != nil && !I1!.isEmpty) ||
        (I2 != nil && !I2!.isEmpty) ||
        (I3 != nil && !I3!.isEmpty) ||
        (I4 != nil && !I4!.isEmpty) ||
        (I5 != nil && !I5!.isEmpty) ||
        (H1?.hasValue == true) ||
        (H2?.hasValue == true) ||
        (H3?.hasValue == true) ||
        (H4?.hasValue == true)
    }

    /// Human-readable summary of non-default AWG parameters.
    var formattedString: String {
        var parts: [String] = []
        if let v = JC, v != 0 { parts.append("JC=\(v)") }
        if let v = JMin, v != 0 { parts.append("JMin=\(v)") }
        if let v = JMax, v != 0 { parts.append("JMax=\(v)") }
        if let v = S1, v != 0 { parts.append("S1=\(v)") }
        if let v = S2, v != 0 { parts.append("S2=\(v)") }
        if let v = S3, v != 0 { parts.append("S3=\(v)") }
        if let v = S4, v != 0 { parts.append("S4=\(v)") }
        if let v = I1, !v.isEmpty { parts.append("I1=\(v)") }
        if let v = I2, !v.isEmpty { parts.append("I2=\(v)") }
        if let v = I3, !v.isEmpty { parts.append("I3=\(v)") }
        if let v = I4, !v.isEmpty { parts.append("I4=\(v)") }
        if let v = I5, !v.isEmpty { parts.append("I5=\(v)") }
        for (label, h) in [("H1", H1), ("H2", H2), ("H3", H3), ("H4", H4)] {
            if let h = h, h.hasValue {
                if h.isFixedValue { parts.append("\(label)=\(h.min!)") }
                else { parts.append("\(label)=\(h.min!)-\(h.max!)") }
            }
        }
        return parts.isEmpty ? "Base Config" : parts.joined(separator: "\n")
    }
}

struct MagicHeaderRange: Codable {
    let min: Int64?
    let max: Int64?

    var hasValue: Bool { min != nil && max != nil && (min != 0 || max != 0) }
    var isFixedValue: Bool { min != nil && max != nil && min == max }
}

/// Result from the awg-sync-peers LocalAPI endpoint.
struct AwgPeerResult: Codable {
    let nodeKey: String
    let hostname: String
    let config: AmneziaWGPrefs?
    let error: String?

    var hasAwgConfig: Bool { config != nil && error == nil }
}

/// Request body for the awg-sync-apply LocalAPI endpoint.
struct AwgSyncApplyRequest: Codable {
    let nodeKey: String
    let timeout: Int

    init(nodeKey: String, timeout: Int = 30) {
        self.nodeKey = nodeKey
        self.timeout = Swift.min(Swift.max(timeout, 1), 60)
    }
}

/// Local prefs subset for AWG configuration check.
struct LocalPrefs: Codable {
    let AmneziaWG: AmneziaWGPrefs?
}

// MARK: - PeerNode (display model)

/// Flattened display model for UI, derived from NetworkMap.NodeData.
struct PeerNode: Identifiable {
    let id: String
    let nodeKey: String?
    let displayName: String
    let hostname: String
    let addresses: [String]
    let online: Bool
    let os: String?
    let isCurrentDevice: Bool
    let userDisplayName: String?
    let keyExpiry: String?
    let isExitNode: Bool
    let isMullvadNode: Bool
    let exitNodeDisplayName: String
    let allowedIPs: [String]
    let computedName: String?
    let hostinfoHostname: String?
    let sshHostKeys: [String]

    private static func displayName(from name: String?) -> String {
        guard let name = name, !name.isEmpty else { return "Unknown" }
        return name.hasSuffix(".") ? String(name.dropLast()) : name
    }

    /// Normalized hostname for AWG peer matching (lowercase, no domain suffix).
    var normalizedHostname: String {
        hostname.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .components(separatedBy: ".").first?
            .lowercased() ?? ""
    }

    var primaryIPv4Address: String? {
        addresses
            .compactMap { $0.components(separatedBy: "/").first }
            .first { $0.contains(".") }
    }

    var advertisesTailscaleSSH: Bool {
        !sshHostKeys.isEmpty
    }

    var sshTargetHost: String {
        if !hostname.isEmpty { return hostname }
        return primaryIPv4Address ?? addresses.first?.components(separatedBy: "/").first ?? ""
    }

    var sshCapabilityLabel: String {
        advertisesTailscaleSSH ? "Tailscale SSH advertised" : "Try port 22"
    }

    private static func isExitNode(_ node: NetworkMap.NodeData) -> Bool {
        if node.IsExitNode == true { return true }
        return (node.AllowedIPs ?? []).contains { route in
            let normalized = route.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized == "0.0.0.0/0" || normalized == "::/0"
        }
    }

    private static func isMullvadNode(_ node: NetworkMap.NodeData) -> Bool {
        if node.Hostinfo?.Location != nil { return true }
        return [node.Name, node.ComputedName].contains { name in
            name?.hasSuffix(".mullvad.ts.net") == true
        }
    }

    private static func exitNodeDisplayName(from node: NetworkMap.NodeData, fallback: String) -> String {
        guard isMullvadNode(node),
              let location = node.Hostinfo?.Location,
              let country = location.Country,
              let city = location.City else { return fallback }
        return "\(country): \(city)"
    }

    init(from node: NetworkMap.NodeData, isSelf: Bool, userProfile: LoginProfile.UserProfile?) {
        self.id = node.id
        self.nodeKey = node.Key
        self.displayName = Self.displayName(from: node.Name)
        self.hostname = node.Hostinfo?.Hostname ?? node.ComputedName ?? node.Name ?? ""
        self.addresses = node.Addresses ?? []
        self.online = node.Online ?? false
        self.os = node.OS
        self.isCurrentDevice = isSelf
        self.userDisplayName = userProfile?.DisplayName ?? userProfile?.LoginName
        self.keyExpiry = node.KeyExpiry
        self.allowedIPs = node.AllowedIPs ?? []
        self.computedName = node.ComputedName
        self.hostinfoHostname = node.Hostinfo?.Hostname
        self.sshHostKeys = node.Hostinfo?.sshHostKeys ?? []
        self.isExitNode = Self.isExitNode(node)
        self.isMullvadNode = Self.isMullvadNode(node)
        self.exitNodeDisplayName = Self.exitNodeDisplayName(from: node, fallback: self.displayName)
    }
}
