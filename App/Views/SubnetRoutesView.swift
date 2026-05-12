import SwiftUI

/// Subnet Routes management view.
/// Displays routes advertised by other devices on the network.
/// Note: iOS cannot advertise subnet routes, only use routes from other devices.
struct SubnetRoutesView: View {
    @EnvironmentObject var appState: AppState
    @State private var routes: [SubnetRoute] = []
    @State private var isLoading: Bool = true
    @State private var error: String?
    
    var body: some View {
        List {
            if isLoading {
                Section {
                    HStack {
                        ProgressView()
                            .padding(.trailing, 8)
                        Text("Loading subnet routes...")
                            .foregroundColor(.secondary)
                    }
                }
            } else if let error = error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundColor(.red)
                }
            } else if routes.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No subnet routes available")
                            .foregroundColor(.secondary)
                        Text("Subnet routes allow you to access networks behind other Tailscale devices. Routes must be advertised by another device and approved by an admin.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 8)
                }
            } else {
                // Active routes
                let activeRoutes = routes.filter { $0.approved && $0.enabled }
                if !activeRoutes.isEmpty {
                    Section {
                        ForEach(activeRoutes) { route in
                            SubnetRouteRow(route: route)
                        }
                    } header: {
                        Text("Active Routes")
                    } footer: {
                        Text("Traffic to these subnets is routed through Tailscale.")
                    }
                }
                
                // Pending approval
                let pendingRoutes = routes.filter { !$0.approved }
                if !pendingRoutes.isEmpty {
                    Section {
                        ForEach(pendingRoutes) { route in
                            SubnetRouteRow(route: route)
                        }
                    } header: {
                        Text("Pending Approval")
                    } footer: {
                        Text("These routes need admin approval in the admin console.")
                    }
                }
                
                // Disabled routes
                let disabledRoutes = routes.filter { $0.approved && !$0.enabled }
                if !disabledRoutes.isEmpty {
                    Section {
                        ForEach(disabledRoutes) { route in
                            SubnetRouteRow(route: route)
                        }
                    } header: {
                        Text("Disabled Routes")
                    }
                }
            }
            
            // Info section
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("About Subnet Routes")
                            .font(.subheadline)
                        Text("iOS devices can use subnet routes advertised by other devices (Linux, macOS, Windows) but cannot advertise their own routes.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } icon: {
                    Image(systemName: "info.circle")
                        .foregroundColor(.blue)
                }
            }
        }
        .navigationTitle("Subnet Routes")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await loadRoutes()
        }
        .onAppear {
            Task {
                await loadRoutes()
            }
        }
    }
    
    @MainActor
    private func loadRoutes() async {
        guard let vpn = appState.vpnManager else {
            error = "VPN manager not available"
            isLoading = false
            return
        }
        
        isLoading = true
        error = nil
        
        // Routes come from the network map - check peers for advertised routes
        var allRoutes: [SubnetRoute] = []
        
        // Parse routes from prefs/status
        do {
            let endpoint = "/localapi/v0/status"
            let resp = try await vpn.callLocalAPI(method: "GET", endpoint: endpoint)
            let bodyData = try resp.bodyData(endpoint: endpoint)
            
            if let json = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
               let peer = json["Peer"] as? [String: Any] {
                for (_, peerValue) in peer {
                    if let peerInfo = peerValue as? [String: Any],
                       let primaryRoutes = peerInfo["PrimaryRoutes"] as? [String],
                       let hostName = peerInfo["HostName"] as? String {
                        for route in primaryRoutes {
                            // Skip 0.0.0.0/0 and ::/0 (exit node routes)
                            if route != "0.0.0.0/0" && route != "::/0" {
                                allRoutes.append(SubnetRoute(
                                    id: "\(hostName)-\(route)",
                                    cidr: route,
                                    advertisedBy: hostName,
                                    approved: true,
                                    enabled: true
                                ))
                            }
                        }
                    }
                }
            }
            
            routes = allRoutes.sorted { $0.cidr < $1.cidr }
            isLoading = false
        } catch {
            self.error = "Failed to load routes: \(error.localizedDescription)"
            isLoading = false
        }
    }
}

/// Row displaying a single subnet route.
struct SubnetRouteRow: View {
    let route: SubnetRoute
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(route.cidr)
                    .font(.system(.body, design: .monospaced))
                
                HStack(spacing: 8) {
                    if !route.advertisedBy.isEmpty {
                        Label(route.advertisedBy, systemImage: "desktopcomputer")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    statusBadge
                }
            }
            
            Spacer()
            
            statusIcon
        }
        .padding(.vertical, 2)
    }
    
    @ViewBuilder
    private var statusBadge: some View {
        if !route.approved {
            Text("Pending")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.2))
                .foregroundColor(.orange)
                .cornerRadius(4)
        } else if !route.enabled {
            Text("Disabled")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.gray.opacity(0.2))
                .foregroundColor(.gray)
                .cornerRadius(4)
        }
    }
    
    @ViewBuilder
    private var statusIcon: some View {
        if !route.approved {
            Image(systemName: "clock")
                .foregroundColor(.orange)
        } else if route.enabled {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        } else {
            Image(systemName: "xmark.circle")
                .foregroundColor(.gray)
        }
    }
}

/// Model for a subnet route.
struct SubnetRoute: Identifiable {
    let id: String
    let cidr: String
    let advertisedBy: String
    let approved: Bool
    let enabled: Bool
}

#Preview {
    NavigationView {
        SubnetRoutesView()
            .environmentObject(AppState())
    }
}
