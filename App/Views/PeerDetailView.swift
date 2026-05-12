import SwiftUI

/// Detailed view for a peer node.
/// Displays all available information about a device on the Tailscale network.
struct PeerDetailView: View {
    let peer: PeerNode
    @EnvironmentObject var appState: AppState
    @State private var showCopiedMessage: Bool = false
    @State private var copiedText: String = ""
    
    private var isExitNode: Bool {
        peer.isExitNode
    }
    
    private var isCurrentExitNode: Bool {
        guard let exitID = appState.prefs?.ExitNodeID else { return false }
        return peer.id == exitID
    }
    
    var body: some View {
        List {
            // Basic info section
            Section {
                InfoRow(label: "Name", value: peer.displayName) {
                    copyToClipboard(peer.displayName)
                }
                
                if let os = peer.os, !os.isEmpty {
                    InfoRow(label: "OS", value: os, icon: osIcon(for: os))
                }
                
                HStack {
                    Text("Status")
                        .foregroundColor(.secondary)
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(peer.online ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)
                        Text(peer.online ? "Online" : "Offline")
                    }
                }
                
                if peer.isCurrentDevice {
                    HStack {
                        Text("This Device")
                            .foregroundColor(.secondary)
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                }
            } header: {
                Text("Device")
            }
            
            // IP Addresses section
            Section {
                ForEach(peer.addresses, id: \.self) { address in
                    InfoRow(label: isIPv6(address) ? "IPv6" : "IPv4", value: address) {
                        copyToClipboard(address)
                    }
                }
            } header: {
                Text("Addresses")
            } footer: {
                Text("Tap an address to copy it to clipboard.")
            }
            
            // Exit Node section
            if isExitNode && !peer.isCurrentDevice {
                Section {
                    HStack {
                        Text("Exit Node")
                            .foregroundColor(.secondary)
                        Spacer()
                        if isCurrentExitNode {
                            Text("In Use")
                                .foregroundColor(.green)
                                .fontWeight(.medium)
                        } else {
                            Text("Available")
                                .foregroundColor(.blue)
                        }
                    }
                    
                    if isCurrentExitNode {
                        Button(role: .destructive) {
                            appState.clearExitNode()
                        } label: {
                            HStack {
                                Spacer()
                                Text("Stop Using as Exit Node")
                                Spacer()
                            }
                        }
                    } else if peer.online {
                        Button {
                            appState.setExitNode(peer)
                        } label: {
                            HStack {
                                Spacer()
                                Text("Use as Exit Node")
                                Spacer()
                            }
                        }
                    }
                } header: {
                    Text("Exit Node")
                }
            }
            
            // Key & Security section
            Section {
                if let keyExpiry = peer.keyExpiry {
                    let expiryDate = parseISO8601Date(keyExpiry)
                    InfoRow(
                        label: "Key Expires",
                        value: expiryDate.map { formatKeyExpiry($0) } ?? "Unknown",
                        valueColor: keyExpiryColor(expiryDate)
                    )
                }
                
                if let userDisplayName = peer.userDisplayName {
                    InfoRow(label: "Owner", value: userDisplayName)
                }
            } header: {
                Text("Security")
            }
            
            // Hostname section
            Section {
                InfoRow(label: "Hostname", value: peer.hostname) {
                    copyToClipboard(peer.hostname)
                }
                
                if let nodeKey = peer.nodeKey {
                    InfoRow(label: "Node Key", value: truncateNodeKey(nodeKey)) {
                        copyToClipboard(nodeKey)
                    }
                }
            } header: {
                Text("Network")
            }
            
            // Diagnostics section
            if !peer.isCurrentDevice && peer.online {
                Section {
                    NavigationLink {
                        PingView(peer: peer)
                    } label: {
                        HStack {
                            Image(systemName: "waveform.path")
                                .foregroundColor(.accentColor)
                            Text("Ping")
                        }
                    }
                } header: {
                    Text("Diagnostics")
                }
            }
        }
        .navigationTitle(peer.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if showCopiedMessage {
                ToastView(message: "Copied: \(copiedText)")
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showCopiedMessage)
    }
    
    // MARK: - Helper Functions
    
    private func copyToClipboard(_ text: String) {
        UIPasteboard.general.string = text
        copiedText = text.count > 30 ? String(text.prefix(30)) + "..." : text
        showCopiedMessage = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showCopiedMessage = false
        }
    }
    
    private func isIPv6(_ address: String) -> Bool {
        address.contains(":")
    }
    
    private func osIcon(for os: String) -> String {
        let lower = os.lowercased()
        if lower.contains("ios") || lower.contains("iphone") || lower.contains("ipad") {
            return "iphone"
        } else if lower.contains("macos") || lower.contains("darwin") || lower.contains("mac") {
            return "laptopcomputer"
        } else if lower.contains("windows") {
            return "pc"
        } else if lower.contains("linux") {
            return "server.rack"
        } else if lower.contains("android") {
            return "smartphone"
        }
        return "desktopcomputer"
    }
    
    private func parseISO8601Date(_ dateString: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: dateString) {
            return date
        }
        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: dateString)
    }
    
    private func formatKeyExpiry(_ date: Date) -> String {
        let now = Date()
        if date < now {
            return "Expired"
        }
        
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
    
    private func keyExpiryColor(_ date: Date?) -> Color {
        guard let date = date else { return .primary }
        let now = Date()
        if date < now {
            return .red
        }
        let daysUntilExpiry = Calendar.current.dateComponents([.day], from: now, to: date).day ?? 0
        if daysUntilExpiry < 7 {
            return .orange
        }
        return .primary
    }
    
    private func truncateNodeKey(_ key: String) -> String {
        if key.count > 20 {
            return String(key.prefix(10)) + "..." + String(key.suffix(6))
        }
        return key
    }
}

/// Row displaying a label-value pair with optional copy action.
struct InfoRow: View {
    let label: String
    let value: String
    var icon: String? = nil
    var valueColor: Color = .primary
    var onTap: (() -> Void)? = nil
    
    var body: some View {
        Button(action: { onTap?() }) {
            HStack {
                Text(label)
                    .foregroundColor(.secondary)
                Spacer()
                HStack(spacing: 4) {
                    if let icon = icon {
                        Image(systemName: icon)
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                    Text(value)
                        .foregroundColor(valueColor)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil)
    }
}

/// Toast view for feedback messages.
struct ToastView: View {
    let message: String
    
    var body: some View {
        Text(message)
            .font(.caption)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(.systemGray5))
            .cornerRadius(20)
            .shadow(radius: 4)
            .padding(.bottom, 20)
    }
}

/// Ping diagnostics view.
struct PingView: View {
    let peer: PeerNode
    @EnvironmentObject var appState: AppState
    @State private var pingResults: [PingResult] = []
    @State private var isPinging: Bool = false
    @State private var pingCount: Int = 0
    
    var body: some View {
        List {
            Section {
                HStack {
                    Text("Target")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(peer.displayName)
                }
                
                if let addr = peer.primaryIPv4Address ?? peer.addresses.first {
                    HStack {
                        Text("Address")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(addr)
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }
            
            Section {
                Button {
                    startPing()
                } label: {
                    HStack {
                        Spacer()
                        if isPinging {
                            ProgressView()
                                .padding(.trailing, 8)
                            Text("Pinging...")
                        } else {
                            Image(systemName: "waveform.path")
                            Text("Start Ping")
                        }
                        Spacer()
                    }
                }
                .disabled(isPinging || peer.primaryIPv4Address == nil)
            }
            
            if !pingResults.isEmpty {
                Section {
                    ForEach(pingResults) { result in
                        HStack {
                            Text("#\(result.seq)")
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(width: 40, alignment: .leading)
                            
                            Spacer()
                            
                            if let latency = result.latencyMs {
                                Text(String(format: "%.1f ms", latency))
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundColor(latencyColor(latency))
                            } else if let error = result.error {
                                Text(error)
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                        }
                    }
                } header: {
                    Text("Results")
                } footer: {
                    if pingCount > 0 {
                        let successful = pingResults.filter { $0.latencyMs != nil }
                        let avgLatency = successful.compactMap(\.latencyMs).reduce(0, +) / Double(max(successful.count, 1))
                        Text("Sent: \(pingCount) | Received: \(successful.count) | Avg: \(String(format: "%.1f", avgLatency)) ms")
                    }
                }
            }
        }
        .navigationTitle("Ping")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private func startPing() {
        guard let vpn = appState.vpnManager else { return }
        guard let targetIP = peer.primaryIPv4Address else {
            pingResults = [PingResult(seq: 1, error: "No IPv4 address")]
            return
        }
        
        isPinging = true
        pingResults = []
        pingCount = 0
        
        Task {
            // Ping 5 times
            for seq in 1...5 {
                pingCount = seq
                
                do {
                    let endpoint = "/localapi/v0/ping?ip=\(targetIP)&type=disco"
                    let resp = try await vpn.callLocalAPI(method: "POST", endpoint: endpoint, timeout: 3000)
                    
                    if resp.statusCode == 200,
                       let bodyB64 = resp.bodyBase64,
                       let bodyData = Data(base64Encoded: bodyB64) {
                        if let result = try? JSONDecoder().decode(PingAPIResponse.self, from: bodyData),
                           let error = result.Err,
                           !error.isEmpty {
                            await MainActor.run {
                                pingResults.append(PingResult(seq: seq, error: error))
                            }
                        } else if let result = try? JSONDecoder().decode(PingAPIResponse.self, from: bodyData),
                                  let latency = result.LatencySeconds {
                            await MainActor.run {
                                pingResults.append(PingResult(seq: seq, latencyMs: latency * 1000))
                            }
                        } else {
                            await MainActor.run {
                                pingResults.append(PingResult(seq: seq, error: "Invalid response"))
                            }
                        }
                    } else {
                        let errorMessage = pingErrorMessage(from: resp)
                        await MainActor.run {
                            pingResults.append(PingResult(seq: seq, error: errorMessage))
                        }
                    }
                } catch {
                    await MainActor.run {
                        pingResults.append(PingResult(seq: seq, error: error.localizedDescription))
                    }
                }
                
                // Wait 1 second between pings
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            
            await MainActor.run {
                isPinging = false
            }
        }
    }

    private func pingErrorMessage(from response: IPCResponse) -> String {
        if let bodyB64 = response.bodyBase64,
           let bodyData = Data(base64Encoded: bodyB64),
           let body = String(data: bodyData, encoding: .utf8),
           !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return response.error ?? "Request failed"
    }
    
    private func latencyColor(_ ms: Double) -> Color {
        if ms < 50 { return .green }
        if ms < 150 { return .orange }
        return .red
    }
}

/// Single ping result.
struct PingResult: Identifiable {
    let id = UUID()
    let seq: Int
    var latencyMs: Double? = nil
    var error: String? = nil
}

private struct PingAPIResponse: Decodable {
    let Err: String?
    let LatencySeconds: Double?
}

#Preview {
    NavigationView {
        PeerDetailView(peer: PeerNode(
            from: NetworkMap.NodeData(
                ID: 1,
                StableID: "abc123",
                Key: "nodekey:abc123def456",
                Name: "my-macbook.tailnet-name.ts.net",
                ComputedName: "my-macbook",
                Hostinfo: .init(Hostname: "my-macbook"),
                Addresses: ["100.100.1.1/32", "fd7a:115c:a1e0::1/128"],
                Online: true,
                OS: "macOS",
                UserID: 1,
                KeyExpiry: "2025-12-31T23:59:59Z",
                IsExitNode: true,
                AllowedIPs: ["0.0.0.0/0", "::/0"]
            ),
            isSelf: false,
            userProfile: nil
        ))
    }
}
