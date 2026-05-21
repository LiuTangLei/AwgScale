import SwiftUI

/// Login view displayed when ipn.State == NeedsLogin.
struct LoginView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingCustomServerLogin = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "network")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)

            Text("AwgScale")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Sign in to connect to your tailnet")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(
                    get: { appState.usesVPNPermission },
                    set: { appState.setUsesVPNPermission($0) }
                )) {
                    HStack {
                        Text("Enable VPN Permission")
                            .font(.headline)
                        if appState.isSwitchingNetworkMode {
                            Spacer()
                            ProgressView()
                        }
                    }
                }

                Text(appState.usesVPNPermission ? "System-wide mode lets every app use the tailnet." : "App-only mode keeps tailnet access inside AwgScale.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(14)
            .background(Color.secondary.opacity(0.10))
            .cornerRadius(12)
            .padding(.horizontal, 32)
            .disabled(appState.isLoggingIn || appState.isSwitchingNetworkMode)

            Button(action: {
                appState.startLogin()
            }) {
                Text("Sign In")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .padding(.horizontal, 32)
            .disabled(appState.isLoggingIn)

            Button {
                showingCustomServerLogin = true
            } label: {
                Text("Use Headscale or a custom server")
                    .font(.footnote.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
            .disabled(appState.isLoggingIn)
            .sheet(isPresented: $showingCustomServerLogin) {
                CustomServerLoginView { controlURL in
                    showingCustomServerLogin = false
                    appState.startLogin(controlURL: controlURL)
                }
            }

            if appState.isLoggingIn {
                VStack(spacing: 10) {
                    ProgressView("Signing in...")
                    Button("Cancel") {
                        appState.cancelLogin()
                    }
                    .font(.footnote)
                    .foregroundColor(.secondary)
                }
            }

            if let error = appState.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal, 32)
            }

            Spacer()
        }
    }
}

private struct CustomServerLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var controlURL = ""
    @State private var validationError: String?

    let onContinue: (String) -> Void

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("https://headscale.example.com", text: $controlURL)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                } header: {
                    Text("Control Server")
                } footer: {
                    Text("Enter the URL for your Headscale or compatible control server.")
                }

                if let validationError = validationError {
                    Section {
                        Label(validationError, systemImage: "exclamationmark.triangle")
                            .foregroundColor(.red)
                    }
                }

                Section {
                    Button {
                        submit()
                    } label: {
                        HStack {
                            Spacer()
                            Text("Continue")
                            Spacer()
                        }
                    }
                    .disabled(controlURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Custom Server")
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

    private func submit() {
        guard let normalizedURL = normalizedControlURL() else {
            validationError = "Enter a valid http or https URL."
            return
        }

        validationError = nil
        onContinue(normalizedURL)
    }

    private func normalizedControlURL() -> String? {
        let trimmedURL = controlURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return nil }

        let urlWithScheme: String
        if trimmedURL.contains("://") {
            urlWithScheme = trimmedURL
        } else {
            urlWithScheme = "https://\(trimmedURL)"
        }

        guard let components = URLComponents(string: urlWithScheme),
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              components.host?.isEmpty == false else {
            return nil
        }

        return components.url?.absoluteString
    }
}
