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

/// Maps to Go's AmneziaWGPrefs — AWG v2/v3 obfuscation parameters.
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

    // AWG v3 fields. Ranges use the same inclusive min/max wire format as H1-H4.
    let HeaderProtectionKey: String?
    let ContentPaddingAddition: MagicHeaderRange?
    let RekeyAfterTime: MagicHeaderRange?
    let RekeyTimeout: MagicHeaderRange?
    let RejectAfterTime: MagicHeaderRange?
    let KeepaliveTimeout: MagicHeaderRange?
    let MaxHandshakeAttempts: MagicHeaderRange?

    init(
        JC: Int? = nil,
        JMin: Int? = nil,
        JMax: Int? = nil,
        S1: Int? = nil,
        S2: Int? = nil,
        S3: Int? = nil,
        S4: Int? = nil,
        I1: String? = nil,
        I2: String? = nil,
        I3: String? = nil,
        I4: String? = nil,
        I5: String? = nil,
        H1: MagicHeaderRange? = nil,
        H2: MagicHeaderRange? = nil,
        H3: MagicHeaderRange? = nil,
        H4: MagicHeaderRange? = nil,
        HeaderProtectionKey: String? = nil,
        ContentPaddingAddition: MagicHeaderRange? = nil,
        RekeyAfterTime: MagicHeaderRange? = nil,
        RekeyTimeout: MagicHeaderRange? = nil,
        RejectAfterTime: MagicHeaderRange? = nil,
        KeepaliveTimeout: MagicHeaderRange? = nil,
        MaxHandshakeAttempts: MagicHeaderRange? = nil
    ) {
        self.JC = JC
        self.JMin = JMin
        self.JMax = JMax
        self.S1 = S1
        self.S2 = S2
        self.S3 = S3
        self.S4 = S4
        self.I1 = I1
        self.I2 = I2
        self.I3 = I3
        self.I4 = I4
        self.I5 = I5
        self.H1 = H1
        self.H2 = H2
        self.H3 = H3
        self.H4 = H4
        self.HeaderProtectionKey = HeaderProtectionKey
        self.ContentPaddingAddition = ContentPaddingAddition
        self.RekeyAfterTime = RekeyAfterTime
        self.RekeyTimeout = RekeyTimeout
        self.RejectAfterTime = RejectAfterTime
        self.KeepaliveTimeout = KeepaliveTimeout
        self.MaxHandshakeAttempts = MaxHandshakeAttempts
    }

    static let empty = AmneziaWGPrefs()
    private static let zeroHeaderProtectionKey = String(repeating: "0", count: 64)

    /// Accepts the Go field names, lower-case historical names, and wireguard-go's
    /// snake_case v3 names. Unknown fields are ignored only when at least one known
    /// AWG field is present, preventing an unrelated JSON object from clearing AWG.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: FlexibleAWGCodingKey.self)
        var recognizedField = false

        func decode<T: Decodable>(_ type: T.Type, named name: String) throws -> T? {
            let normalizedName = normalizedAWGJSONKey(name)
            guard let key = container.allKeys.first(where: {
                normalizedAWGJSONKey($0.stringValue) == normalizedName
            }) else {
                return nil
            }
            recognizedField = true
            return try container.decodeIfPresent(type, forKey: key)
        }

        JC = try decode(Int.self, named: "JC")
        JMin = try decode(Int.self, named: "JMin")
        JMax = try decode(Int.self, named: "JMax")
        S1 = try decode(Int.self, named: "S1")
        S2 = try decode(Int.self, named: "S2")
        S3 = try decode(Int.self, named: "S3")
        S4 = try decode(Int.self, named: "S4")
        I1 = try decode(String.self, named: "I1")
        I2 = try decode(String.self, named: "I2")
        I3 = try decode(String.self, named: "I3")
        I4 = try decode(String.self, named: "I4")
        I5 = try decode(String.self, named: "I5")
        H1 = try decode(MagicHeaderRange.self, named: "H1")
        H2 = try decode(MagicHeaderRange.self, named: "H2")
        H3 = try decode(MagicHeaderRange.self, named: "H3")
        H4 = try decode(MagicHeaderRange.self, named: "H4")
        HeaderProtectionKey = try decode(String.self, named: "HeaderProtectionKey")
        ContentPaddingAddition = try decode(MagicHeaderRange.self, named: "ContentPaddingAddition")
        RekeyAfterTime = try decode(MagicHeaderRange.self, named: "RekeyAfterTime")
        RekeyTimeout = try decode(MagicHeaderRange.self, named: "RekeyTimeout")
        RejectAfterTime = try decode(MagicHeaderRange.self, named: "RejectAfterTime")
        KeepaliveTimeout = try decode(MagicHeaderRange.self, named: "KeepaliveTimeout")
        MaxHandshakeAttempts = try decode(MagicHeaderRange.self, named: "MaxHandshakeAttempts")

        if !container.allKeys.isEmpty && !recognizedField {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "JSON contains no recognized AWG fields")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CanonicalAWGCodingKey.self)
        try container.encodeIfPresent(JC, forKey: .JC)
        try container.encodeIfPresent(JMin, forKey: .JMin)
        try container.encodeIfPresent(JMax, forKey: .JMax)
        try container.encodeIfPresent(S1, forKey: .S1)
        try container.encodeIfPresent(S2, forKey: .S2)
        try container.encodeIfPresent(S3, forKey: .S3)
        try container.encodeIfPresent(S4, forKey: .S4)
        try container.encodeIfPresent(I1, forKey: .I1)
        try container.encodeIfPresent(I2, forKey: .I2)
        try container.encodeIfPresent(I3, forKey: .I3)
        try container.encodeIfPresent(I4, forKey: .I4)
        try container.encodeIfPresent(I5, forKey: .I5)
        try container.encodeIfPresent(H1, forKey: .H1)
        try container.encodeIfPresent(H2, forKey: .H2)
        try container.encodeIfPresent(H3, forKey: .H3)
        try container.encodeIfPresent(H4, forKey: .H4)
        try container.encodeIfPresent(HeaderProtectionKey, forKey: .HeaderProtectionKey)
        try container.encodeIfPresent(ContentPaddingAddition, forKey: .ContentPaddingAddition)
        try container.encodeIfPresent(RekeyAfterTime, forKey: .RekeyAfterTime)
        try container.encodeIfPresent(RekeyTimeout, forKey: .RekeyTimeout)
        try container.encodeIfPresent(RejectAfterTime, forKey: .RejectAfterTime)
        try container.encodeIfPresent(KeepaliveTimeout, forKey: .KeepaliveTimeout)
        try container.encodeIfPresent(MaxHandshakeAttempts, forKey: .MaxHandshakeAttempts)
    }

    var isV3: Bool {
        (HeaderProtectionKey?.isEmpty == false && HeaderProtectionKey != Self.zeroHeaderProtectionKey) ||
        [
            ContentPaddingAddition, RekeyAfterTime, RekeyTimeout,
            RejectAfterTime, KeepaliveTimeout, MaxHandshakeAttempts,
        ].contains { $0?.hasValue == true }
    }

    var profileVersion: String {
        if isV3 { return "AWG v3" }
        return hasNonDefaultValues ? "AWG v2" : "Standard WireGuard"
    }

    /// Returns true if any AWG parameter has a non-default value.
    var hasNonDefaultValues: Bool {
        (JC != nil && JC != 0) ||
        (JMin != nil && JMin != 0) ||
        (JMax != nil && JMax != 0) ||
        (S1 != nil && S1 != 0) ||
        (S2 != nil && S2 != 0) ||
        (S3 != nil && S3 != 0) ||
        (S4 != nil && S4 != 0) ||
        [I1, I2, I3, I4, I5].contains { $0?.isEmpty == false } ||
        (H1?.hasValue == true) ||
        (H2?.hasValue == true) ||
        (H3?.hasValue == true) ||
        (H4?.hasValue == true) ||
        isV3
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
        if isV3 {
            if HeaderProtectionKey?.isEmpty == false,
               HeaderProtectionKey != Self.zeroHeaderProtectionKey {
                parts.append("HeaderProtectionKey=set")
            }
            for (label, value) in [
                ("ContentPaddingAddition", ContentPaddingAddition),
                ("RekeyAfterTime", RekeyAfterTime),
                ("RekeyTimeout", RekeyTimeout),
                ("RejectAfterTime", RejectAfterTime),
                ("KeepaliveTimeout", KeepaliveTimeout),
                ("MaxHandshakeAttempts", MaxHandshakeAttempts),
            ] where value?.hasValue == true {
                let range = value!
                parts.append(range.isFixedValue
                    ? "\(label)=\(range.min!)"
                    : "\(label)=\(range.min!)-\(range.max!)")
            }
        }
        return parts.isEmpty ? "Base Config" : parts.joined(separator: "\n")
    }
}

struct MagicHeaderRange: Codable {
    let min: Int64?
    let max: Int64?

    init(min: Int64?, max: Int64?) {
        self.min = min
        self.max = max
    }

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let value = try? single.decode(Int64.self) {
            try Self.validate(value)
            min = value
            max = value
            return
        }
        if let text = try? single.decode(String.self) {
            let components = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            guard let lower = Int64(components[0].trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw DecodingError.dataCorruptedError(in: single, debugDescription: "Invalid AWG range")
            }
            let upper: Int64
            if components.count == 2,
               let parsed = Int64(components[1].trimmingCharacters(in: .whitespacesAndNewlines)) {
                upper = parsed
            } else if components.count == 1 {
                upper = lower
            } else {
                throw DecodingError.dataCorruptedError(in: single, debugDescription: "Invalid AWG range")
            }
            try Self.validate(lower)
            try Self.validate(upper)
            guard lower <= upper else {
                throw DecodingError.dataCorruptedError(in: single, debugDescription: "AWG range min exceeds max")
            }
            min = lower
            max = upper
            return
        }

        let keyed = try decoder.container(keyedBy: FlexibleAWGCodingKey.self)
        func value(named name: String) throws -> Int64? {
            guard let key = keyed.allKeys.first(where: {
                normalizedAWGJSONKey($0.stringValue) == normalizedAWGJSONKey(name)
            }) else { return nil }
            return try keyed.decodeIfPresent(Int64.self, forKey: key)
        }
        let lower = try value(named: "min") ?? 0
        let upper = try value(named: "max") ?? 0
        try Self.validate(lower)
        try Self.validate(upper)
        guard lower <= upper else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "AWG range min exceeds max")
            )
        }
        min = lower
        max = upper
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: RangeCodingKey.self)
        try container.encode(min ?? 0, forKey: .min)
        try container.encode(max ?? 0, forKey: .max)
    }

    private static func validate(_ value: Int64) throws {
        guard (0...4_294_967_295).contains(value) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "AWG range must be 0-4294967295")
            )
        }
    }

    var hasValue: Bool { min != nil && max != nil && (min != 0 || max != 0) }
    var isFixedValue: Bool { min != nil && max != nil && min == max }

    private enum RangeCodingKey: String, CodingKey {
        case min, max
    }
}

private struct FlexibleAWGCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private enum CanonicalAWGCodingKey: String, CodingKey {
    case JC, JMin, JMax, S1, S2, S3, S4
    case I1, I2, I3, I4, I5
    case H1, H2, H3, H4
    case HeaderProtectionKey
    case ContentPaddingAddition
    case RekeyAfterTime
    case RekeyTimeout
    case RejectAfterTime
    case KeepaliveTimeout
    case MaxHandshakeAttempts
}

private func normalizedAWGJSONKey(_ value: String) -> String {
    value.lowercased().replacingOccurrences(of: "_", with: "")
}

/// Decodes either a bare AWG config or a prefs-shaped {"AmneziaWG": {...}}
/// wrapper without letting an unrelated object silently become an empty config.
func decodeAmneziaWGConfigJSON(_ data: Data) throws -> AmneziaWGPrefs {
    if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
       let wrapped = object.first(where: {
           normalizedAWGJSONKey($0.key) == normalizedAWGJSONKey("AmneziaWG")
       })?.value {
        if wrapped is NSNull {
            return .empty
        }
        let nested = try JSONSerialization.data(withJSONObject: wrapped)
        return try JSONDecoder().decode(AmneziaWGPrefs.self, from: nested)
    }
    return try JSONDecoder().decode(AmneziaWGPrefs.self, from: data)
}

/// Result from the awg-sync-peers LocalAPI endpoint.
struct AwgPeerResult: Codable {
    let nodeKey: String
    let hostname: String
    let config: AmneziaWGPrefs?
    let error: String?

    var lookupError: String? {
        guard let error = error?.trimmingCharacters(in: .whitespacesAndNewlines),
              !error.isEmpty else { return nil }
        return error
    }

    var hasAwgConfig: Bool { config?.hasNonDefaultValues == true && lookupError == nil }
    var isStandardWireGuard: Bool { config?.hasNonDefaultValues != true && lookupError == nil }
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
