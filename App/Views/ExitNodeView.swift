import SwiftUI

/// Exit Node picker view.
/// Allows users to select an exit node from the list of available nodes.
struct ExitNodeView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    
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
            peer.displayName.localizedCaseInsensitiveContains(searchText) ||
            peer.addresses.contains { $0.contains(searchText) }
        }
    }
    
    /// Currently selected exit node ID.
    private var currentExitNodeID: String? {
        appState.prefs?.ExitNodeID
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
                        Button("Stop") {
                            appState.clearExitNode()
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
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
            if currentExitNode != nil {
                Section {
                    Toggle("Allow LAN Access", isOn: Binding(
                        get: { appState.prefs?.ExitNodeAllowLANAccess ?? false },
                        set: { appState.setExitNodeAllowLANAccess($0) }
                    ))
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
                            Text("To use an exit node, a device on your network must advertise itself as one. Configure exit nodes in the Tailscale admin console.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 8)
                    } else {
                        Text("No matching exit nodes")
                            .foregroundColor(.secondary)
                    }
                } else {
                    ForEach(filteredExitNodes) { peer in
                        ExitNodeRow(
                            peer: peer,
                            isSelected: peer.id == currentExitNodeID,
                            onSelect: {
                                appState.setExitNode(peer)
                                dismiss()
                            }
                        )
                    }
                }
            } header: {
                Text("Available Exit Nodes")
            }
            
            // Note: iOS does not support running as an exit node.
            // iOS devices can consume exit nodes, but do not advertise as exit nodes here.
        }
        .searchable(text: $searchText, prompt: "Search exit nodes")
        .navigationTitle("Exit Node")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Row displaying an exit node option.
struct ExitNodeRow: View {
    let peer: PeerNode
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(peer.online ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)
                        Text(peer.displayName)
                            .font(.body)
                            .foregroundColor(.primary)
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
                
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!peer.online)
        .opacity(peer.online ? 1.0 : 0.5)
    }
}

// Note: RunAsExitNodeView removed - iOS does not support running as an exit node.
// iOS devices can consume exit nodes, but do not advertise as exit nodes here.
// See: https://tailscale.com/kb/1103/exit-nodes

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
