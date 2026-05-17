import SwiftUI

/// Main view displayed when logged in (Stopped / Starting / Running).
struct MainView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var vpnManager: VPNManager
    @State private var showTaildropPrompt = false
    @State private var openTaildropFromPrompt = false
    @State private var promptedTaildropRevision = 0

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

    private var connectionTitle: String {
        if let pending = appState.pendingWantRunning {
            return pending ? "Connecting" : "Disconnecting"
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
                if vpnIsActive {
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
                        NavigationLink(destination: PeerDetailView(peer: peer)) {
                            PeerRow(peer: peer, appState: appState)
                        }
                    }
                }
            }
            .navigationTitle("AwgScale")
            .background(
                NavigationLink(destination: TaildropView(), isActive: $openTaildropFromPrompt) {
                    EmptyView()
                }
                .hidden()
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

    private var hasAwgConfig: Bool {
        appState.peerHasAwgConfig(peer)
    }

    private var isSyncing: Bool {
        appState.awgSyncInProgress == peer.displayName
    }

    var body: some View {
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

            if !peer.isCurrentDevice {
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
        }
        .padding(.vertical, 2)
    }
}
