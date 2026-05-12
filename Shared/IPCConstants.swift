import Foundation

/// Shared App Group constants for IPC between main App and Packet Tunnel Extension.
///
/// Main App and Extension run in separate processes.
/// Process-local global channels cannot be shared across the iOS app and extension.
/// Instead, use these shared mechanisms:
///
/// - App Group UserDefaults: small state sync (connection status, profile)
/// - App Group file container: large data (logs, NetMap cache)
/// - NETunnelProviderSession.sendProviderMessage: request/response IPC
/// - Darwin Notifications: lightweight cross-process "state changed" signals
/// - Keychain (shared access group): encrypted state persistence
enum IPCConstants {
    static let appGroupID = "group.com.tailscale.ipn.ios"
    static let keychainGroupID = "com.tailscale.ipn.ios.shared"

    // MARK: - App Group UserDefaults keys (Extension writes, App reads)

    /// Current ipn.State as Int raw value (see IpnState enum).
    static let keyIPNState = "ipn_state"
    /// Current Prefs as JSON string.
    static let keyPrefsJSON = "prefs_json"
    /// Current NetMap as JSON string.
    static let keyNetMapJSON = "netmap_json"
    /// Login URL (BrowseToURL from Notify). Nil when not logging in.
    static let keyBrowseToURL = "browse_to_url"
    /// Set to true when LoginFinished is received; App clears after reading.
    static let keyLoginFinished = "login_finished"
    /// Health state as JSON string.
    static let keyHealthJSON = "health_json"
    /// Self node data as JSON string.
    static let keySelfNodeJSON = "self_node_json"
    /// Last error from the backend.
    static let keyLastError = "last_error"
    /// Current profile ID.
    static let keyCurrentProfileID = "current_profile_id"

    // MARK: - Darwin Notification names

    /// Posted by Extension when ipn state/prefs/netmap changes.
    /// App should re-read shared UserDefaults when receiving this.
    static let notifyStateChanged = "com.tailscale.ipn.ios.state-changed" as CFString
}

// MARK: - Shared Defaults

/// Shared UserDefaults backed by App Group. Use instead of .standard for cross-process data.
let sharedDefaults = UserDefaults(suiteName: IPCConstants.appGroupID)

/// Shared container URL for file-based data exchange.
let sharedContainerURL: URL? = FileManager.default.containerURL(
    forSecurityApplicationGroupIdentifier: IPCConstants.appGroupID
)

// MARK: - IPC Messages (App ↔ Extension via sendProviderMessage)

/// Request sent from App to Extension via NETunnelProviderSession.sendProviderMessage.
struct IPCRequest: Codable {
    enum Command: String, Codable {
        case callLocalAPI
        case startLoginInteractive
    }

    let command: Command

    // For callLocalAPI:
    var method: String?
    var endpoint: String?
    var bodyBase64: String?  // Base64-encoded request body
    var timeoutMillis: Int?
}

/// Response sent from Extension to App via sendProviderMessage completion handler.
struct IPCResponse: Codable {
    let statusCode: Int
    var bodyBase64: String?  // Base64-encoded response body
    var error: String?

    static func success(statusCode: Int, body: Data? = nil) -> IPCResponse {
        IPCResponse(
            statusCode: statusCode,
            bodyBase64: body?.base64EncodedString()
        )
    }

    static func failure(_ message: String) -> IPCResponse {
        IPCResponse(statusCode: 500, error: message)
    }
}

// MARK: - Darwin Notification Helpers

/// Post a Darwin notification (cross-process, no payload).
func postDarwinNotification(_ name: CFString) {
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFNotificationName(name),
        nil, nil, true
    )
}

/// Observe a Darwin notification. The callback is always dispatched to the main queue.
/// The observer persists for the lifetime of the process (appropriate for app-wide singletons).
func observeDarwinNotification(_ name: CFString, callback: @escaping () -> Void) {
    let center = CFNotificationCenterGetDarwinNotifyCenter()
    // Store callback via a Box so we can pass it through the C callback.
    // passRetained intentionally: observer lives for the process lifetime.
    let box = DarwinCallbackBox(callback)
    let ptr = Unmanaged.passRetained(box).toOpaque()

    CFNotificationCenterAddObserver(
        center,
        ptr,
        { (_, observer, _, _, _) in
            guard let observer = observer else { return }
            let box = Unmanaged<DarwinCallbackBox>.fromOpaque(observer).takeUnretainedValue()
            DispatchQueue.main.async {
                box.callback()
            }
        },
        name,
        nil,
        .deliverImmediately
    )
}

private class DarwinCallbackBox {
    let callback: () -> Void
    init(_ callback: @escaping () -> Void) { self.callback = callback }
}
