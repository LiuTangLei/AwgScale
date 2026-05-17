import SwiftUI
import Darwin

/// Subnet Routes management view.
/// Displays routes advertised by peers and routes advertised by this device.
struct SubnetRoutesView: View {
    @EnvironmentObject var appState: AppState
    @State private var routes: [SubnetRoute] = []
    @State private var advertisedRoutes: [String] = []
    @State private var advertisedRouteInput: String = ""
    @State private var useSubnetRoutes: Bool = true
    @State private var isLoading: Bool = true
    @State private var isSavingSubnetPreference: Bool = false
    @State private var isSavingAdvertisedRoutes: Bool = false
    @State private var error: String?
    @State private var advertisedRouteError: String?
    
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
            } else {
                Section {
                    Toggle(isOn: Binding(
                        get: { useSubnetRoutes },
                        set: { setUseSubnetRoutes($0) }
                    )) {
                        HStack {
                            Image(systemName: "network")
                                .foregroundColor(.accentColor)
                                .frame(width: 24)
                            Text("Use Subnet Routes")
                        }
                    }
                    .disabled(isSavingSubnetPreference)
                } footer: {
                    Text("Route traffic for approved subnet routes through your tailnet.")
                }

                Section {
                    if advertisedRoutes.isEmpty {
                        Text("No local subnet routes advertised")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(advertisedRoutes, id: \.self) { route in
                            HStack {
                                Text(route)
                                    .font(.system(.body, design: .monospaced))
                                Spacer()
                                Button(role: .destructive) {
                                    deleteAdvertisedRoute(route)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .disabled(isSavingAdvertisedRoutes)
                            }
                        }
                    }

                    HStack {
                        TextField("192.168.1.0/24", text: $advertisedRouteInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                            .disabled(isSavingAdvertisedRoutes)

                        Button {
                            addAdvertisedRoute()
                        } label: {
                            if isSavingAdvertisedRoutes {
                                ProgressView()
                            } else {
                                Image(systemName: "plus.circle.fill")
                            }
                        }
                        .disabled(isSavingAdvertisedRoutes || advertisedRouteInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if let advertisedRouteError {
                        Label(advertisedRouteError, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                } header: {
                    Text("Advertise Routes")
                } footer: {
                    Text("Advertise local LAN prefixes from this device. Exit-node default routes are configured separately.")
                }

                if routes.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No subnet routes available")
                                .foregroundColor(.secondary)
                            Text("Subnet routes allow you to access networks behind other devices. Routes must be advertised by another device and approved by an admin.")
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
                            Text("Traffic to these subnets is routed through your overlay network.")
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
            }
            
            // Info section
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("About Subnet Routes")
                            .font(.subheadline)
                        Text("Subnet routes can be used from other devices or advertised from this device after admin approval.")
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
        .task {
            await loadRoutes()
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
        
        var allRoutes: [SubnetRoute] = []
        
        do {
            let client = LocalAPIClient.vpn(vpn)
            let status = try await client.status()
            let prefs = try? await client.ipnPrefs()
            let routeAll = prefs?.RouteAll ?? true
            let localAdvertisedRoutes = prefs?.AdvertiseRoutes ?? []

            for (peerID, peer) in status.Peer ?? [:] {
                for route in peer.PrimaryRoutes ?? [] where SubnetRoute.isSubnetRoute(route) {
                    allRoutes.append(SubnetRoute(
                        id: "\(peerID)-\(route)",
                        cidr: route,
                        advertisedBy: peer.displayName,
                        approved: true,
                        enabled: routeAll,
                        online: peer.Online ?? false,
                        active: peer.Active ?? false,
                        os: peer.OS
                    ))
                }
            }

            useSubnetRoutes = routeAll
            advertisedRoutes = localAdvertisedRoutes.sorted()
            routes = allRoutes.sorted {
                if $0.cidr == $1.cidr { return $0.advertisedBy < $1.advertisedBy }
                return $0.cidr < $1.cidr
            }
            isLoading = false
        } catch {
            self.error = "Failed to load routes: \(error.localizedDescription)"
            isLoading = false
        }
    }

    private func setUseSubnetRoutes(_ enabled: Bool) {
        guard !isSavingSubnetPreference, let vpn = appState.vpnManager else { return }
        let previous = useSubnetRoutes
        let previousRoutes = routes
        useSubnetRoutes = enabled
        routes = routes.map { $0.withEnabled(enabled) }
        isSavingSubnetPreference = true

        Task {
            do {
                try await LocalAPIClient.vpn(vpn).setUseSubnetRoutes(enabled)
                await MainActor.run {
                    isSavingSubnetPreference = false
                    error = nil
                }
            } catch {
                await MainActor.run {
                    useSubnetRoutes = previous
                    routes = previousRoutes
                    self.error = "Failed to update subnet route preference: \(error.localizedDescription)"
                    isSavingSubnetPreference = false
                }
            }
        }
    }

    private func addAdvertisedRoute() {
        do {
            let route = try SubnetRoute.normalizedAdvertisedRoute(advertisedRouteInput)
            guard !advertisedRoutes.contains(route) else {
                advertisedRouteError = "This route is already advertised."
                return
            }
            saveAdvertisedRoutes((advertisedRoutes + [route]).sorted())
            advertisedRouteInput = ""
            advertisedRouteError = nil
        } catch {
            advertisedRouteError = error.localizedDescription
        }
    }

    private func deleteAdvertisedRoute(_ route: String) {
        saveAdvertisedRoutes(advertisedRoutes.filter { $0 != route })
    }

    private func saveAdvertisedRoutes(_ newRoutes: [String]) {
        guard !isSavingAdvertisedRoutes, let vpn = appState.vpnManager else { return }
        let previous = advertisedRoutes
        advertisedRoutes = newRoutes
        isSavingAdvertisedRoutes = true

        Task {
            do {
                try await LocalAPIClient.vpn(vpn).setAdvertiseRoutes(newRoutes)
                await MainActor.run {
                    isSavingAdvertisedRoutes = false
                    advertisedRouteError = nil
                    error = nil
                }
            } catch {
                await MainActor.run {
                    advertisedRoutes = previous
                    advertisedRouteError = "Failed to save advertised routes: \(error.localizedDescription)"
                    isSavingAdvertisedRoutes = false
                }
            }
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
                    if let os = route.os, !os.isEmpty {
                        Text(os)
                            .font(.caption2)
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
        } else if !route.online {
            Text("Offline")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15))
                .foregroundColor(.secondary)
                .cornerRadius(4)
        } else if route.enabled {
            Image(systemName: route.online ? "checkmark.circle.fill" : "wifi.slash")
                .foregroundColor(route.online ? .green : .secondary)
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
    let online: Bool
    let active: Bool
    let os: String?

    func withEnabled(_ enabled: Bool) -> SubnetRoute {
        SubnetRoute(id: id, cidr: cidr, advertisedBy: advertisedBy, approved: approved, enabled: enabled, online: online, active: active, os: os)
    }

    static func isSubnetRoute(_ route: String) -> Bool {
        let route = route.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !route.isEmpty,
              route != "0.0.0.0/0",
              route != "::/0" else { return false }
        return route.contains("/")
    }

    static func normalizedAdvertisedRoute(_ value: String) throws -> String {
        let route = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = route.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty,
              let bits = Int(parts[1]) else {
            throw SubnetRouteValidationError("Enter a CIDR route like 192.168.1.0/24.")
        }

        let address = String(parts[0])
        if address.contains(":") {
            guard (0...128).contains(bits), isValidIP(address, family: AF_INET6) else {
                throw SubnetRouteValidationError("Enter a valid IPv6 CIDR route.")
            }
        } else {
            guard (0...32).contains(bits), isValidIP(address, family: AF_INET) else {
                throw SubnetRouteValidationError("Enter a valid IPv4 CIDR route.")
            }
        }

        let normalized = "\(address)/\(bits)"
        guard normalized != "0.0.0.0/0", normalized != "::/0" else {
            throw SubnetRouteValidationError("Exit-node default routes are configured separately.")
        }
        return normalized
    }

    private static func isValidIP(_ address: String, family: Int32) -> Bool {
        if family == AF_INET {
            var ipv4 = in_addr()
            return address.withCString { inet_pton(AF_INET, $0, &ipv4) == 1 }
        }
        var ipv6 = in6_addr()
        return address.withCString { inet_pton(AF_INET6, $0, &ipv6) == 1 }
    }
}

private struct SubnetRouteValidationError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

#Preview {
    NavigationView {
        SubnetRoutesView()
            .environmentObject(AppState())
    }
}
