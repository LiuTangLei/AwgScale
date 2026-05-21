import SwiftUI

/// Main view displayed when logged in (Stopped / Starting / Running).
struct MainView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var vpnManager: VPNManager
    @State private var showTaildropPrompt = false
    @State private var openTaildropFromPrompt = false
    @State private var promptedTaildropRevision = 0
    @State private var selectedPeerID: String?

    /// Currently selected exit node (if any).
    private var currentExitNode: PeerNode? {
        guard let exitID = appState.effectiveExitNodeID, !exitID.isEmpty else { return nil }
        return appState.peers.first { $0.id == exitID }
    }

    private var vpnIsActive: Bool {
        appState.effectiveVPNIsActive(systemActive: vpnManager.isTunnelActive)
    }

    private var visiblePeers: [PeerNode] {
        appState.peers.filter { !$0.isMullvadNode }
    }

    private var selectedPeer: PeerNode? {
        guard let selectedPeerID else { return nil }
        return appState.peers.first { $0.id == selectedPeerID }
    }

    private var awgScanTaskID: String {
        let peerIDs = visiblePeers.map(\.id).joined(separator: ",")
        return "\(appState.usesVPNPermission)-\(vpnIsActive)-\(appState.ipnState.rawValue)-\(peerIDs)"
    }

    private var connectionTitle: String {
        if let pending = appState.pendingWantRunning {
            return pending ? "Connecting" : "Disconnecting"
        }

        if !appState.usesVPNPermission {
            switch appState.ipnState {
            case .running:
                return "Connected in App"
            case .starting:
                return "Connecting"
            default:
                return "Disconnected"
            }
        }

        switch vpnManager.vpnStatus {
        case .connected:
            return "Connected"
        case .connecting, .reasserting:
            return "Connecting"
        default:
            return "Disconnected"
        }
    }

    var body: some View {
        NavigationView {
            List {
                // Connection toggle
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(connectionTitle)
                                .font(.headline)
                            if let selfNode = appState.selfNode {
                                Text(selfNode.addresses.first ?? "")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        if appState.pendingWantRunning != nil {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                        Toggle("", isOn: Binding(
                            get: { vpnIsActive },
                            set: { enabled in
                                appState.setWantRunning(enabled)
                            }
                        ))
                        .labelsHidden()
                        .disabled(appState.pendingWantRunning != nil)
                    }

                    if vpnIsActive {
                        NavigationLink(destination: HealthView()) {
                            HStack {
                                Image(systemName: "heart.text.square")
                                    .foregroundColor(.accentColor)
                                    .frame(width: 24)
                                Text("Health")
                                Spacer()
                                HealthBadge(health: appState.health)
                            }
                        }
                    }
                }

                // Exit Node section
                if appState.usesVPNPermission, vpnIsActive {
                    Section {
                        NavigationLink(destination: ExitNodeView()) {
                            HStack {
                                Image(systemName: "globe")
                                    .foregroundColor(.accentColor)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Exit Node")
                                        .font(.body)
                                    if let exitNode = currentExitNode {
                                        HStack(spacing: 4) {
                                            Circle()
                                                .fill(exitNode.online ? Color.green : Color.gray)
                                                .frame(width: 6, height: 6)
                                            Text(exitNode.displayName)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    } else {
                                        Text("None")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                            }
                        }
                    }
                } else if !appState.usesVPNPermission {
                    Section {
                        NavigationLink(destination: InAppToolsView()) {
                            HStack {
                                Image(systemName: "square.grid.2x2")
                                    .foregroundColor(.accentColor)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Built-in Apps")
                                        .font(.body)
                                    Text(vpnIsActive ? "Browser and Terminal" : "Connect to use app-only tools")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .opacity(vpnIsActive ? 1 : 0.45)
                    }
                }

                // Error display
                if let error = appState.lastError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                    }
                }

                // AWG status toast
                if let awgMessage = appState.awgStatusMessage {
                    Section {
                        HStack {
                            Image(systemName: "shield.checkered")
                                .foregroundColor(.orange)
                            Text(awgMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button {
                                appState.clearAwgStatusMessage()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                                    .imageScale(.small)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Peer list
                Section("Devices") {
                    if visiblePeers.isEmpty {
                        Text("No other devices found")
                            .foregroundColor(.secondary)
                    }
                    ForEach(visiblePeers, id: \.id) { peer in
                        PeerRow(peer: peer, appState: appState) {
                            selectedPeerID = peer.id
                        }
                    }
                }
            }
            .navigationTitle("AwgScale")
            .background(
                Group {
                    NavigationLink(destination: TaildropView(), isActive: $openTaildropFromPrompt) {
                        EmptyView()
                    }
                    .hidden()

                    NavigationLink(isActive: Binding(
                        get: { selectedPeerID != nil },
                        set: { isActive in
                            if !isActive {
                                selectedPeerID = nil
                            }
                        }
                    )) {
                        if let selectedPeer {
                            PeerDetailView(peer: selectedPeer)
                        } else {
                            EmptyView()
                        }
                    } label: {
                        EmptyView()
                    }
                    .hidden()
                }
            )
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink(destination: SettingsView()) {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .onAppear {
                presentTaildropPromptIfNeeded()
            }
            .task(id: awgScanTaskID) {
                appState.loadAwgStatusIfNeeded()
            }
            .onChange(of: appState.taildropInboxRevision) { _ in
                presentTaildropPromptIfNeeded()
            }
            .alert("Taildrop File Received", isPresented: $showTaildropPrompt) {
                Button("View Files") {
                    openTaildropFromPrompt = true
                }
                Button("Later", role: .cancel) {}
            } message: {
                Text(appState.taildropPromptMessage)
            }
        }
    }

    private func presentTaildropPromptIfNeeded() {
        let revision = appState.taildropInboxRevision
        guard revision > 0, revision != promptedTaildropRevision else { return }
        guard revision > appState.taildropPromptedInboxRevision else { return }
        promptedTaildropRevision = revision
        appState.markTaildropPromptPresented(revision: revision)
        showTaildropPrompt = true
    }
}

struct PeerRow: View {
    let peer: PeerNode
    @ObservedObject var appState: AppState
    let openDetails: () -> Void

    private var hasAwgConfig: Bool {
        appState.peerHasAwgConfig(peer)
    }

    private var isSyncing: Bool {
        appState.awgSyncInProgress == peer.displayName
    }

    var body: some View {
        HStack {
            Button(action: openDetails) {
                HStack {
                    Circle()
                        .fill(peer.online ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(peer.displayName)
                                .font(.body)
                            if peer.isCurrentDevice {
                                Text("This device")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.15))
                                    .cornerRadius(4)
                            }
                            if hasAwgConfig {
                                Text("\u{2605}")
                                    .font(.subheadline)
                                    .foregroundColor(Color(red: 1.0, green: 0.84, blue: 0.0)) // Gold
                            }
                        }
                        Text(peer.addresses.first ?? "")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

            if !peer.isCurrentDevice && hasAwgConfig {
                Button {
                    appState.syncAwgConfigFromPeer(peer)
                } label: {
                    if isSyncing {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Text("Sync")
                            .font(.caption)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                  .disabled(isSyncing || !peer.online)
            }

            if let os = peer.os, !os.isEmpty {
                Text(os)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Button(action: openDetails) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }
}
