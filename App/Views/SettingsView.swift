import SwiftUI

/// Minimal settings view for MVP.
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var vpnManager: VPNManager

    var body: some View {
        List {
            Section("Account") {
                if let profile = appState.currentProfile {
                    HStack {
                        Text("User")
                        Spacer()
                        Text(profile.name).foregroundColor(.secondary)
                    }
                    if !profile.controlURL.isEmpty && profile.controlURL != "https://controlplane.tailscale.com" {
                        HStack {
                            Text("Control Server")
                            Spacer()
                            Text(profile.controlURL).foregroundColor(.secondary)
                        }
                    }
                }
                
                NavigationLink(destination: ProfilesView()) {
                    HStack {
                        Image(systemName: "person.2")
                            .foregroundColor(.accentColor)
                            .frame(width: 24)
                        Text("Manage Profiles")
                    }
                }
            }

            Section("About") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(appState.appVersion).foregroundColor(.secondary)
                }
            }

            Section("Network") {
                NavigationLink(destination: DNSSettingsView()) {
                    HStack {
                        Image(systemName: "network")
                            .foregroundColor(.accentColor)
                            .frame(width: 24)
                        Text("DNS Settings")
                    }
                }
                
                NavigationLink(destination: SubnetRoutesView()) {
                    HStack {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .foregroundColor(.accentColor)
                            .frame(width: 24)
                        Text("Subnet Routes")
                    }
                }

                NavigationLink(destination: AwgSettingsView()) {
                    HStack {
                        Image(systemName: "shield.checkered")
                            .foregroundColor(.accentColor)
                            .frame(width: 24)
                        Text("Amnezia-WG")
                    }
                }
            }

            Section("Security") {
                NavigationLink(destination: TailnetLockView()) {
                    HStack {
                        Image(systemName: "lock.shield")
                            .foregroundColor(.accentColor)
                            .frame(width: 24)
                        Text("Tailnet Lock")
                    }
                }
                
                NavigationLink(destination: MDMInfoView()) {
                    HStack {
                        Image(systemName: "building.2")
                            .foregroundColor(.accentColor)
                            .frame(width: 24)
                        Text("Device Management")
                    }
                }
            }

            Section("Diagnostics") {
                HStack {
                    Text("Amnezia-WG")
                    Spacer()
                    if appState.localAwgStatus {
                        HStack(spacing: 4) {
                            Text("\u{2605}")
                                .foregroundColor(Color(red: 1.0, green: 0.84, blue: 0.0))
                            Text("Enabled")
                                .foregroundColor(.green)
                        }
                        .font(.caption)
                    } else {
                        Text("Not configured")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }

                // AWG refresh button
                Button {
                    appState.refreshAwgStatus()
                } label: {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Refresh AWG Status")
                    }
                }
                
                NavigationLink(destination: BugReportView()) {
                    HStack {
                        Image(systemName: "ladybug")
                            .foregroundColor(.accentColor)
                            .frame(width: 24)
                        Text("Bug Report")
                    }
                }

                if let lastError = appState.lastError {
                    HStack {
                        Text("Last Error")
                        Spacer()
                        Text(lastError)
                            .foregroundColor(.red)
                            .font(.caption)
                            .lineLimit(2)
                    }
                }
            }
            
            Section("About") {
                NavigationLink(destination: AboutView()) {
                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundColor(.accentColor)
                            .frame(width: 24)
                        Text("About Tailscale")
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    appState.logout()
                } label: {
                    HStack {
                        Spacer()
                        Text("Sign Out")
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle("Settings")
    }
}

struct AwgSettingsView: View {
    @EnvironmentObject var appState: AppState

    @State private var jc = ""
    @State private var jMin = ""
    @State private var jMax = ""
    @State private var s1 = ""
    @State private var s2 = ""
    @State private var s3 = ""
    @State private var s4 = ""
    @State private var i1 = ""
    @State private var i2 = ""
    @State private var i3 = ""
    @State private var i4 = ""
    @State private var i5 = ""
    @State private var h1Min = ""
    @State private var h1Max = ""
    @State private var h2Min = ""
    @State private var h2Max = ""
    @State private var h3Min = ""
    @State private var h3Max = ""
    @State private var h4Min = ""
    @State private var h4Max = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?

    var body: some View {
        List {
            Section("Status") {
                HStack {
                    Text("Configuration")
                    Spacer()
                    if appState.localAwgStatus {
                        HStack(spacing: 4) {
                            Text("\u{2605}")
                                .foregroundColor(Color(red: 1.0, green: 0.84, blue: 0.0))
                            Text("Enabled")
                                .foregroundColor(.green)
                        }
                        .font(.caption)
                    } else {
                        Text("Not configured")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }

                if isLoading {
                    HStack {
                        ProgressView()
                            .padding(.trailing, 8)
                        Text("Loading...")
                            .foregroundColor(.secondary)
                    }
                }

                if let statusMessage {
                    Label(statusMessage, systemImage: "checkmark.circle")
                        .foregroundColor(.green)
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundColor(.red)
                }
            }

            Section("Packet Shape") {
                numericField("JC", text: $jc)
                numericField("JMin", text: $jMin)
                numericField("JMax", text: $jMax)
                numericField("S1", text: $s1)
                numericField("S2", text: $s2)
                numericField("S3", text: $s3)
                numericField("S4", text: $s4)
            }

            Section("Signature Packets") {
                stringField("I1", text: $i1)
                stringField("I2", text: $i2)
                stringField("I3", text: $i3)
                stringField("I4", text: $i4)
                stringField("I5", text: $i5)
            }

            Section("Magic Headers") {
                rangeField("H1", min: $h1Min, max: $h1Max)
                rangeField("H2", min: $h2Min, max: $h2Max)
                rangeField("H3", min: $h3Min, max: $h3Max)
                rangeField("H4", min: $h4Min, max: $h4Max)
            }

            Section {
                Button {
                    saveConfig()
                } label: {
                    HStack {
                        Spacer()
                        if isSaving {
                            ProgressView()
                                .padding(.trailing, 8)
                            Text("Saving...")
                        } else {
                            Text("Save AWG Config")
                        }
                        Spacer()
                    }
                }
                .disabled(isSaving || isLoading)

                Button(role: .destructive) {
                    clearConfig()
                } label: {
                    HStack {
                        Spacer()
                        Text("Clear AWG Config")
                        Spacer()
                    }
                }
                .disabled(isSaving || isLoading)
            }
        }
        .navigationTitle("Amnezia-WG")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await loadConfig()
        }
        .onAppear {
            Task {
                await loadConfig()
            }
        }
    }

    private func numericField(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", text: text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .font(.system(.body, design: .monospaced))
        }
    }

    private func stringField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .foregroundColor(.secondary)
            TextField("", text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
        }
        .padding(.vertical, 2)
    }

    private func rangeField(_ label: String, min: Binding<String>, max: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .foregroundColor(.secondary)
            HStack {
                TextField("min", text: min)
                    .keyboardType(.numberPad)
                    .font(.system(.body, design: .monospaced))
                TextField("max", text: max)
                    .keyboardType(.numberPad)
                    .font(.system(.body, design: .monospaced))
            }
        }
        .padding(.vertical, 2)
    }

    @MainActor
    private func loadConfig() async {
        isLoading = true
        errorMessage = nil
        await appState.refreshLocalAwgStatusNow(showMessages: false)
        loadFields(from: appState.currentAwgConfig)
        isLoading = false
    }

    private func saveConfig() {
        Task {
            await applyConfigFromFields()
        }
    }

    private func clearConfig() {
        clearFields()
        Task {
            await applyConfig(.empty)
        }
    }

    @MainActor
    private func applyConfigFromFields() async {
        do {
            let config = try buildConfig()
            await applyConfig(config)
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
        }
    }

    @MainActor
    private func applyConfig(_ config: AmneziaWGPrefs) async {
        isSaving = true
        errorMessage = nil
        statusMessage = nil

        do {
            try await appState.applyManualAwgConfig(config)
            loadFields(from: appState.currentAwgConfig)
            statusMessage = config.hasNonDefaultValues ? "Saved" : "Cleared"
        } catch {
            errorMessage = error.localizedDescription
        }

        isSaving = false
    }

    private func buildConfig() throws -> AmneziaWGPrefs {
        AmneziaWGPrefs(
            JC: try parseUInt16(jc, label: "JC"),
            JMin: try parseUInt16(jMin, label: "JMin"),
            JMax: try parseUInt16(jMax, label: "JMax"),
            S1: try parseUInt16(s1, label: "S1"),
            S2: try parseUInt16(s2, label: "S2"),
            S3: try parseUInt16(s3, label: "S3"),
            S4: try parseUInt16(s4, label: "S4"),
            I1: optionalString(i1),
            I2: optionalString(i2),
            I3: optionalString(i3),
            I4: optionalString(i4),
            I5: optionalString(i5),
            H1: try parseRange("H1", minText: h1Min, maxText: h1Max),
            H2: try parseRange("H2", minText: h2Min, maxText: h2Max),
            H3: try parseRange("H3", minText: h3Min, maxText: h3Max),
            H4: try parseRange("H4", minText: h4Min, maxText: h4Max)
        )
    }

    private func loadFields(from config: AmneziaWGPrefs?) {
        jc = text(config?.JC)
        jMin = text(config?.JMin)
        jMax = text(config?.JMax)
        s1 = text(config?.S1)
        s2 = text(config?.S2)
        s3 = text(config?.S3)
        s4 = text(config?.S4)
        i1 = config?.I1 ?? ""
        i2 = config?.I2 ?? ""
        i3 = config?.I3 ?? ""
        i4 = config?.I4 ?? ""
        i5 = config?.I5 ?? ""
        h1Min = text(config?.H1?.min)
        h1Max = text(config?.H1?.max)
        h2Min = text(config?.H2?.min)
        h2Max = text(config?.H2?.max)
        h3Min = text(config?.H3?.min)
        h3Max = text(config?.H3?.max)
        h4Min = text(config?.H4?.min)
        h4Max = text(config?.H4?.max)
    }

    private func clearFields() {
        loadFields(from: nil)
    }

    private func parseUInt16(_ value: String, label: String) throws -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let number = Int(trimmed), (0...65535).contains(number) else {
            throw AwgSettingsError("\(label) must be 0-65535")
        }
        return number == 0 ? nil : number
    }

    private func parseUInt32(_ value: String, label: String) throws -> Int64 {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = Int64(trimmed), (0...4_294_967_295).contains(number) else {
            throw AwgSettingsError("\(label) must be 0-4294967295")
        }
        return number
    }

    private func parseRange(_ label: String, minText: String, maxText: String) throws -> MagicHeaderRange? {
        let minTrimmed = minText.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxTrimmed = maxText.trimmingCharacters(in: .whitespacesAndNewlines)
        if minTrimmed.isEmpty && maxTrimmed.isEmpty { return nil }
        guard !minTrimmed.isEmpty, !maxTrimmed.isEmpty else {
            throw AwgSettingsError("\(label) requires min and max")
        }

        let minValue = try parseUInt32(minTrimmed, label: "\(label) min")
        let maxValue = try parseUInt32(maxTrimmed, label: "\(label) max")
        guard minValue <= maxValue else {
            throw AwgSettingsError("\(label) min must be <= max")
        }

        return (minValue == 0 && maxValue == 0) ? nil : MagicHeaderRange(min: minValue, max: maxValue)
    }

    private func optionalString(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func text(_ value: Int?) -> String {
        guard let value, value != 0 else { return "" }
        return String(value)
    }

    private func text(_ value: Int64?) -> String {
        guard let value, value != 0 else { return "" }
        return String(value)
    }
}

private struct AwgSettingsError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
