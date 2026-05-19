import Foundation

/// Typed wrapper around the raw LocalAPI bridge.
///
/// Views and other Swift callers should prefer the methods on this client
/// rather than building `/localapi/v0/...` URLs and decoding `IPCResponse`
/// bodies inline. The client is transport-agnostic and works equally well
/// against the in-app `AppLoginBackend` (used pre-tunnel for login) and the
/// `VPNManager` IPC bridge to the Packet Tunnel extension.
struct LocalAPIClient {
    typealias Executor = (_ method: String, _ endpoint: String, _ body: Data?, _ timeout: Int, _ readBody: Bool) async throws -> IPCResponse
    typealias FileExecutor = (_ method: String, _ endpoint: String, _ fileURL: URL, _ transferID: String?, _ timeout: Int, _ readBody: Bool) async throws -> IPCResponse

    private let execute: Executor
    private let executeFile: FileExecutor?

    init(_ execute: @escaping Executor, fileExecutor: FileExecutor? = nil) {
        self.execute = execute
        self.executeFile = fileExecutor
    }

    /// Client that routes calls through the active VPN extension.
    static func vpn(_ manager: VPNManager) -> LocalAPIClient {
        LocalAPIClient { method, endpoint, body, timeout, readBody in
            try await manager.callLocalAPI(method: method, endpoint: endpoint, body: body, timeout: timeout, readBody: readBody)
        } fileExecutor: { method, endpoint, fileURL, transferID, timeout, readBody in
            try await manager.callLocalAPIWithFileBody(method: method, endpoint: endpoint, fileURL: fileURL, transferID: transferID, timeout: timeout, readBody: readBody)
        }
    }

    #if !SHARE_EXTENSION
    /// Client that routes calls through the in-app login backend (pre-tunnel).
    static func login(_ backend: AppLoginBackend) -> LocalAPIClient {
        LocalAPIClient { method, endpoint, body, timeout, readBody in
            try await backend.callLocalAPI(method: method, endpoint: endpoint, body: body, timeout: timeout, readBody: readBody)
        }
    }
    #endif

    // MARK: - Raw transport

    @discardableResult
    func raw(
        method: String,
        endpoint: String,
        body: Data? = nil,
        timeout: Int = 30000,
        readBody: Bool = true
    ) async throws -> IPCResponse {
        try await execute(method, endpoint, body, timeout, readBody)
    }

    // MARK: - Profiles

    func listProfiles() async throws -> [LoginProfile] {
        let endpoint = "/localapi/v0/profiles/"
        let resp = try await execute("GET", endpoint, nil, 30000, true)
        return try resp.decodedBody([LoginProfile].self, endpoint: endpoint)
    }

    func currentProfile() async throws -> LoginProfile {
        let endpoint = "/localapi/v0/profiles/current"
        let resp = try await execute("GET", endpoint, nil, 30000, true)
        return try resp.decodedBody(LoginProfile.self, endpoint: endpoint)
    }

    func switchProfile(id: String) async throws {
        let endpoint = "/localapi/v0/profiles/\(id)"
        let resp = try await execute("POST", endpoint, nil, 30000, true)
        try resp.requireSuccess(endpoint: endpoint)
    }

    func deleteProfile(id: String) async throws {
        let endpoint = "/localapi/v0/profiles/\(id)"
        let resp = try await execute("DELETE", endpoint, nil, 30000, true)
        try resp.requireSuccess(endpoint: endpoint)
    }

    func newProfile() async throws {
        let endpoint = "/localapi/v0/profiles/new"
        let resp = try await execute("POST", endpoint, nil, 30000, true)
        try resp.requireSuccess(endpoint: endpoint)
    }

    // MARK: - Prefs / login

    func patchPrefs(_ prefs: MaskedPrefs, timeout: Int = 30000) async throws {
        let endpoint = "/localapi/v0/prefs"
        let body = try JSONEncoder().encode(prefs)
        let resp = try await execute("PATCH", endpoint, body, timeout, true)
        try resp.requireSuccess(endpoint: endpoint)
    }

    func patchPrefsReturningBody(_ prefs: MaskedPrefs, timeout: Int = 30000) async throws -> Data {
        let endpoint = "/localapi/v0/prefs"
        let body = try JSONEncoder().encode(prefs)
        let resp = try await execute("PATCH", endpoint, body, timeout, true)
        return try resp.bodyData(endpoint: endpoint)
    }

    func setWantRunning(_ wantRunning: Bool, timeout: Int = 30000) async throws {
        try await patchPrefs(.setWantRunning(wantRunning), timeout: timeout)
    }

    func setUseSubnetRoutes(_ enabled: Bool, timeout: Int = 30000) async throws {
        var prefs = MaskedPrefs()
        prefs.RouteAll = enabled
        prefs.RouteAllSet = true
        try await patchPrefs(prefs, timeout: timeout)
    }

    func setUseTailscaleDNS(_ enabled: Bool, timeout: Int = 30000) async throws {
        var prefs = MaskedPrefs()
        prefs.CorpDNS = enabled
        prefs.CorpDNSSet = true
        try await patchPrefs(prefs, timeout: timeout)
    }

    func setAdvertiseRoutes(_ routes: [String], timeout: Int = 30000) async throws {
        try await patchPrefs(.setAdvertiseRoutes(routes), timeout: timeout)
    }

    func setExitNode(id: String, timeout: Int = 30000) async throws {
        var prefs = MaskedPrefs()
        prefs.ExitNodeID = id
        prefs.ExitNodeIDSet = true
        prefs.RouteAll = !id.isEmpty
        prefs.RouteAllSet = true
        try await patchPrefs(prefs, timeout: timeout)
    }

    func setExitNodeAllowLANAccess(_ allow: Bool, timeout: Int = 30000) async throws {
        var prefs = MaskedPrefs()
        prefs.ExitNodeAllowLANAccess = allow
        prefs.ExitNodeAllowLANAccessSet = true
        try await patchPrefs(prefs, timeout: timeout)
    }

    func ipnPrefs(timeout: Int = 30000) async throws -> IpnPrefs {
        try await prefs(IpnPrefs.self, timeout: timeout)
    }

    func localPrefs(timeout: Int = 30000) async throws -> LocalPrefs {
        try await prefs(LocalPrefs.self, timeout: timeout)
    }

    func prefs<T: Decodable>(_ type: T.Type, timeout: Int = 30000) async throws -> T {
        let endpoint = "/localapi/v0/prefs"
        let resp = try await execute("GET", endpoint, nil, timeout, true)
        return try resp.decodedBody(type, endpoint: endpoint)
    }

    func login(authKey: String) async throws {
        let endpoint = "/localapi/v0/login"
        let body = try JSONEncoder().encode(["authKey": authKey])
        let resp = try await execute("POST", endpoint, body, 30000, true)
        try resp.requireSuccess(endpoint: endpoint)
    }

    func start(updatePrefsData: Data) async throws {
        let endpoint = "/localapi/v0/start"
        let updatePrefs = try JSONSerialization.jsonObject(with: updatePrefsData)
        let body = try JSONSerialization.data(withJSONObject: ["UpdatePrefs": updatePrefs])
        let resp = try await execute("POST", endpoint, body, 30000, false)
        try resp.requireSuccess(endpoint: endpoint)
    }

    func logout() async throws {
        let endpoint = "/localapi/v0/logout"
        let resp = try await execute("POST", endpoint, nil, 30000, false)
        try resp.requireSuccess(endpoint: endpoint)
    }

    // MARK: - Status / diagnostics

    func statusResponse(timeout: Int = 30000) async throws -> IPCResponse {
        let endpoint = "/localapi/v0/status"
        return try await execute("GET", endpoint, nil, timeout, true)
    }

    func statusJSON(timeout: Int = 30000) async throws -> Data {
        let endpoint = "/localapi/v0/status"
        let resp = try await execute("GET", endpoint, nil, timeout, true)
        return try resp.bodyData(endpoint: endpoint)
    }

    func status(timeout: Int = 30000) async throws -> StatusResponse {
        let endpoint = "/localapi/v0/status"
        let resp = try await execute("GET", endpoint, nil, timeout, true)
        return try resp.decodedBody(StatusResponse.self, endpoint: endpoint)
    }

    func statusObject(timeout: Int = 30000) async throws -> [String: Any] {
        let data = try await statusJSON(timeout: timeout)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LocalAPIError.decoding(endpoint: "/localapi/v0/status", underlying: LocalAPIClientError.invalidJSONObject, bodyPreview: nil)
        }
        return json
    }

    func bugReportLogs() async throws -> String {
        let endpoint = "/localapi/v0/bugreport"
        let resp = try await execute("GET", endpoint, nil, 30000, true)
        let data = try resp.bodyData(endpoint: endpoint)
        return String(data: data, encoding: .utf8) ?? ""
    }

    func ping(ip: String, type: String = "disco", timeout: Int = 10000) async throws -> PingAPIResponse {
        let endpoint = "/localapi/v0/ping?ip=\(ip)&type=\(type)"
        let resp = try await execute("POST", endpoint, nil, timeout, true)
        return try resp.decodedBody(PingAPIResponse.self, endpoint: endpoint)
    }

    // MARK: - DNS

    func dnsConfig() async throws -> DNSConfigResponse {
        let endpoint = "/localapi/v0/dns-config"
        let resp = try await execute("GET", endpoint, nil, 30000, true)
        return try resp.decodedBody(DNSConfigResponse.self, endpoint: endpoint)
    }

    // MARK: - Taildrop

    /// Result of listing waiting Taildrop files.
    enum TaildropListResult {
        case unavailable      // 404: feature not present in this build
        case files([TaildropFileResponse])
    }

    func listTaildropFiles() async throws -> TaildropListResult {
        let endpoint = "/localapi/v0/files/"
        let resp = try await execute("GET", endpoint, nil, 30000, true)
        if resp.statusCode == 404 {
            return .unavailable
        }
        if resp.statusCode == 204 || (resp.statusCode == 200 && resp.bodyBase64 == nil) {
            return .files([])
        }
        let files = try resp.decodedBody([TaildropFileResponse]?.self, endpoint: endpoint)
        return .files(files ?? [])
    }

    func taildropTargets() async throws -> [TaildropFileTargetResponse] {
        let endpoint = "/localapi/v0/file-targets"
        let resp = try await execute("GET", endpoint, nil, 30000, true)
        if resp.statusCode == 404 {
            return []
        }
        return try resp.decodedBody([TaildropFileTargetResponse].self, endpoint: endpoint)
    }

    func deleteTaildropFile(name: String) async throws {
        let escaped = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let endpoint = "/localapi/v0/files/\(escaped)"
        let resp = try await execute("DELETE", endpoint, nil, 30000, true)
        try resp.requireSuccess(endpoint: endpoint)
    }

    @discardableResult
    func putTaildropFile(peerID: String, fileURL: URL) async throws -> String {
        let transferID = UUID().uuidString
        guard let executeFile else {
            throw LocalAPIError.backend("Taildrop file transport is unavailable")
        }

        let endpoint = "/localapi/v0/file-put/\(peerID)"
        let resp = try await executeFile("POST", endpoint, fileURL, transferID, 600000, true)
        try resp.requireSuccess(endpoint: endpoint)
        return transferID
    }

    // MARK: - AWG sync

    func awgPeers() async throws -> [AwgPeerResult] {
        let endpoint = "/localapi/v0/awg-sync-peers"
        let resp = try await execute("GET", endpoint, nil, 30000, true)
        return try resp.decodedBody([AwgPeerResult].self, endpoint: endpoint)
    }

    func awgSyncApply(_ request: AwgSyncApplyRequest) async throws -> AmneziaWGPrefs {
        let endpoint = "/localapi/v0/awg-sync-apply"
        let body = try JSONEncoder().encode(request)
        let timeout = max(30000, (request.timeout + 5) * 1000)
        let resp = try await execute("POST", endpoint, body, timeout, true)
        return try resp.decodedBody(AmneziaWGPrefs.self, endpoint: endpoint)
    }

    // MARK: - Tailnet Lock

    /// Result of the Tailnet-Lock status query.
    enum TKAStatusResult {
        case unavailable      // 404: TKA not compiled in or not initialized
        case status(TKAStatusResponse)
    }

    func tkaStatus() async throws -> TKAStatusResult {
        let endpoint = "/localapi/v0/tka/status"
        let resp = try await execute("GET", endpoint, nil, 30000, true)
        if resp.statusCode == 404 {
            return .unavailable
        }
        let status = try resp.decodedBody(TKAStatusResponse.self, endpoint: endpoint)
        return .status(status)
    }

    func tkaVerifyDeeplink(url: String) async throws -> TKADeeplinkValidationResponse {
        let endpoint = "/localapi/v0/tka/verify-deeplink"
        let body = try JSONEncoder().encode(["URL": url])
        let resp = try await execute("POST", endpoint, body, 30000, true)
        return try resp.decodedBody(TKADeeplinkValidationResponse.self, endpoint: endpoint)
    }

    func tkaSign(nodeKey: String, rotationPublic: String?) async throws {
        let endpoint = "/localapi/v0/tka/sign"
        let request = TKASignRequest(
            NodeKey: nodeKey,
            RotationPublic: rotationPublic.flatMap { $0.isEmpty ? nil : Data($0.utf8) }
        )
        let body = try JSONEncoder().encode(request)
        let resp = try await execute("POST", endpoint, body, 30000, true)
        try resp.requireSuccess(endpoint: endpoint)
    }

    func tkaSign(url: String) async throws -> TKADeeplinkValidationResponse {
        let validation = try await tkaVerifyDeeplink(url: url)
        guard validation.IsValid == true else {
            throw LocalAPIError.backend(validation.Error ?? "Invalid Tailnet Lock signing link")
        }
        guard let nodeKey = validation.NodeKey, !nodeKey.isEmpty else {
            throw LocalAPIError.backend("Tailnet Lock signing link did not include a node key")
        }
        try await tkaSign(nodeKey: nodeKey, rotationPublic: validation.TLPub)
        return validation
    }
}

enum LocalAPIClientError: Error {
    case invalidJSONObject
}

// MARK: - LocalAPI wire types

/// Response from `POST /localapi/v0/ping`.
struct PingAPIResponse: Decodable {
    let Err: String?
    let LatencySeconds: Double?
}

/// Response from `GET /localapi/v0/status`.
struct StatusResponse: Codable {
    let BackendState: String?
    let Peer: [String: PeerStatus]?

    struct PeerStatus: Codable {
        let HostName: String?
        let DNSName: String?
        let TailscaleIPs: [String]?
        let PrimaryRoutes: [String]?
        let AllowedIPs: [String]?
        let Online: Bool?
        let Active: Bool?
        let ExitNode: Bool?
        let ExitNodeOption: Bool?
        let OS: String?

        var displayName: String {
            if let hostName = HostName, !hostName.isEmpty { return hostName }
            if let dnsName = DNSName, !dnsName.isEmpty {
                return dnsName.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            }
            return "Unknown"
        }
    }
}

/// Response from `GET /localapi/v0/dns-config`.
struct DNSConfigResponse: Codable {
    let Resolvers: [ResolverEntry]?
    let FallbackResolvers: [ResolverEntry]?
    let Routes: [String: [ResolverEntry]?]?
    let Domains: [String]?
    let Proxied: Bool?
    let Nameservers: [String]?
    let CertDomains: [String]?
    let ExtraRecords: [DNSRecord]?
    let ExitNodeFilteredSet: [String]?

    struct ResolverEntry: Codable {
        let Addr: String?
    }

    struct DNSRecord: Codable {
        let Name: String?
        let recordType: String?
        let Value: String?

        enum CodingKeys: String, CodingKey {
            case Name
            case recordType = "Type"
            case Value
        }
    }
}

/// Response from `GET /localapi/v0/tka/status`.
struct TKAStatusResponse: Codable {
    let Enabled: Bool?
    let Head: String?
    let PublicKey: String?
    let NodeKey: String?
    let NodeKeySigned: Bool?
    let IsSigningKey: Bool?
    let TrustedKeys: [String]?
}

/// Response from `POST /localapi/v0/tka/verify-deeplink`.
struct TKADeeplinkValidationResponse: Codable {
    let IsValid: Bool?
    let Error: String?
    let Version: UInt8?
    let NodeKey: String?
    let TLPub: String?
    let DeviceName: String?
    let OSName: String?
    let EmailAddress: String?
}

private struct TKASignRequest: Codable {
    let NodeKey: String
    let RotationPublic: Data?
}

/// Response from `GET /localapi/v0/files`.
struct TaildropFileResponse: Codable {
    let Name: String
    let Size: Int64
    let Sender: String?
    let Started: String?
}

/// Response element from `GET /localapi/v0/file-targets`.
struct TaildropFileTargetResponse: Codable {
    let Node: NetworkMap.NodeData
    let PeerAPIURL: String

    var peer: PeerNode {
        PeerNode(from: Node, isSelf: false, userProfile: nil)
    }
}
