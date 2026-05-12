import SwiftUI

/// DNS Settings view (read-only display).
/// Shows the current DNS configuration from the Tailscale network.
struct DNSSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var dnsConfig: DNSConfig?
    @State private var isLoading: Bool = true
    @State private var error: String?
    
    var body: some View {
        List {
            if isLoading {
                Section {
                    HStack {
                        ProgressView()
                            .padding(.trailing, 8)
                        Text("Loading DNS configuration...")
                            .foregroundColor(.secondary)
                    }
                }
            } else if let error = error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundColor(.red)
                }
            } else if let config = dnsConfig {
                // MagicDNS status
                Section {
                    HStack {
                        Text("MagicDNS")
                        Spacer()
                        if config.magicDNSEnabled {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("Enabled")
                                    .foregroundColor(.green)
                            }
                        } else {
                            Text("Disabled")
                                .foregroundColor(.secondary)
                        }
                    }
                } footer: {
                    Text("MagicDNS assigns DNS names to your devices automatically.")
                }
                
                // DNS suffix
                if let suffix = config.magicDNSSuffix, !suffix.isEmpty {
                    Section {
                        DNSInfoRow(label: "DNS Suffix", value: suffix, copyable: true)
                    } header: {
                        Text("Tailnet Domain")
                    }
                }
                
                // Global resolvers
                if !config.resolvers.isEmpty {
                    Section {
                        ForEach(config.resolvers, id: \.self) { resolver in
                            DNSInfoRow(label: "Resolver", value: resolver, copyable: true)
                        }
                    } header: {
                        Text("Global Resolvers")
                    } footer: {
                        Text("DNS queries are sent to these resolvers.")
                    }
                }
                
                // Fallback resolvers
                if !config.fallbackResolvers.isEmpty {
                    Section {
                        ForEach(config.fallbackResolvers, id: \.self) { resolver in
                            DNSInfoRow(label: "Fallback", value: resolver, copyable: true)
                        }
                    } header: {
                        Text("Fallback Resolvers")
                    } footer: {
                        Text("Used when primary resolvers are unavailable.")
                    }
                }
                
                // Routes (split DNS)
                if !config.routes.isEmpty {
                    Section {
                        ForEach(config.routes.sorted(by: { $0.key < $1.key }), id: \.key) { domain, resolvers in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(domain)
                                    .font(.body)
                                ForEach(resolvers, id: \.self) { resolver in
                                    Text(resolver)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        Text("Split DNS Routes")
                    } footer: {
                        Text("Queries for these domains are routed to specific resolvers.")
                    }
                }
                
                // Search domains
                if !config.searchDomains.isEmpty {
                    Section {
                        ForEach(config.searchDomains, id: \.self) { domain in
                            Text(domain)
                        }
                    } header: {
                        Text("Search Domains")
                    } footer: {
                        Text("These domains are appended when resolving short hostnames.")
                    }
                }
                
                // Use Tailscale DNS toggle info
                Section {
                    HStack {
                        Text("Use Tailscale DNS")
                        Spacer()
                        Text(config.useTailscaleDNS ? "Yes" : "No")
                            .foregroundColor(.secondary)
                    }
                } footer: {
                    Text("DNS settings are managed by your Tailnet admin in the admin console.")
                }
            } else {
                Section {
                    Text("No DNS configuration available")
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("DNS Settings")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await loadDNSConfig()
        }
        .onAppear {
            Task {
                await loadDNSConfig()
            }
        }
    }
    
    @MainActor
    private func loadDNSConfig() async {
        guard let vpn = appState.vpnManager else {
            error = "VPN manager not available"
            isLoading = false
            return
        }
        
        isLoading = true
        error = nil
        
        do {
            let endpoint = "/localapi/v0/dns/config"
            let resp = try await vpn.callLocalAPI(method: "GET", endpoint: endpoint)
            let config = try resp.decodedBody(DNSConfigResponse.self, endpoint: endpoint)
            dnsConfig = DNSConfig(from: config)
            isLoading = false
        } catch {
            self.error = "Failed to load DNS config: \(error.localizedDescription)"
            isLoading = false
        }
    }
}

/// Row displaying a DNS info item with optional copy functionality.
struct DNSInfoRow: View {
    let label: String
    let value: String
    var copyable: Bool = false
    @State private var showCopied: Bool = false
    
    var body: some View {
        Button {
            if copyable {
                UIPasteboard.general.string = value
                showCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    showCopied = false
                }
            }
        } label: {
            HStack {
                Text(label)
                    .foregroundColor(.secondary)
                Spacer()
                if showCopied {
                    Text("Copied!")
                        .foregroundColor(.green)
                        .font(.caption)
                } else {
                    Text(value)
                        .foregroundColor(.primary)
                        .font(.system(.body, design: .monospaced))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!copyable)
    }
}

// MARK: - DNS Config Models

/// Response from /localapi/v0/dns/config
struct DNSConfigResponse: Codable {
    let Resolvers: [ResolverEntry]?
    let FallbackResolvers: [ResolverEntry]?
    let Routes: [String: [ResolverEntry]?]?
    let Domains: [String]?
    
    struct ResolverEntry: Codable {
        let Addr: String?
    }
}

/// Parsed DNS configuration for display.
struct DNSConfig {
    let resolvers: [String]
    let fallbackResolvers: [String]
    let routes: [String: [String]]
    let searchDomains: [String]
    let magicDNSEnabled: Bool
    let magicDNSSuffix: String?
    let useTailscaleDNS: Bool
    
    init(from response: DNSConfigResponse) {
        self.resolvers = response.Resolvers?.compactMap { $0.Addr } ?? []
        self.fallbackResolvers = response.FallbackResolvers?.compactMap { $0.Addr } ?? []
        
        var routesMap: [String: [String]] = [:]
        if let routes = response.Routes {
            for (domain, entries) in routes {
                let addrs = entries?.compactMap { $0.Addr } ?? []
                if !addrs.isEmpty {
                    routesMap[domain] = addrs
                }
            }
        }
        self.routes = routesMap
        
        self.searchDomains = response.Domains ?? []
        self.magicDNSEnabled = !self.resolvers.isEmpty || !routesMap.isEmpty
        self.magicDNSSuffix = response.Domains?.first
        self.useTailscaleDNS = true
    }
}

#Preview {
    NavigationView {
        DNSSettingsView()
            .environmentObject(AppState())
    }
}
