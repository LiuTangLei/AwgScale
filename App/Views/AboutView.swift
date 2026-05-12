import SwiftUI

/// Enhanced About page with branding, version info, and legal links.
struct AboutView: View {
    @EnvironmentObject var appState: AppState
    @State private var showCopiedToast: Bool = false
    
    private var buildInfo: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }
    
    private var deviceInfo: String {
        """
        App: \(buildInfo)
        iOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Device: \(getDeviceModel())
        """
    }
    
    var body: some View {
        List {
            // Branding section
            Section {
                VStack(spacing: 16) {
                    // Logo placeholder
                    Image(systemName: "network")
                        .font(.system(size: 60))
                        .foregroundColor(.accentColor)
                    
                    Text("Tailscale")
                        .font(.title)
                        .fontWeight(.bold)
                    
                    Text("Secure networking made simple")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }
            
            // Version info
            Section {
                InfoRow(label: "Version", value: buildInfo)
                InfoRow(label: "iOS Version", value: ProcessInfo.processInfo.operatingSystemVersionString)
                InfoRow(label: "Device", value: getDeviceModel())
                
                Button {
                    copyDeviceInfo()
                } label: {
                    HStack {
                        Image(systemName: "doc.on.doc")
                            .foregroundColor(.accentColor)
                        Text("Copy Device Info")
                    }
                }
            } header: {
                Text("Version")
            }
            
            // Links section
            Section {
                Link(destination: URL(string: "https://tailscale.com/")!) {
                    LinkRow(title: "Website", icon: "globe")
                }
                
                Link(destination: URL(string: "https://tailscale.com/kb/")!) {
                    LinkRow(title: "Documentation", icon: "book")
                }
                
                Link(destination: URL(string: "https://tailscale.com/contact/support")!) {
                    LinkRow(title: "Support", icon: "questionmark.circle")
                }
                
                NavigationLink(destination: BugReportView()) {
                    HStack {
                        Image(systemName: "ladybug")
                            .foregroundColor(.accentColor)
                            .frame(width: 24)
                        Text("Bug Report")
                    }
                }
            } header: {
                Text("Help & Support")
            }
            
            // Legal section
            Section {
                Link(destination: URL(string: "https://tailscale.com/privacy-policy")!) {
                    LinkRow(title: "Privacy Policy", icon: "hand.raised")
                }
                
                Link(destination: URL(string: "https://tailscale.com/terms")!) {
                    LinkRow(title: "Terms of Service", icon: "doc.text")
                }
                
                NavigationLink(destination: LicensesView()) {
                    HStack {
                        Image(systemName: "doc.plaintext")
                            .foregroundColor(.accentColor)
                            .frame(width: 24)
                        Text("Open Source Licenses")
                    }
                }
            } header: {
                Text("Legal")
            }
            
            // Copyright
            Section {
                Text("© 2024 Tailscale Inc.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if showCopiedToast {
                ToastView(message: "Device info copied")
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showCopiedToast)
    }
    
    private func getDeviceModel() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(cString: machine)
    }
    
    private func copyDeviceInfo() {
        UIPasteboard.general.string = deviceInfo
        showCopiedToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showCopiedToast = false
        }
    }
}

/// Link row with external indicator.
struct LinkRow: View {
    let title: String
    let icon: String
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
                .frame(width: 24)
            Text(title)
                .foregroundColor(.primary)
            Spacer()
            Image(systemName: "arrow.up.right.square")
                .foregroundColor(.secondary)
                .font(.caption)
        }
    }
}

/// Open source licenses view.
struct LicensesView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("This app includes open source software.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                LicenseSection(
                    name: "Tailscale",
                    license: "BSD 3-Clause License",
                    url: "https://github.com/tailscale/tailscale"
                )
                
                LicenseSection(
                    name: "WireGuard",
                    license: "MIT License",
                    url: "https://www.wireguard.com/"
                )
                
                LicenseSection(
                    name: "Go",
                    license: "BSD 3-Clause License",
                    url: "https://go.dev/"
                )
                
                LicenseSection(
                    name: "gomobile",
                    license: "BSD 3-Clause License",
                    url: "https://pkg.go.dev/golang.org/x/mobile"
                )
                
                Spacer()
            }
            .padding()
        }
        .navigationTitle("Licenses")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Individual license section.
struct LicenseSection: View {
    let name: String
    let license: String
    let url: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(name)
                .font(.headline)
            
            Text(license)
                .font(.caption)
                .foregroundColor(.secondary)
            
            Link(destination: URL(string: url)!) {
                HStack {
                    Text(url)
                        .font(.caption)
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption2)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(8)
    }
}

// Use the ToastView from PeerDetailView if already defined, otherwise define here
// ToastView is already defined in PeerDetailView.swift

#Preview {
    NavigationView {
        AboutView()
            .environmentObject(AppState())
    }
}
