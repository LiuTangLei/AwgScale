import NetworkExtension
import SwiftUI

struct TaildropShareView: View {
    let extensionContext: NSExtensionContext?

    @StateObject private var vpnManager = VPNManager()
    @State private var files: [URL] = []
    @State private var targets: [PeerNode] = []
    @State private var isLoading = true
    @State private var loadingMessage = "Loading share..."
    @State private var activePeerID: String?
    @State private var peerSendStates: [String: SharePeerSendState] = [:]
    @State private var error: String?
    @State private var canOpenApp = false
    @State private var openAppButtonTitle = "Open AwgScale"

    var body: some View {
        NavigationView {
            List {
                if isLoading {
                    Section {
                        HStack {
                            ProgressView()
                                .padding(.trailing, 8)
                            Text(loadingMessage)
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    Section("Files") {
                        ForEach(files, id: \.absoluteString) { file in
                            HStack(spacing: 12) {
                                Image(systemName: "doc")
                                    .foregroundColor(.accentColor)
                                Text(file.lastPathComponent)
                                    .lineLimit(2)
                            }
                        }
                    }

                    Section("Send To") {
                        if targets.isEmpty {
                            Text("No Taildrop-capable devices available")
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(targets) { peer in
                                Button {
                                    send(to: peer)
                                } label: {
                                    SharePeerRow(peer: peer, state: peerSendStates[peer.id] ?? .idle)
                                }
                                .disabled(activePeerID != nil)
                            }
                        }
                    }
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundColor(.red)
                        if canOpenApp {
                            Button {
                                openContainingApp()
                            } label: {
                                Label(openAppButtonTitle, systemImage: "arrow.up.forward.app")
                            }
                        } else {
                            Button("Retry") {
                                Task { await reloadTargets() }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Send with AwgScale")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        finish()
                    }
                    .disabled(activePeerID != nil)
                }
            }
        }
        .task {
            await loadShare()
        }
    }

    @MainActor
    private func loadShare() async {
        guard isLoading else { return }
        error = nil
        canOpenApp = false
        loadingMessage = "Loading shared files..."

        do {
            files = try await ShareInputFileLoader.copyInputFiles(from: extensionContext)
            targets = try await loadTargetsWhenReady()
        } catch {
            present(error)
        }

        isLoading = false
    }

    @MainActor
    private func reloadTargets() async {
        isLoading = true
        error = nil
        canOpenApp = false
        loadingMessage = "Looking for devices..."
        do {
            targets = try await loadTargetsWhenReady()
        } catch {
            present(error)
        }
        isLoading = false
    }

    @MainActor
    private func present(_ error: Error) {
        if let shareError = error as? ShareInputError {
            self.error = shareError.localizedDescription
            canOpenApp = shareError.opensContainingApp
            openAppButtonTitle = shareError.recoveryButtonTitle ?? "Open AwgScale"
        } else {
            self.error = error.localizedDescription
            canOpenApp = false
            openAppButtonTitle = "Open AwgScale"
        }
    }

    @MainActor
    private func loadTargetsWhenReady() async throws -> [PeerNode] {
        try await ensureVPNReadyForShare()

        let deadline = Date().addingTimeInterval(45)
        var lastError: Error?

        while Date() < deadline {
            try Task.checkCancellation()
            loadingMessage = "Loading Taildrop devices..."

            do {
                let loadedTargets = try await TaildropSendService.loadTargets(vpn: vpnManager)
                if !loadedTargets.isEmpty {
                    return loadedTargets
                }
                lastError = nil
                loadingMessage = "Waiting for Taildrop devices..."
            } catch {
                lastError = error
                loadingMessage = "Waiting for VPN backend..."
            }

            try await Task.sleep(nanoseconds: 1_000_000_000)
        }

        if let lastError {
            canOpenApp = true
            throw ShareInputError.backendUnavailable(lastError.localizedDescription)
        }
        return []
    }

    @MainActor
    private func ensureVPNReadyForShare() async throws {
        try requireSystemVPNModeForShare()

        loadingMessage = "Checking VPN..."
        let status = await vpnManager.refreshStatus()

        if status != .connected && status != .reasserting && status != .connecting,
           await vpnManager.requiresConfigurationInstall() {
            throw ShareInputError.vpnPermissionRequired
        }

        do {
            try await connectVPNAndSetWantRunningForShare()
        } catch let shareError as ShareInputError {
            throw shareError
        } catch {
            throw ShareInputError.vpnUnavailable(error.localizedDescription)
        }
    }

    @MainActor
    private func connectVPNAndSetWantRunningForShare() async throws {
        do {
            try await connectVPNAndSetWantRunningOnceForShare()
        } catch {
            guard shouldRetryVPNStartAfterShareFailure(error) else { throw error }
            vpnManager.disconnect()
            await waitForVPNStoppedForShare()
            try await Task.sleep(nanoseconds: 1_000_000_000)
            try await connectVPNAndSetWantRunningOnceForShare()
        }
    }

    @MainActor
    private func connectVPNAndSetWantRunningOnceForShare() async throws {
        try requireSystemVPNModeForShare()
        loadingMessage = "Starting VPN..."
        try await vpnManager.connectTunnel()

        loadingMessage = "Waiting for VPN backend..."
        if let readinessError = await waitForBackendReadyForShare() {
            throw classifyBackendReadinessError(readinessError)
        }

        do {
            try requireSystemVPNModeForShare()
        } catch {
            vpnManager.disconnect()
            throw error
        }

        loadingMessage = "Starting Tailscale..."
        try await LocalAPIClient.vpn(vpnManager).setWantRunning(true, timeout: 10000)

        loadingMessage = "Waiting for Tailscale..."
        if let runningError = await waitForBackendRunningForShare() {
            throw classifyBackendReadinessError(runningError)
        }
    }

    @MainActor
    private func requireSystemVPNModeForShare() throws {
        guard sharedVPNPermissionModeEnabled() else {
            throw ShareInputError.systemVPNModeRequired
        }
    }

    @MainActor
    private func waitForBackendReadyForShare() async -> String? {
        var lastError = vpnManager.lastError

        for _ in 0..<25 {
            let status = vpnManager.updateStatusFromConnection()
            if status == .connected || status == .reasserting {
                break
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        let deadline = Date().addingTimeInterval(35)

        while Date() < deadline {
            switch vpnManager.updateStatusFromConnection() {
            case .disconnected, .invalid:
                return "VPN tunnel stopped before LocalAPI became ready"
            case .disconnecting:
                return "VPN tunnel is disconnecting before LocalAPI became ready"
            default:
                break
            }

            if let extensionError = sharedDefaults?.string(forKey: IPCConstants.keyLastError), !extensionError.isEmpty {
                lastError = extensionError
            }

            do {
                let response = try await LocalAPIClient.vpn(vpnManager).statusResponse(timeout: 1000)
                if response.error == nil {
                    return nil
                }
                lastError = response.error
            } catch {
                lastError = error.localizedDescription
            }

            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        return lastError ?? "timed out waiting for LocalAPI"
    }

    @MainActor
    private func waitForBackendRunningForShare() async -> String? {
        let deadline = Date().addingTimeInterval(60)
        var lastState = "Starting"

        while Date() < deadline {
            if Task.isCancelled {
                return "cancelled while waiting for backend to run"
            }

            switch vpnManager.updateStatusFromConnection() {
            case .disconnected, .invalid:
                return "VPN tunnel stopped before backend reached Running"
            case .disconnecting:
                return "VPN tunnel is disconnecting before backend reached Running"
            default:
                break
            }

            do {
                let status = try await LocalAPIClient.vpn(vpnManager).statusObject(timeout: 1000)
                let backendState = status["BackendState"] as? String
                switch backendState {
                case "Running":
                    if statusHasNetworkMap(status) {
                        return nil
                    }
                    lastState = "Running without network map"
                    loadingMessage = "Waiting for Tailnet map..."
                case "NeedsLogin":
                    return "login is required"
                case "NeedsMachineAuth":
                    return "machine authorization is pending"
                case "Stopped", "NoState":
                    loadingMessage = "Starting Tailscale..."
                    try await LocalAPIClient.vpn(vpnManager).setWantRunning(true, timeout: 3000)
                default:
                    lastState = backendState ?? lastState
                    loadingMessage = "Waiting for Tailscale backend..."
                }
            } catch {
                lastState = error.localizedDescription
                loadingMessage = "Waiting for VPN backend..."
            }

            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        return "timed out waiting for backend to run; last state: \(lastState)"
    }

    private func statusHasNetworkMap(_ status: [String: Any]) -> Bool {
        if let selfStatus = status["Self"] as? [String: Any], !selfStatus.isEmpty {
            return true
        }
        if let peers = status["Peer"] as? [String: Any], !peers.isEmpty {
            return true
        }
        return false
    }

    private func classifyBackendReadinessError(_ message: String) -> ShareInputError {
        let lowercased = message.lowercased()
        if lowercased.contains("login is required") {
            return .loginRequired
        }
        if lowercased.contains("machine authorization") {
            return .machineAuthRequired
        }
        if lowercased.contains("permission") || lowercased.contains("configuration") {
            return .vpnPermissionRequired
        }
        return .backendUnavailable(message)
    }

    private func shouldRetryVPNStartAfterShareFailure(_ error: Error) -> Bool {
        let message: String
        if case ShareInputError.backendUnavailable(let detail) = error {
            message = detail
        } else if case VPNError.ipcTimeout = error {
            return true
        } else {
            message = error.localizedDescription
        }

        let lowercased = message.lowercased()
        if lowercased.contains("login is required") || lowercased.contains("machine authorization") {
            return false
        }
        return lowercased.contains("tunnel stopped") ||
            lowercased.contains("disconnecting") ||
            lowercased.contains("packet tunnel ipc") ||
            lowercased.contains("no active vpn session") ||
            lowercased.contains("timed out waiting for localapi") ||
            lowercased.contains("timed out waiting for backend")
    }

    @MainActor
    private func waitForVPNStoppedForShare() async {
        for _ in 0..<25 {
            let status = vpnManager.updateStatusFromConnection()
            if status != .connected && status != .connecting && status != .reasserting && status != .disconnecting {
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    @MainActor
    private func send(to peer: PeerNode) {
        guard !files.isEmpty else { return }
        activePeerID = peer.id
        peerSendStates[peer.id] = .sending(progress: 0, detail: "Starting...")
        error = nil

        Task {
            do {
                try await TaildropSendService.send(files: files, to: peer, vpn: vpnManager) { update in
                    peerSendStates[peer.id] = .sending(progress: update.progress, detail: update.detail)
                }
                peerSendStates[peer.id] = .sent
                activePeerID = nil
            } catch {
                peerSendStates[peer.id] = .failed(error.localizedDescription)
                activePeerID = nil
            }
        }
    }

    private func openContainingApp() {
        guard let url = URL(string: "awgscale://open") else { return }
        extensionContext?.open(url) { opened in
            Task { @MainActor in
                if opened {
                    finish()
                } else {
                    error = "AwgScale could not be opened. Open it from the Home Screen and try again."
                    canOpenApp = false
                }
            }
        }
    }

    private func finish() {
        cleanupSharedInputFiles()
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func cleanupSharedInputFiles() {
        guard let directory = files.first?.deletingLastPathComponent() else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}

private enum SharePeerSendState: Equatable {
    case idle
    case sending(progress: Double, detail: String?)
    case sent
    case failed(String)
}

private struct SharePeerRow: View {
    let peer: PeerNode
    let state: SharePeerSendState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: peerIcon)
                    .foregroundColor(statusColor)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(peer.displayName)
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                statusAccessory
            }

            if case .sending(let progress, let detail) = state {
                ProgressView(value: max(0, min(progress, 1)))
                    .tint(statusColor)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            } else if case .failed(let message) = state {
                Text(message)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        switch state {
        case .idle:
            return peer.os?.isEmpty == false ? peer.os! : "Ready"
        case .sending:
            return "Sending"
        case .sent:
            return "Sent"
        case .failed:
            return "Failed"
        }
    }

    private var statusColor: Color {
        switch state {
        case .idle: return .accentColor
        case .sending: return .blue
        case .sent: return .green
        case .failed: return .red
        }
    }

    private var peerIcon: String {
        switch peer.os?.lowercased() {
        case "windows": return "desktopcomputer"
        case "macos", "ios": return "laptopcomputer"
        case "android": return "apps.iphone"
        case "linux": return "terminal"
        default: return "desktopcomputer"
        }
    }

    @ViewBuilder
    private var statusAccessory: some View {
        switch state {
        case .idle:
            Image(systemName: "paperplane")
                .foregroundColor(.secondary)
        case .sending:
            ProgressView()
        case .sent:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
        }
    }
}
