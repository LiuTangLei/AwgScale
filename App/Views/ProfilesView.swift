import SwiftUI

/// Multi-profile management view.
/// Allows switching between different Tailscale accounts/profiles.
struct ProfilesView: View {
    @EnvironmentObject var appState: AppState
    @State private var profiles: [LoginProfile] = []
    @State private var isLoading: Bool = true
    @State private var error: String?
    @State private var showingAddProfile: Bool = false
    @State private var showingSwitchConfirmation: Bool = false
    @State private var profileToSwitch: LoginProfile?
    @State private var isSwitching: Bool = false
    
    var body: some View {
        List {
            if isLoading {
                Section {
                    HStack {
                        ProgressView()
                            .padding(.trailing, 8)
                        Text("Loading profiles...")
                            .foregroundColor(.secondary)
                    }
                }
            } else if let error = error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundColor(.red)
                }
            } else {
                // Current profile
                if let current = appState.currentProfile {
                    Section {
                        ProfileRow(profile: current, isCurrent: true)
                    } header: {
                        Text("Current Profile")
                    }
                }
                
                // Other profiles
                let otherProfiles = profiles.filter { $0.ID != appState.currentProfile?.ID }
                if !otherProfiles.isEmpty {
                    Section {
                        ForEach(otherProfiles) { profile in
                            Button {
                                profileToSwitch = profile
                                showingSwitchConfirmation = true
                            } label: {
                                ProfileRow(profile: profile, isCurrent: false)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    deleteProfile(profile)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        Text("Other Profiles")
                    } footer: {
                        Text("Tap a profile to switch. Swipe left to delete.")
                    }
                }
                
                // Add profile
                Section {
                    Button {
                        showingAddProfile = true
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(.green)
                            Text("Add Profile")
                        }
                    }
                }
            }
            
            // Info
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text("Profiles let you use multiple Tailscale accounts on this device.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } icon: {
                        Image(systemName: "info.circle")
                            .foregroundColor(.blue)
                    }
                    
                    Label {
                        Text("Switching profiles will disconnect and reconnect the VPN.")
                            .font(.caption)
                            .foregroundColor(.orange)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Profiles")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await loadProfiles()
        }
        .onAppear {
            Task {
                await loadProfiles()
            }
        }
        .sheet(isPresented: $showingAddProfile) {
            NavigationView {
                AddProfileView(onComplete: {
                    showingAddProfile = false
                    Task { await loadProfiles() }
                })
            }
        }
        .alert("Switch Profile?", isPresented: $showingSwitchConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Switch") {
                if let profile = profileToSwitch {
                    switchToProfile(profile)
                }
            }
        } message: {
            if let profile = profileToSwitch {
                Text("Switch to \(profile.name)? This will disconnect the current VPN session.")
            }
        }
        .overlay {
            if isSwitching {
                ZStack {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Switching profile...")
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
    private func loadProfiles() async {
        guard let vpn = appState.vpnManager else {
            error = "VPN manager not available"
            isLoading = false
            return
        }
        
        isLoading = true
        error = nil
        
        do {
            let endpoint = "/localapi/v0/profiles/"
            let resp = try await vpn.callLocalAPI(method: "GET", endpoint: endpoint)
            profiles = try resp.decodedBody([LoginProfile].self, endpoint: endpoint)
            isLoading = false
        } catch {
            self.error = "Failed to load profiles: \(error.localizedDescription)"
            isLoading = false
        }
    }
    
    private func switchToProfile(_ profile: LoginProfile) {
        guard !isSwitching else { return }  // Prevent race condition
        guard let vpn = appState.vpnManager else { return }
        
        isSwitching = true
        
        Task {
            do {
                // First disconnect
                vpn.disconnect()
                try await Task.sleep(nanoseconds: 500_000_000)
                
                // Switch profile
                let endpoint = "/localapi/v0/profiles/\(profile.ID)"
                let resp = try await vpn.callLocalAPI(method: "POST", endpoint: endpoint)
                try resp.requireSuccess(endpoint: endpoint)
                
                // Wait and reconnect
                try await Task.sleep(nanoseconds: 1_000_000_000)
                vpn.connect()
                
                await MainActor.run {
                    isSwitching = false
                    appState.fetchCurrentProfile()
                }
            } catch {
                await MainActor.run {
                    isSwitching = false
                    appState.lastError = "Failed to switch profile: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func deleteProfile(_ profile: LoginProfile) {
        guard let vpn = appState.vpnManager else { return }
        
        Task {
            do {
                let endpoint = "/localapi/v0/profiles/\(profile.ID)"
                let resp = try await vpn.callLocalAPI(method: "DELETE", endpoint: endpoint)
                try resp.requireSuccess(endpoint: endpoint)
                await loadProfiles()
            } catch {
                await MainActor.run {
                    appState.lastError = "Failed to delete profile: \(error.localizedDescription)"
                }
            }
        }
    }
}

/// Row displaying a single profile.
struct ProfileRow: View {
    let profile: LoginProfile
    let isCurrent: Bool
    
    var body: some View {
        HStack {
            // Avatar placeholder
            Circle()
                .fill(Color.accentColor.opacity(0.2))
                .frame(width: 40, height: 40)
                .overlay {
                    Text(String(profile.name.prefix(1)).uppercased())
                        .font(.headline)
                        .foregroundColor(.accentColor)
                }
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(profile.name)
                        .font(.body)
                        .foregroundColor(.primary)
                    
                    if isCurrent {
                        Text("Active")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.2))
                            .foregroundColor(.green)
                            .cornerRadius(4)
                    }
                }
                
                if let userProfile = profile.UserProfile {
                    Text(userProfile.LoginName ?? userProfile.DisplayName ?? "")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                if !profile.controlURL.isEmpty && profile.controlURL != "https://controlplane.tailscale.com" {
                    Text(profile.controlURL)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            if isCurrent {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            }
        }
        .padding(.vertical, 4)
    }
}

/// View for adding a new profile via auth key.
struct AddProfileView: View {
    @EnvironmentObject var appState: AppState
    @State private var authKey: String = ""
    @State private var controlURL: String = ""
    @State private var useCustomServer: Bool = false
    @State private var isAdding: Bool = false
    @State private var error: String?
    
    var onComplete: () -> Void
    
    var body: some View {
        Form {
            Section {
                Toggle("Use Custom Control Server", isOn: $useCustomServer)
                
                if useCustomServer {
                    TextField("Control Server URL", text: $controlURL)
                        .textContentType(.URL)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                }
            }
            
            Section {
                SecureField("Auth Key", text: $authKey)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
            } header: {
                Text("Authentication")
            } footer: {
                Text("Enter an auth key from the Tailscale admin console. The key should start with 'tskey-auth-'.")
            }
            
            if let error = error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundColor(.red)
                }
            }
            
            Section {
                Button {
                    addProfile()
                } label: {
                    HStack {
                        Spacer()
                        if isAdding {
                            ProgressView()
                                .padding(.trailing, 8)
                            Text("Adding...")
                        } else {
                            Text("Add Profile")
                        }
                        Spacer()
                    }
                }
                .disabled(authKey.isEmpty || isAdding)
            }
        }
        .navigationTitle("Add Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    onComplete()
                }
            }
        }
    }
    
    private func addProfile() {
        guard let vpn = appState.vpnManager else {
            error = "VPN manager not available"
            return
        }
        
        isAdding = true
        error = nil
        
        Task {
            do {
                // Create new profile
                let _ = try await vpn.callLocalAPI(method: "POST", endpoint: "/localapi/v0/profiles/new")
                
                // Set control URL if custom
                if useCustomServer && !controlURL.isEmpty {
                    let prefs = MaskedPrefs.setControlURL(controlURL)
                    let body = try JSONEncoder().encode(prefs)
                    let _ = try await vpn.callLocalAPI(method: "PATCH", endpoint: "/localapi/v0/prefs", body: body)
                }
                
                // Login with auth key
                let loginBody = try JSONEncoder().encode(["authKey": authKey])
                let _ = try await vpn.callLocalAPI(method: "POST", endpoint: "/localapi/v0/login", body: loginBody)
                
                await MainActor.run {
                    isAdding = false
                    onComplete()
                }
            } catch {
                await MainActor.run {
                    self.error = "Failed to add profile: \(error.localizedDescription)"
                    isAdding = false
                }
            }
        }
    }
}

#Preview {
    NavigationView {
        ProfilesView()
            .environmentObject(AppState())
    }
}
