import Foundation

/// MDM (Mobile Device Management) settings handler.
/// Reads managed app configuration from Apple's configuration profile.
///
/// Supported keys match Tailscale's official MDM policy keys:
/// https://tailscale.com/kb/1258/device-management
@MainActor
class MDMSettings: ObservableObject {
    
    static let shared = MDMSettings()
    
    // MARK: - Published Properties
    
    @Published var isManaged: Bool = false
    @Published var organizationName: String?
    @Published var managedByCaption: String?
    @Published var managedByURL: String?
    
    // MARK: - Policy Values
    
    /// Force VPN to always be enabled
    var forceEnabled: Bool? { getBool("ForceEnabled") }
    
    /// Force specific exit node
    var exitNodeID: String? { getString("ExitNodeID") }
    
    /// Custom control plane URL (for Headscale etc.)
    var loginURL: String? { getString("LoginURL") }
    
    /// Auth key for automatic registration
    var authKey: String? { getString("AuthKey") }
    
    /// Required tailnet name
    var tailnet: String? { getString("Tailnet") }
    
    /// Key expiration notice period
    var keyExpirationNotice: String? { getString("KeyExpirationNotice") }
    
    /// Allow incoming connections policy
    var allowIncomingConnections: TriState { getTriState("AllowIncomingConnections") }
    
    /// Allow LAN access when using exit node
    var exitNodeAllowLANAccess: TriState { getTriState("ExitNodeAllowLANAccess") }
    
    /// Use Tailscale DNS settings
    var useTailscaleDNSSettings: TriState { getTriState("UseTailscaleDNSSettings") }
    
    /// Use Tailscale subnet routes
    var useTailscaleSubnets: TriState { getTriState("UseTailscaleSubnets") }
    
    /// Hidden network devices (filtered from UI)
    var hiddenNetworkDevices: [String]? { getStringArray("HiddenNetworkDevices") }
    
    /// Show/hide exit nodes picker
    var exitNodesPicker: ShowHide { getShowHide("ExitNodesPicker") }
    
    /// Show/hide Tailnet Lock management
    var manageTailnetLock: ShowHide { getShowHide("ManageTailnetLock") }
    
    /// Forced hostname
    var hostname: String? { getString("Hostname") }
    
    /// Require hardware attestation
    var hardwareAttestation: Bool? { getBool("HardwareAttestation") }
    
    /// Device serial number (for inventory)
    var deviceSerialNumber: String? { getString("DeviceSerialNumber") }
    
    // MARK: - Initialization
    
    private let managedDefaults = UserDefaults(suiteName: "com.apple.configuration.managed")
    
    init() {
        loadSettings()
        
        // Observe MDM config changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(managedConfigChanged),
            name: UserDefaults.didChangeNotification,
            object: managedDefaults
        )
    }
    
    // MARK: - Loading
    
    func loadSettings() {
        guard let defaults = managedDefaults else {
            isManaged = false
            return
        }
        
        // Check if any managed settings exist
        let dict = defaults.dictionaryRepresentation()
        isManaged = !dict.isEmpty
        
        // Load organization info
        organizationName = getString("ManagedByOrganizationName")
        managedByCaption = getString("ManagedByCaption")
        managedByURL = getString("ManagedByURL")
    }
    
    @objc private func managedConfigChanged() {
        loadSettings()
    }
    
    // MARK: - Helpers
    
    private func getString(_ key: String) -> String? {
        managedDefaults?.string(forKey: key)
    }
    
    private func getBool(_ key: String) -> Bool? {
        guard managedDefaults?.object(forKey: key) != nil else { return nil }
        return managedDefaults?.bool(forKey: key)
    }
    
    private func getStringArray(_ key: String) -> [String]? {
        managedDefaults?.array(forKey: key) as? [String]
    }
    
    private func getTriState(_ key: String) -> TriState {
        guard let value = getString(key) else { return .unset }
        switch value.lowercased() {
        case "always": return .always
        case "never": return .never
        default: return .unset
        }
    }
    
    private func getShowHide(_ key: String) -> ShowHide {
        guard let value = getString(key) else { return .show }
        switch value.lowercased() {
        case "hide": return .hide
        default: return .show
        }
    }
    
    // MARK: - Policy Enforcement
    
    /// Check if a UI element should be hidden based on MDM policy
    func shouldHide(_ element: MDMHiddenElement) -> Bool {
        switch element {
        case .exitNodePicker:
            return exitNodesPicker == .hide
        case .tailnetLock:
            return manageTailnetLock == .hide
        case .signOut:
            return forceEnabled == true
        case .disconnect:
            return forceEnabled == true
        }
    }
    
    /// Check if a setting is locked by MDM
    func isLocked(_ setting: MDMLockedSetting) -> Bool {
        switch setting {
        case .exitNode:
            return exitNodeID != nil
        case .controlURL:
            return loginURL != nil
        case .allowLAN:
            return exitNodeAllowLANAccess != .unset
        case .dns:
            return useTailscaleDNSSettings != .unset
        case .subnets:
            return useTailscaleSubnets != .unset
        }
    }
    
    /// Get locked value for a setting (if locked)
    func lockedValue<T>(_ setting: MDMLockedSetting) -> T? {
        switch setting {
        case .exitNode:
            return exitNodeID as? T
        case .controlURL:
            return loginURL as? T
        case .allowLAN:
            return (exitNodeAllowLANAccess == .always) as? T
        case .dns:
            return (useTailscaleDNSSettings == .always) as? T
        case .subnets:
            return (useTailscaleSubnets == .always) as? T
        }
    }
}

// MARK: - Types

/// Tri-state value for MDM policies
enum TriState: String {
    case unset = "unset"
    case always = "always"
    case never = "never"
}

/// Show/hide state for UI elements
enum ShowHide: String {
    case show = "show"
    case hide = "hide"
}

/// UI elements that can be hidden by MDM
enum MDMHiddenElement {
    case exitNodePicker
    case tailnetLock
    case signOut
    case disconnect
}

/// Settings that can be locked by MDM
enum MDMLockedSetting {
    case exitNode
    case controlURL
    case allowLAN
    case dns
    case subnets
}
