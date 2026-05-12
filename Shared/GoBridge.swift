import Foundation

// MARK: - GoBridge: Swift ↔ Go Backend Bridge
//
// When the Libtailscale.xcframework is built (via ios/build_go.sh),
// the real Go backend is used. Otherwise, stubs are compiled so the
// project still builds for UI development.

#if canImport(Libtailscale)
import Libtailscale

enum GoBridge {
    /// The running Go Application instance, set after start().
    private(set) static var application: (any LibtailscaleApplicationProtocol)?
    /// Retain the AppContext so it's not deallocated while Go holds a reference.
    private static var appContext: GoAppContext?
    /// Retain packet callback while Go holds a reference.
    private static var packetCallback: GoPacketCallback?

    /// Start the Go backend. Must be called from the Extension process.
    ///
    /// - Parameters:
    ///   - dataDir: Writable directory for backend state.
    ///   - directFileRoot: Directory for Taildrop files (can be empty for MVP).
    ///   - hwAttestation: Whether hardware attestation is enabled.
    /// - Returns: true if the backend started successfully.
    static func start(dataDir: String, directFileRoot: String, hwAttestation: Bool, appLogin: Bool = false) -> Bool {
        let appCtx = GoAppContext()
        appContext = appCtx
        let app = appLogin
            ? LibtailscaleStartAppLogin(dataDir, directFileRoot, appCtx)
            : LibtailscaleStart(dataDir, directFileRoot, hwAttestation, appCtx)
        if app != nil {
            application = app
            return true
        }
        appContext = nil
        return false
    }

    /// Subscribe to ipn.Notify events from the Go backend.
    ///
    /// - Parameters:
    ///   - mask: Bitmask of NotifyWatchOpt values.
    ///   - callback: Called with JSON-serialized ipn.Notify on each event.
    /// - Returns: A handle to stop the subscription; nil if backend not started.
    static func watchNotifications(mask: Int, callback: @escaping (Data) -> Void) -> NotificationHandle? {
        guard let app = application else { return nil }
        let cb = GoNotificationCallback(callback)
        guard let manager = app.watchNotifications(mask, cb: cb) else { return nil }
        let handle = NotificationHandle()
        handle.goManager = manager
        handle.goCallback = cb
        return handle
    }

    /// Call a LocalAPI endpoint via the in-process bridge (net.Pipe pattern).
    ///
    /// - Parameters:
    ///   - timeoutMillis: Timeout in milliseconds.
    ///   - method: HTTP method (GET, POST, PATCH, etc.).
    ///   - endpoint: LocalAPI endpoint path (e.g. "/localapi/v0/status").
    ///   - body: Optional request body.
    /// - Returns: The LocalAPI response.
    static func callLocalAPI(
        timeoutMillis: Int,
        method: String,
        endpoint: String,
        body: Data? = nil,
        readBody: Bool = true
    ) async throws -> LocalAPIResponse {
        guard let app = application else { throw GoBridgeError.startFailed }

        let inputStream: (any LibtailscaleInputStreamProtocol)? = body.map { DataInputStream($0) }

        let goResp = try app.callLocalAPI(timeoutMillis, method: method, endpoint: endpoint, body: inputStream)

        let statusCode = goResp.statusCode()
        let bodyData = readBody ? try goResp.bodyBytes() : Data()

        return LocalAPIResponse(statusCode: statusCode, body: bodyData)
    }

    /// Register a packet callback for packets emitted by the Go TUN device.
    static func setPacketCallback(_ callback: @escaping (Data) -> Void) {
        guard let app = application else { return }
        let cb = GoPacketCallback(callback)
        app.setPacketCallback(cb)
        packetCallback = cb
    }

    /// Clear the packet callback registered with Go.
    static func clearPacketCallback() {
        application?.setPacketCallback(nil)
        packetCallback = nil
    }

    /// Inject a packet read from NEPacketTunnelFlow into the Go TUN device.
    static func injectInboundPacket(_ packet: Data) throws {
        guard let app = application else { throw GoBridgeError.startFailed }
        try app.injectInboundPacket(packet)
    }

    /// Stop watching notifications.
    static func stopNotifications(_ handle: NotificationHandle) {
        handle.goManager?.stop()
        handle.goManager = nil
        handle.goCallback = nil
    }

    /// Stop the Go backend and release retained bridge objects.
    static func stopBackend() {
        application?.stop()
        packetCallback = nil
        application = nil
        appContext = nil
    }
}

/// Implements Go's PacketCallback interface.
class GoPacketCallback: NSObject, LibtailscalePacketCallbackProtocol {
    private let handler: (Data) -> Void

    init(_ handler: @escaping (Data) -> Void) {
        self.handler = handler
    }

    func onPacket(_ packet: Data?) throws {
        guard let packet = packet else { return }
        handler(packet)
    }
}

#else
// MARK: - Stub Implementation (no Libtailscale.xcframework)

enum GoBridge {
    static var application: AnyObject? { nil }

    static func start(dataDir: String, directFileRoot: String, hwAttestation: Bool, appLogin: Bool = false) -> Bool {
        NSLog("[GoBridge] start() — stub, Go backend not built. Run ios/build_go.sh first.")
        return false
    }

    static func watchNotifications(mask: Int, callback: @escaping (Data) -> Void) -> NotificationHandle? {
        NSLog("[GoBridge] watchNotifications(mask: \(mask)) — stub")
        return nil
    }

    static func callLocalAPI(
        timeoutMillis: Int,
        method: String,
        endpoint: String,
        body: Data? = nil,
        readBody: Bool = true
    ) async throws -> LocalAPIResponse {
        NSLog("[GoBridge] callLocalAPI(\(method) \(endpoint)) — stub")
        throw GoBridgeError.notImplemented
    }

    static func setPacketCallback(_ callback: @escaping (Data) -> Void) {
        NSLog("[GoBridge] setPacketCallback — stub")
    }

    static func clearPacketCallback() {
        NSLog("[GoBridge] clearPacketCallback — stub")
    }

    static func injectInboundPacket(_ packet: Data) throws {
        NSLog("[GoBridge] injectInboundPacket(\(packet.count) bytes) — stub")
        throw GoBridgeError.notImplemented
    }

    static func stopNotifications(_ handle: NotificationHandle) {
        NSLog("[GoBridge] stopNotifications() — stub")
    }

    static func stopBackend() {
        NSLog("[GoBridge] stopBackend() — stub")
    }
}
#endif

// MARK: - Shared Types (always available)

/// Handle returned by watchNotifications, used to stop the subscription.
class NotificationHandle {
    #if canImport(Libtailscale)
    var goManager: (any LibtailscaleNotificationManagerProtocol)?
    var goCallback: AnyObject?
    #endif
}

/// Response from a LocalAPI call.
struct LocalAPIResponse {
    let statusCode: Int
    let body: Data
}

enum GoBridgeError: Error, LocalizedError {
    case notImplemented
    case startFailed
    case callFailed(String)

    var errorDescription: String? {
        switch self {
        case .notImplemented: return "Go backend not integrated"
        case .startFailed: return "Go backend failed to start"
        case .callFailed(let msg): return "LocalAPI call failed: \(msg)"
        }
    }
}

// MARK: - NotifyWatchOpt

/// Matches Go's ipn.NotifyWatchOpt constants.
struct NotifyWatchOpt {
    static let engineUpdates       = 1
    static let initialState        = 2
    static let prefs               = 4
    static let netmap              = 8
    static let noPrivateKey        = 16
    static let initialTailFSShares = 32
    static let initialOutgoingFiles = 64
    static let initialHealthState  = 128
    static let rateLimitNetmaps    = 256

    /// Default mask for the iOS notification subscription.
    static let defaultMask =
        netmap | prefs | initialState | initialHealthState | rateLimitNetmaps
}
