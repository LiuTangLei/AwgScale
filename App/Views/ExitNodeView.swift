import SwiftUI

/// Exit Node picker view.
/// Allows users to select an exit node from the list of available nodes.
struct ExitNodeView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    var showsAllowLANAccess = true
    
    @State private var searchText: String = ""
    
    /// Filter peers that can be used as exit nodes (online and marked as exit node capable).
    private var exitNodePeers: [PeerNode] {
        appState.peers.filter { peer in
            peer.isExitNode && !peer.isCurrentDevice
        }
    }
    
    /// Filtered exit nodes based on search text.
    private var filteredExitNodes: [PeerNode] {
        guard !searchText.isEmpty else { return exitNodePeers }
        return exitNodePeers.filter { peer in
            peer.exitNodeDisplayName.localizedCaseInsensitiveContains(searchText) ||
            peer.displayName.localizedCaseInsensitiveContains(searchText) ||
            peer.addresses.contains { $0.contains(searchText) }
        }
    }

    private var tailnetExitNodes: [PeerNode] {
        filteredExitNodes.filter { !$0.isMullvadNode }
    }

    private var mullvadExitNodes: [PeerNode] {
        filteredExitNodes.filter { $0.isMullvadNode }
    }
    
    /// Currently selected exit node ID.
    private var currentExitNodeID: String? {
        appState.effectiveExitNodeID
    }
    
    /// Currently selected exit node (if any).
    private var currentExitNode: PeerNode? {
        guard let exitID = currentExitNodeID, !exitID.isEmpty else { return nil }
        return appState.peers.first { $0.id == exitID }
    }
    
    var body: some View {
        List {
            // Current selection section
            Section {
                if let current = currentExitNode {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Currently using")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(current.displayName)
                                .font(.headline)
                            if let addr = current.addresses.first {
                                Text(addr)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        Button {
                            appState.clearExitNode()
                        } label: {
                            if appState.isUpdatingExitNode && appState.pendingExitNodeID == "" {
                                ProgressView()
                            } else {
                                Text("Stop")
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .disabled(appState.isUpdatingExitNode)
                    }
                } else {
                    HStack {
                        Image(systemName: "globe")
                            .foregroundColor(.secondary)
                        Text("No exit node selected")
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Exit Node")
            } footer: {
                Text("Route all internet traffic through the selected exit node.")
            }
            
            // Allow LAN access toggle
            if showsAllowLANAccess, currentExitNode != nil {
                Section {
                    Toggle("Allow LAN Access", isOn: Binding(
                        get: { appState.effectiveExitNodeAllowLANAccess },
                        set: { appState.setExitNodeAllowLANAccess($0) }
                    ))
                    .disabled(appState.isUpdatingExitNode)
                } footer: {
                    Text("Allow access to local network devices when using an exit node.")
                }
            }
            // Available exit nodes
            Section {
                if filteredExitNodes.isEmpty {
                    if exitNodePeers.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No exit nodes available")
                                .foregroundColor(.secondary)
                            Text("To use an exit node, another device must advertise itself as one. Configure exit nodes in your control plane admin console.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 8)
                    } else {
                        Text("No matching exit nodes")
                            .foregroundColor(.secondary)
                    }
                } else if tailnetExitNodes.isEmpty {
                    Text("No tailnet exit nodes match")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(tailnetExitNodes) { peer in
                        exitNodeRow(peer)
                    }
                }
            } header: {
                Text("Tailnet Exit Nodes")
            }

            if !mullvadExitNodes.isEmpty {
                Section {
                    ForEach(mullvadExitNodes) { peer in
                        exitNodeRow(peer)
                    }
                } header: {
                    Text("Mullvad Exit Nodes")
                }
            }
            
            // Note: iOS does not support running as an exit node.
            // iOS devices can consume exit nodes, but do not advertise as exit nodes here.
        }
        .searchable(text: $searchText, prompt: "Search exit nodes")
        .navigationTitle("Exit Node")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func exitNodeRow(_ peer: PeerNode) -> some View {
        ExitNodeRow(
            peer: peer,
            isSelected: peer.id == currentExitNodeID,
            isUpdating: appState.isUpdatingExitNode && appState.pendingExitNodeID == peer.id,
            isDisabled: appState.isUpdatingExitNode,
            onSelect: {
                appState.setExitNode(peer)
                dismiss()
            }
        )
    }
}

/// Row displaying an exit node option.
struct ExitNodeRow: View {
    let peer: PeerNode
    let isSelected: Bool
    let isUpdating: Bool
    let isDisabled: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(peer.online ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)
                        Text(peer.exitNodeDisplayName)
                            .font(.body)
                            .foregroundColor(.primary)
                    }
                    if peer.isMullvadNode && peer.exitNodeDisplayName != peer.displayName {
                        Text(peer.displayName)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if let addr = peer.addresses.first {
                        Text(addr)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if let os = peer.os {
                        Text(os)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                if isUpdating {
                    ProgressView()
                } else if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!peer.online || isDisabled)
        .opacity(peer.online ? 1.0 : 0.5)
    }
}

// Note: RunAsExitNodeView removed - iOS does not support running as an exit node.
// iOS devices can consume exit nodes, but do not advertise as exit nodes here.

/// Warning row component (kept for potential reuse).
struct WarningRow: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.orange)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

#Preview {
    NavigationView {
        ExitNodeView()
    }
}
