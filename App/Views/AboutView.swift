import SwiftUI

/// About page with AwgScale branding, version info, and legal notices.
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
            Section {
                VStack(spacing: 16) {
                    Image(systemName: "network")
                        .font(.system(size: 60))
                        .foregroundColor(.accentColor)
                    
                    Text("AwgScale")
                        .font(.title)
                        .fontWeight(.bold)
                    
                    Text("Tailnet connectivity with Amnezia-WG controls")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }
            
            // Version info
            Section {
                InfoRow(label: "Version", value: buildInfo)
                InfoRow(label: "tailscale-awg", value: appState.tailscaleAwgVersion)
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
            
            Section {
                NavigationLink(destination: BugReportView()) {
                    HStack {
                        Image(systemName: "ladybug")
                            .foregroundColor(.accentColor)
                            .frame(width: 24)
                        Text("Bug Report")
                    }
                }
            } header: {
                Text("Diagnostics")
            }
            
            Section {
                NavigationLink(destination: OpenSourceProjectsView()) {
                    HStack {
                        Image(systemName: "doc.plaintext")
                            .foregroundColor(.accentColor)
                            .frame(width: 24)
                        Text("Open Source Projects")
                    }
                }
            } header: {
                Text("Legal")
            }
            
            Section {
                Text("AwgScale is a third-party iOS client compatible with Tailscale and similar in role to tailscale-ios.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)

                Text("AwgScale is independent open source software and is not an official product of any control-plane provider.")
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

/// Open source credits and module inventory for the embedded runtime.
struct OpenSourceProjectsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("AwgScale is built on open source projects. Redistribution must preserve the notices and disclaimers required by each bundled project.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("Core Upstreams")
                        .font(.headline)

                    ForEach(OpenSourceCatalog.coreProjects) { project in
                        OpenSourceProjectCard(project: project)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Bundled Go Runtime Modules")
                        .font(.headline)

                    Text("This list follows the iOS package dependency graph embedded in Libtailscale.xcframework.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    VStack(spacing: 0) {
                        ForEach(Array(OpenSourceCatalog.runtimeModules.enumerated()), id: \.element.id) { index, module in
                            GoRuntimeModuleRow(module: module)

                            if index < OpenSourceCatalog.runtimeModules.count - 1 {
                                Divider()
                                    .padding(.leading, 12)
                            }
                        }
                    }
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(8)
                }
            }
            .padding()
        }
        .navigationTitle("Open Source")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct OpenSourceProject: Identifiable {
    let id = UUID()
    let name: String
    let detail: String
    let license: String?
    let url: URL
}

private struct GoRuntimeModule: Identifiable {
    var id: String { path }
    let path: String
    let version: String
    let sourceNote: String?

    var documentationURL: URL {
        URL(string: "https://pkg.go.dev/\(path)")!
    }
}

private enum OpenSourceCatalog {
    static let coreProjects = [
        OpenSourceProject(
            name: "Tailscale",
            detail: "Tailnet runtime, LocalAPI behavior, networking stack, and Taildrop. The tailscale.com module is resolved to the LiuTangLei AWG fork.",
            license: "BSD 3-Clause License with PATENTS grant",
            url: URL(string: "https://github.com/tailscale/tailscale")!
        ),
        OpenSourceProject(
            name: "LiuTangLei/tailscale",
            detail: "AWG-enabled source fork used for the tailscale.com module in this build.",
            license: nil,
            url: URL(string: "https://github.com/LiuTangLei/tailscale")!
        ),
        OpenSourceProject(
            name: "wireguard-go",
            detail: "WireGuard userspace foundation used through the LiuTangLei AWG fork.",
            license: "MIT License",
            url: URL(string: "https://git.zx2c4.com/wireguard-go/")!
        ),
        OpenSourceProject(
            name: "LiuTangLei/wireguard-go",
            detail: "AWG-enabled wireguard-go fork used by the embedded Go runtime.",
            license: nil,
            url: URL(string: "https://github.com/LiuTangLei/wireguard-go")!
        ),
        OpenSourceProject(
            name: "Amnezia-WG",
            detail: "AWG protocol ideas and configuration model surfaced by the forked networking stack.",
            license: nil,
            url: URL(string: "https://github.com/amnezia-vpn/amneziawg-go")!
        ),
        OpenSourceProject(
            name: "golang.org/x/crypto/ssh",
            detail: "SSH client implementation used by the built-in terminal.",
            license: "BSD 3-Clause License",
            url: URL(string: "https://pkg.go.dev/golang.org/x/crypto/ssh")!
        ),
        OpenSourceProject(
            name: "Go",
            detail: "Toolchain used to build the embedded networking runtime.",
            license: "BSD 3-Clause License",
            url: URL(string: "https://go.dev/")!
        ),
        OpenSourceProject(
            name: "gomobile",
            detail: "Go-to-iOS binding toolchain used to build Libtailscale.xcframework.",
            license: "BSD 3-Clause License",
            url: URL(string: "https://pkg.go.dev/golang.org/x/mobile")!
        ),
        OpenSourceProject(
            name: "XcodeGen",
            detail: "Project generation tool used to produce the Xcode project from project.yml.",
            license: "MIT License",
            url: URL(string: "https://github.com/yonaskolb/XcodeGen")!
        )
    ]

    static let runtimeModules = [
        GoRuntimeModule(path: "filippo.io/edwards25519", version: "v1.2.0", sourceNote: nil),
        GoRuntimeModule(path: "github.com/LiuTangLei/wireguard-go", version: "v0.0.20", sourceNote: nil),
        GoRuntimeModule(path: "github.com/creachadair/msync", version: "v0.7.1", sourceNote: nil),
        GoRuntimeModule(path: "github.com/fxamacker/cbor/v2", version: "v2.9.0", sourceNote: nil),
        GoRuntimeModule(path: "github.com/gaissmai/bart", version: "v0.26.1", sourceNote: nil),
        GoRuntimeModule(path: "github.com/go-json-experiment/json", version: "v0.0.0-20250813024750-ebf49471dced", sourceNote: nil),
        GoRuntimeModule(path: "github.com/golang/groupcache", version: "v0.0.0-20241129210726-2c02b8208cf8", sourceNote: nil),
        GoRuntimeModule(path: "github.com/google/btree", version: "v1.1.3", sourceNote: nil),
        GoRuntimeModule(path: "github.com/hdevalence/ed25519consensus", version: "v0.2.0", sourceNote: nil),
        GoRuntimeModule(path: "github.com/klauspost/compress", version: "v1.18.5", sourceNote: nil),
        GoRuntimeModule(path: "github.com/pires/go-proxyproto", version: "v0.8.1", sourceNote: nil),
        GoRuntimeModule(path: "github.com/tailscale/peercred", version: "v0.0.0-20250107143737-35a0c7bd7edc", sourceNote: nil),
        GoRuntimeModule(path: "github.com/x448/float16", version: "v0.8.4", sourceNote: nil),
        GoRuntimeModule(path: "go4.org/mem", version: "v0.0.0-20240501181205-ae6ca9944745", sourceNote: nil),
        GoRuntimeModule(path: "go4.org/netipx", version: "v0.0.0-20231129151722-fdeea329fbba", sourceNote: nil),
        GoRuntimeModule(path: "golang.org/x/crypto", version: "v0.50.0", sourceNote: nil),
        GoRuntimeModule(path: "golang.org/x/exp", version: "v0.0.0-20250620022241-b7579e27df2b", sourceNote: nil),
        GoRuntimeModule(path: "golang.org/x/mobile", version: "v0.0.0-20260312152759-81488f6aeb60", sourceNote: nil),
        GoRuntimeModule(path: "golang.org/x/mod", version: "v0.35.0", sourceNote: nil),
        GoRuntimeModule(path: "golang.org/x/net", version: "v0.53.0", sourceNote: nil),
        GoRuntimeModule(path: "golang.org/x/sync", version: "v0.20.0", sourceNote: nil),
        GoRuntimeModule(path: "golang.org/x/sys", version: "v0.43.0", sourceNote: nil),
        GoRuntimeModule(path: "golang.org/x/term", version: "v0.42.0", sourceNote: nil),
        GoRuntimeModule(path: "golang.org/x/text", version: "v0.36.0", sourceNote: nil),
        GoRuntimeModule(path: "golang.org/x/time", version: "v0.12.0", sourceNote: nil),
        GoRuntimeModule(path: "golang.org/x/tools", version: "v0.44.0", sourceNote: nil),
        GoRuntimeModule(path: "gvisor.dev/gvisor", version: "v0.0.0-20260224225140-573d5e7127a8", sourceNote: nil),
        GoRuntimeModule(path: "tailscale.com", version: "v1.98.2", sourceNote: "source replaced by github.com/LiuTangLei/tailscale")
    ]
}

/// Individual core project credit.
private struct OpenSourceProjectCard: View {
    let project: OpenSourceProject
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(project.name)
                .font(.headline)
            
            Text(project.detail)
                .font(.caption)
                .foregroundColor(.secondary)

            if let license = project.license {
                Text(license)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Link(destination: project.url) {
                HStack {
                    Text(project.url.absoluteString)
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

private struct GoRuntimeModuleRow: View {
    let module: GoRuntimeModule

    var body: some View {
        Link(destination: module.documentationURL) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top) {
                    Text(module.path)
                        .font(.caption)
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Text(module.version)
                    .font(.caption2)
                    .foregroundColor(.secondary)

                if let sourceNote = module.sourceNote {
                    Text(sourceNote)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
