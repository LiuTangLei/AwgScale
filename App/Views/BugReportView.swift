import SwiftUI
import os

/// Bug Report generation and export view.
struct BugReportView: View {
    @EnvironmentObject var appState: AppState
    @State private var isGenerating: Bool = false
    @State private var reportData: BugReportData?
    @State private var error: String?
    @State private var showingShareSheet: Bool = false
    @State private var reportFileURL: URL?
    
    var body: some View {
        List {
            // Info section
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Label {
                        Text("Generate a diagnostic report to help troubleshoot issues.")
                            .font(.subheadline)
                    } icon: {
                        Image(systemName: "ladybug")
                            .foregroundColor(.orange)
                    }
                    
                    Text("The report includes:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        BulletPoint("App and system version info")
                        BulletPoint("Current connection state")
                        BulletPoint("Network configuration")
                        BulletPoint("Health warnings")
                        BulletPoint("Recent logs (sanitized)")
                    }
                    .padding(.leading, 8)
                }
                .padding(.vertical, 4)
            } footer: {
                Text("Personal information like IP addresses may be included. Review before sharing.")
            }
            
            // Generate button
            Section {
                Button {
                    generateReport()
                } label: {
                    HStack {
                        Spacer()
                        if isGenerating {
                            ProgressView()
                                .padding(.trailing, 8)
                            Text("Generating...")
                        } else {
                            Image(systemName: "doc.badge.gearshape")
                            Text("Generate Report")
                        }
                        Spacer()
                    }
                }
                .disabled(isGenerating)
            }
            
            if let error = error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundColor(.red)
                }
            }
            
            // Report preview
            if let report = reportData {
                Section {
                    HStack {
                        Text("Report ID")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(report.reportID)
                            .font(.system(.caption, design: .monospaced))
                    }
                    
                    HStack {
                        Text("Generated")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(report.timestamp, style: .relative)
                    }
                    
                    HStack {
                        Text("Size")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(formatBytes(report.size))
                    }
                } header: {
                    Text("Report Ready")
                }
                
                Section {
                    Button {
                        showingShareSheet = true
                    } label: {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                            Text("Share Report")
                        }
                    }
                    
                    Button {
                        copyReportID(report.reportID)
                    } label: {
                        HStack {
                            Image(systemName: "doc.on.doc")
                            Text("Copy Report ID")
                        }
                    }
                }
            }
        }
        .navigationTitle("Bug Report")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingShareSheet) {
            if let url = reportFileURL {
                ShareSheet(activityItems: [url])
            }
        }
    }
    
    private func generateReport() {
        guard let vpn = appState.vpnManager else {
            error = "VPN manager not available"
            return
        }
        
        isGenerating = true
        error = nil
        reportData = nil
        
        Task {
            do {
                // Collect diagnostic data
                var diagnostics: [String: Any] = [:]
                
                // Basic info
                diagnostics["report_id"] = UUID().uuidString.prefix(8).uppercased()
                diagnostics["timestamp"] = ISO8601DateFormatter().string(from: Date())
                diagnostics["app_version"] = appState.appVersion
                diagnostics["os_version"] = ProcessInfo.processInfo.operatingSystemVersionString
                diagnostics["device_model"] = getDeviceModel()
                
                // Connection state
                diagnostics["ipn_state"] = appState.ipnState.displayName
                diagnostics["vpn_status"] = vpn.vpnStatus.rawValue
                
                // Prefs (sanitized)
                if let prefs = appState.prefs {
                    diagnostics["wants_running"] = prefs.WantRunning ?? false
                    diagnostics["exit_node_configured"] = prefs.ExitNodeID != nil && !prefs.ExitNodeID!.isEmpty
                    diagnostics["allow_lan_access"] = prefs.ExitNodeAllowLANAccess ?? false
                }
                
                // Self node
                if let selfNode = appState.selfNode {
                    diagnostics["self_hostname"] = selfNode.displayName
                    diagnostics["self_online"] = selfNode.online
                    diagnostics["self_os"] = selfNode.os ?? "unknown"
                }
                
                // Peer count
                diagnostics["peer_count"] = appState.peers.count
                diagnostics["online_peers"] = appState.peers.filter { $0.online }.count
                
                // Health warnings
                if let health = appState.health?.Warnings {
                    diagnostics["health_warning_count"] = health.count
                    diagnostics["health_warnings"] = health.map { key, value in
                        [
                            "code": key,
                            "severity": value.Severity ?? "unknown",
                            "impacts_connectivity": value.ImpactsConnectivity ?? false
                        ]
                    }
                }
                
                // AWG status
                diagnostics["awg_local_enabled"] = appState.localAwgStatus
                diagnostics["awg_peer_count"] = appState.awgPeersStatus.filter { $0.value }.count
                
                // Fetch logs from LocalAPI
                do {
                    let endpoint = "/localapi/v0/bugreport"
                    let logsResp = try await vpn.callLocalAPI(method: "GET", endpoint: endpoint)
                    let bodyData = try logsResp.bodyData(endpoint: endpoint)
                    if let logsStr = String(data: bodyData, encoding: .utf8) {
                        diagnostics["bugreport_logs"] = logsStr
                    }
                } catch {
                    diagnostics["bugreport_error"] = error.localizedDescription
                }
                
                // Generate JSON
                let jsonData = try JSONSerialization.data(withJSONObject: diagnostics, options: [.prettyPrinted, .sortedKeys])
                
                // Save to temp file
                let reportID = diagnostics["report_id"] as! String
                let fileName = "tailscale-bugreport-\(reportID).json"
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
                try jsonData.write(to: tempURL)
                
                await MainActor.run {
                    reportData = BugReportData(
                        reportID: String(reportID),
                        timestamp: Date(),
                        size: jsonData.count
                    )
                    reportFileURL = tempURL
                    isGenerating = false
                }
            } catch {
                await MainActor.run {
                    self.error = "Failed to generate report: \(error.localizedDescription)"
                    isGenerating = false
                }
            }
        }
    }
    
    private func getDeviceModel() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(cString: machine)
    }
    
    private func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
    
    private func copyReportID(_ id: String) {
        UIPasteboard.general.string = id
    }
}

/// Bullet point text.
struct BulletPoint: View {
    let text: String
    
    init(_ text: String) {
        self.text = text
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .foregroundColor(.secondary)
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

/// Bug report data model.
struct BugReportData {
    let reportID: String
    let timestamp: Date
    let size: Int
}

#Preview {
    NavigationView {
        BugReportView()
            .environmentObject(AppState())
    }
}
