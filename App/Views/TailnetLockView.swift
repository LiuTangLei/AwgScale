import SwiftUI

/// Tailnet Lock management view.
/// Shows lock status and allows signing operations.
struct TailnetLockView: View {
    @EnvironmentObject var appState: AppState
    @State private var lockStatus: TailnetLockStatus?
    @State private var isLoading: Bool = true
    @State private var error: String?
    @State private var showingQRScanner: Bool = false
    @State private var showingSignURL: Bool = false
    @State private var signURL: String = ""
    @State private var isSigning: Bool = false
    
    var body: some View {
        List {
            if isLoading {
                Section {
                    HStack {
                        ProgressView()
                            .padding(.trailing, 8)
                        Text("Loading Tailnet Lock status...")
                            .foregroundColor(.secondary)
                    }
                }
            } else if let error = error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundColor(.red)
                }
            } else if let status = lockStatus {
                // Lock status
                Section {
                    HStack {
                        Image(systemName: status.enabled ? "lock.shield.fill" : "lock.open")
                            .foregroundColor(status.enabled ? .green : .secondary)
                            .font(.title2)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Tailnet Lock")
                                .font(.headline)
                            Text(status.enabled ? "Enabled" : "Not Enabled")
                                .font(.subheadline)
                                .foregroundColor(status.enabled ? .green : .secondary)
                        }
                    }
                } footer: {
                    Text("Tailnet Lock requires nodes to be signed by trusted signing keys before they can join your network.")
                }
                
                // This node's status
                if status.enabled {
                    Section {
                        // Node key
                        if let nodeKey = status.nodeKey {
                            CopyableRow(label: "Node Key", value: truncateKey(nodeKey), fullValue: nodeKey)
                        }
                        
                        // Node key signature status
                        HStack {
                            Text("Signature")
                            Spacer()
                            if status.nodeKeySigned {
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.seal.fill")
                                        .foregroundColor(.green)
                                    Text("Signed")
                                        .foregroundColor(.green)
                                }
                            } else {
                                HStack(spacing: 4) {
                                    Image(systemName: "questionmark.circle")
                                        .foregroundColor(.orange)
                                    Text("Not Signed")
                                        .foregroundColor(.orange)
                                }
                            }
                        }
                    } header: {
                        Text("This Device")
                    }
                    
                    // Signing key (if this device can sign)
                    if let tlPubKey = status.publicKey {
                        Section {
                            CopyableRow(label: "TL Public Key", value: truncateKey(tlPubKey), fullValue: tlPubKey)
                            
                            HStack {
                                Text("Can Sign")
                                Spacer()
                                if status.isSigningKey {
                                    HStack(spacing: 4) {
                                        Image(systemName: "signature")
                                            .foregroundColor(.green)
                                        Text("Yes")
                                            .foregroundColor(.green)
                                    }
                                } else {
                                    Text("No")
                                        .foregroundColor(.secondary)
                                }
                            }
                        } header: {
                            Text("Tailnet Lock Key")
                        } footer: {
                            if status.isSigningKey {
                                Text("This device is a trusted signing node and can sign other nodes.")
                            } else {
                                Text("This device cannot sign other nodes. A Tailnet admin can add this key as a signing key.")
                            }
                        }
                    }
                    
                    // Signing operations (if this device can sign)
                    if status.isSigningKey {
                        Section {
                            Button {
                                showingQRScanner = true
                            } label: {
                                HStack {
                                    Image(systemName: "qrcode.viewfinder")
                                        .foregroundColor(.accentColor)
                                    Text("Scan QR Code to Sign")
                                }
                            }
                            
                            Button {
                                showingSignURL = true
                            } label: {
                                HStack {
                                    Image(systemName: "link")
                                        .foregroundColor(.accentColor)
                                    Text("Sign via URL")
                                }
                            }
                        } header: {
                            Text("Sign Nodes")
                        } footer: {
                            Text("Sign other devices to allow them to join your Tailnet.")
                        }
                    }
                    
                    // Trusted keys
                    if !status.trustedKeys.isEmpty {
                        Section {
                            ForEach(status.trustedKeys, id: \.self) { key in
                                Text(truncateKey(key))
                                    .font(.system(.caption, design: .monospaced))
                            }
                        } header: {
                            Text("Trusted Signing Keys (\(status.trustedKeys.count))")
                        }
                    }
                }
            } else {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tailnet Lock Not Available")
                            .font(.headline)
                        Text("Tailnet Lock is not configured for this Tailnet. Contact your Tailnet admin to enable it.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 8)
                }
            }
            
            // Info section
            Section {
                Link(destination: URL(string: "https://tailscale.com/kb/1226/tailnet-lock")!) {
                    HStack {
                        Image(systemName: "questionmark.circle")
                            .foregroundColor(.blue)
                        Text("Learn about Tailnet Lock")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Tailnet Lock")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await loadLockStatus()
        }
        .onAppear {
            Task {
                await loadLockStatus()
            }
        }
        .sheet(isPresented: $showingSignURL) {
            NavigationView {
                SignURLView(onSign: { url in
                    signURL = url
                    showingSignURL = false
                    signNode(url: url)
                })
            }
        }
        .overlay {
            if isSigning {
                ZStack {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Signing node...")
                            .foregroundColor(.white)
                    }
                    .padding(32)
                    .background(Color(.systemBackground))
                    .cornerRadius(16)
                }
            }
        }
    }
    
    @MainActor
    private func loadLockStatus() async {
        guard let vpn = appState.vpnManager else {
            error = "VPN manager not available"
            isLoading = false
            return
        }
        
        isLoading = true
        error = nil
        
        do {
            let resp = try await vpn.callLocalAPI(method: "GET", endpoint: "/localapi/v0/tka/status")
            
            guard resp.statusCode == 200,
                  let bodyB64 = resp.bodyBase64,
                  let bodyData = Data(base64Encoded: bodyB64) else {
                // 404 or other means TKA not available
                lockStatus = nil
                isLoading = false
                return
            }
            
            let status = try JSONDecoder().decode(TKAStatusResponse.self, from: bodyData)
            lockStatus = TailnetLockStatus(from: status)
            isLoading = false
        } catch {
            self.error = "Failed to load status: \(error.localizedDescription)"
            isLoading = false
        }
    }
    
    private func signNode(url: String) {
        guard let vpn = appState.vpnManager else { return }
        
        isSigning = true
        
        Task {
            do {
                let body = try JSONEncoder().encode(["url": url])
                let resp = try await vpn.callLocalAPI(method: "POST", endpoint: "/localapi/v0/tka/sign", body: body)
                
                await MainActor.run {
                    isSigning = false
                    if resp.statusCode == 200 {
                        // Success
                    } else {
                        appState.lastError = "Signing failed (status \(resp.statusCode))"
                    }
                }
            } catch {
                await MainActor.run {
                    isSigning = false
                    appState.lastError = "Signing failed: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func truncateKey(_ key: String) -> String {
        if key.count > 24 {
            return String(key.prefix(12)) + "..." + String(key.suffix(8))
        }
        return key
    }
}

/// Copyable row with tap to copy functionality.
struct CopyableRow: View {
    let label: String
    let value: String
    let fullValue: String
    @State private var showCopied: Bool = false
    
    var body: some View {
        Button {
            UIPasteboard.general.string = fullValue
            showCopied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                showCopied = false
            }
        } label: {
            HStack {
                Text(label)
                    .foregroundColor(.secondary)
                Spacer()
                if showCopied {
                    Text("Copied!")
                        .font(.caption)
                        .foregroundColor(.green)
                } else {
                    Text(value)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.primary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// View for entering a sign URL.
struct SignURLView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var url: String = ""
    
    var onSign: (String) -> Void
    
    var body: some View {
        Form {
            Section {
                TextField("Sign URL", text: $url)
                    .textContentType(.URL)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
            } header: {
                Text("Sign URL")
            } footer: {
                Text("Enter the signing URL from the node that needs to be signed. URLs typically start with 'tailscale://sign/'.")
            }
            
            Section {
                Button {
                    onSign(url)
                } label: {
                    HStack {
                        Spacer()
                        Text("Sign Node")
                        Spacer()
                    }
                }
                .disabled(url.isEmpty)
            }
        }
        .navigationTitle("Sign via URL")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
        }
    }
}

// MARK: - Models

/// Response from /localapi/v0/tka/status
struct TKAStatusResponse: Codable {
    let Enabled: Bool?
    let Head: String?
    let PublicKey: String?
    let NodeKey: String?
    let NodeKeySigned: Bool?
    let IsSigningKey: Bool?
    let TrustedKeys: [String]?
}

/// Parsed Tailnet Lock status.
struct TailnetLockStatus {
    let enabled: Bool
    let head: String?
    let publicKey: String?
    let nodeKey: String?
    let nodeKeySigned: Bool
    let isSigningKey: Bool
    let trustedKeys: [String]
    
    init(from response: TKAStatusResponse) {
        self.enabled = response.Enabled ?? false
        self.head = response.Head
        self.publicKey = response.PublicKey
        self.nodeKey = response.NodeKey
        self.nodeKeySigned = response.NodeKeySigned ?? false
        self.isSigningKey = response.IsSigningKey ?? false
        self.trustedKeys = response.TrustedKeys ?? []
    }
}

#Preview {
    NavigationView {
        TailnetLockView()
            .environmentObject(AppState())
    }
}
