import SwiftUI

/// MDM Management info view.
/// Shows organization management status and policies.
struct MDMInfoView: View {
    @StateObject private var mdm = MDMSettings.shared
    
    var body: some View {
        List {
            if mdm.isManaged {
                // Organization info
                Section {
                    if let orgName = mdm.organizationName {
                        HStack {
                            Image(systemName: "building.2")
                                .foregroundColor(.accentColor)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Managed by")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(orgName)
                                    .font(.headline)
                            }
                        }
                    }
                    
                    if let caption = mdm.managedByCaption {
                        Text(caption)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    if let urlString = mdm.managedByURL, let url = URL(string: urlString) {
                        Link(destination: url) {
                            HStack {
                                Image(systemName: "link")
                                Text("Support")
                                Spacer()
                                Image(systemName: "arrow.up.right.square")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Organization")
                }
                
                // Applied policies
                Section {
                    if let forceEnabled = mdm.forceEnabled {
                        PolicyRow(
                            name: "Force VPN Enabled",
                            value: forceEnabled ? "Yes" : "No",
                            icon: "power"
                        )
                    }
                    
                    if let exitNode = mdm.exitNodeID {
                        PolicyRow(
                            name: "Exit Node",
                            value: exitNode,
                            icon: "globe"
                        )
                    }
                    
                    if let loginURL = mdm.loginURL {
                        PolicyRow(
                            name: "Control Server",
                            value: loginURL,
                            icon: "server.rack"
                        )
                    }
                    
                    if let tailnet = mdm.tailnet {
                        PolicyRow(
                            name: "Required Tailnet",
                            value: tailnet,
                            icon: "network"
                        )
                    }
                    
                    if mdm.allowIncomingConnections != .unset {
                        PolicyRow(
                            name: "Incoming Connections",
                            value: mdm.allowIncomingConnections == .always ? "Allowed" : "Blocked",
                            icon: "arrow.down.circle"
                        )
                    }
                    
                    if mdm.exitNodeAllowLANAccess != .unset {
                        PolicyRow(
                            name: "LAN Access",
                            value: mdm.exitNodeAllowLANAccess == .always ? "Allowed" : "Blocked",
                            icon: "wifi"
                        )
                    }
                    
                    if mdm.useTailscaleDNSSettings != .unset {
                        PolicyRow(
                            name: "Tailscale DNS",
                            value: mdm.useTailscaleDNSSettings == .always ? "Enabled" : "Disabled",
                            icon: "network.badge.shield.half.filled"
                        )
                    }
                    
                    if mdm.exitNodesPicker == .hide {
                        PolicyRow(
                            name: "Exit Node Picker",
                            value: "Hidden",
                            icon: "eye.slash"
                        )
                    }
                    
                    if mdm.manageTailnetLock == .hide {
                        PolicyRow(
                            name: "Tailnet Lock",
                            value: "Hidden",
                            icon: "lock.slash"
                        )
                    }
                    
                    if mdm.hardwareAttestation == true {
                        PolicyRow(
                            name: "Hardware Attestation",
                            value: "Required",
                            icon: "cpu"
                        )
                    }
                } header: {
                    Text("Applied Policies")
                } footer: {
                    Text("These settings are managed by your organization and cannot be changed.")
                }
            } else {
                // Not managed
                Section {
                    VStack(spacing: 16) {
                        Image(systemName: "person.badge.shield.checkmark")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        
                        Text("Not Managed")
                            .font(.headline)
                        
                        Text("This device is not enrolled in Mobile Device Management (MDM). All settings can be configured freely.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            }
            
            // Info section
            Section {
                Link(destination: URL(string: "https://tailscale.com/kb/1258/device-management")!) {
                    HStack {
                        Image(systemName: "questionmark.circle")
                            .foregroundColor(.blue)
                        Text("Learn about MDM")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Device Management")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Row displaying a single MDM policy.
struct PolicyRow: View {
    let name: String
    let value: String
    let icon: String
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
                .frame(width: 24)
            
            Text(name)
            
            Spacer()
            
            Text(value)
                .foregroundColor(.secondary)
                .font(.caption)
                .lineLimit(1)
        }
    }
}

#Preview {
    NavigationView {
        MDMInfoView()
    }
}
