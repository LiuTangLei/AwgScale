import SwiftUI
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

/// Minimal settings view for MVP.
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var vpnManager: VPNManager

    private var awgStatusText: String {
        appState.localAwgStatus ? "Enabled" : "Not configured"
    }

    private var awgStatusColor: Color {
        appState.localAwgStatus ? .green : .secondary
    }

    private var modeSwitchDisabled: Bool {
        appState.pendingWantRunning != nil || appState.isSwitchingNetworkMode
    }

    var body: some View {
        List {
            Section("Account") {
                if let profile = appState.currentProfile {
                    HStack {
                        SettingsRowLabel(title: "User", systemImage: "person.crop.circle")
                        Spacer()
                        Text(profile.name).foregroundColor(.secondary)
                    }
                    if !profile.controlURL.isEmpty && profile.controlURL != "https://controlplane.tailscale.com" {
                        HStack {
                            SettingsRowLabel(title: "Control Server", systemImage: "server.rack")
                            Spacer()
                            Text(profile.controlURL).foregroundColor(.secondary)
                        }
                    }
                }
                
                NavigationLink(destination: ProfilesView()) {
                    SettingsRowLabel(title: "Manage Profiles", systemImage: "person.2")
                }
            }

              Section {
                  Toggle(isOn: Binding(
                      get: { appState.usesVPNPermission },
                      set: { appState.setUsesVPNPermission($0) }
                  )) {
                      HStack {
                          SettingsRowLabel(title: "Enable VPN Permission", systemImage: "shield.lefthalf.filled")
                          if appState.isSwitchingNetworkMode {
                              Spacer()
                              ProgressView()
                          }
                      }
                  }
                  .disabled(modeSwitchDisabled)
              } header: {
                  Text("Connection Mode")
              } footer: {
                  Text(appState.usesVPNPermission ? "System-wide VPN mode keeps the original behavior. Switching modes resets the current app/VPN network session but keeps the login." : "App-only mode keeps tailnet traffic inside AwgScale. Switching modes resets the current app/VPN network session but keeps the login.")
              }

            Section("Network") {
                  if appState.usesVPNPermission {
                      NavigationLink(destination: DNSSettingsView()) {
                          SettingsRowLabel(title: "DNS Settings", systemImage: "network")
                      }

                      NavigationLink(destination: SubnetRoutesView()) {
                          SettingsRowLabel(title: "Subnet Routes", systemImage: "network")
                      }
                  } else {
                      DisabledSettingsRow(title: "DNS Settings", systemImage: "network")
                      DisabledSettingsRow(title: "Subnet Routes", systemImage: "network")
                  }
            }

            Section("Files") {
                NavigationLink(destination: TaildropView()) {
                    HStack {
                        SettingsRowLabel(title: "Taildrop", systemImage: "arrow.up.arrow.down.circle")
                        Spacer()
                        if appState.taildropFilesWaiting {
                            Text("Files waiting")
                                .font(.caption)
                                .foregroundColor(.accentColor)
                        }
                    }
                }
            }

            Section("Amnezia-WG") {
                HStack {
                    SettingsRowLabel(title: "Status", systemImage: "shield.fill", color: .orange)
                    Spacer()
                    Text(awgStatusText)
                        .foregroundColor(awgStatusColor)
                        .font(.caption)
                }

                  NavigationLink(destination: AwgSettingsView()) {
                      SettingsRowLabel(title: "Configuration", systemImage: "slider.horizontal.3", color: .orange)
                  }

                Button {
                    appState.refreshAwgStatus()
                } label: {
                    HStack {
                        if appState.isAwgStatusRefreshing {
                            ProgressView()
                                .frame(width: 24)
                        } else {
                            SettingsIcon(systemImage: "arrow.clockwise", color: .orange)
                        }
                        Text(appState.isAwgStatusRefreshing ? "Refreshing AWG Status" : "Refresh AWG Status")
                    }
                }
                  .disabled(appState.isAwgStatusRefreshing)
            }

            Section("Security") {
                NavigationLink(destination: TailnetLockView()) {
                    SettingsRowLabel(title: "Tailnet Lock", systemImage: "lock.shield")
                }
                
                NavigationLink(destination: MDMInfoView()) {
                    SettingsRowLabel(title: "Device Management", systemImage: "building.2")
                }
            }

            Section("Diagnostics") {
                NavigationLink(destination: BugReportView()) {
                    SettingsRowLabel(title: "Bug Report", systemImage: "ladybug")
                }

                NavigationLink(destination: NotificationsSettingsView()) {
                    SettingsRowLabel(title: "Notifications", systemImage: "bell")
                }

                if let lastError = appState.lastError {
                    HStack {
                        SettingsRowLabel(title: "Last Error", systemImage: "exclamationmark.triangle", color: .red)
                        Spacer()
                        Text(lastError)
                            .foregroundColor(.red)
                            .font(.caption)
                            .lineLimit(2)
                    }
                }
            }
            
            Section("About") {
                HStack {
                    SettingsRowLabel(title: "Version", systemImage: "number.circle")
                    Spacer()
                    Text(appState.appVersion).foregroundColor(.secondary)
                }

                HStack {
                    SettingsRowLabel(title: "tailscale-awg", systemImage: "shippingbox")
                    Spacer()
                    Text(appState.tailscaleAwgVersion).foregroundColor(.secondary)
                }

                NavigationLink(destination: AboutView()) {
                    SettingsRowLabel(title: "About AwgScale", systemImage: "info.circle")
                }
            }

            Section {
                Button(role: .destructive) {
                    appState.logout()
                } label: {
                    HStack {
                        Spacer()
                        SettingsRowLabel(title: "Sign Out", systemImage: "rectangle.portrait.and.arrow.right", color: .red)
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle("Settings")
        .task {
            appState.loadAwgStatusIfNeeded()
        }
    }
}

private struct SettingsIcon: View {
    let systemImage: String
    var color: Color = .accentColor

    private var resolvedSystemImage: String {
        #if canImport(UIKit)
        UIImage(systemName: systemImage) == nil ? "circle" : systemImage
        #else
        systemImage
        #endif
    }

    var body: some View {
        Image(systemName: resolvedSystemImage)
            .foregroundColor(color)
            .frame(width: 24)
    }
}

private struct SettingsRowLabel: View {
    let title: String
    let systemImage: String
    var color: Color = .accentColor

    var body: some View {
        HStack {
            SettingsIcon(systemImage: systemImage, color: color)
            Text(title)
        }
    }
}

private struct DisabledSettingsRow: View {
    let title: String
    let systemImage: String
    var color: Color = .accentColor

    var body: some View {
        HStack {
            SettingsRowLabel(title: title, systemImage: systemImage, color: color)
            Spacer()
            Text("VPN required")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .foregroundColor(.secondary)
        .opacity(0.55)
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
    @State private var jsonText = ""

    var body: some View {
        List {
            Section("Status") {
                HStack {
                    SettingsRowLabel(title: "Configuration", systemImage: "shield.fill", color: .orange)
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

            Section("JSON") {
                TextEditor(text: $jsonText)
                    .frame(minHeight: 140)
                    .font(.system(.caption, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button {
                    pasteJSONFromClipboard()
                } label: {
                    SettingsRowLabel(title: "Paste JSON", systemImage: "doc.on.clipboard")
                }
                .disabled(isSaving || isLoading)

                Button {
                    applyJSONConfig()
                } label: {
                    SettingsRowLabel(title: "Apply JSON Config", systemImage: "curlybraces")
                }
                .disabled(isSaving || isLoading || jsonText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    copyCurrentJSON()
                } label: {
                    SettingsRowLabel(title: "Copy Current JSON", systemImage: "doc.on.doc")
                }
                .disabled(isSaving || isLoading)
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
        loadJSON(from: appState.currentAwgConfig)
        isLoading = false
    }

    private func saveConfig() {
        Task {
            await applyConfigFromFields()
        }
    }

    private func clearConfig() {
        clearFields()
        jsonText = ""
        Task {
            await applyConfig(.empty)
        }
    }

    private func pasteJSONFromClipboard() {
        #if canImport(UIKit)
        guard let clipboardText = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clipboardText.isEmpty else {
            statusMessage = nil
            errorMessage = "Clipboard is empty"
            return
        }
        jsonText = clipboardText
        statusMessage = "Pasted"
        errorMessage = nil
        #else
        errorMessage = "Clipboard is unavailable"
        statusMessage = nil
        #endif
    }

    private func applyJSONConfig() {
        Task {
            await applyJSONConfigFromText()
        }
    }

    private func copyCurrentJSON() {
        Task {
            await copyCurrentConfigJSON()
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
    private func applyJSONConfigFromText() async {
        do {
            let config = try decodeConfigJSON(jsonText)
            jsonText = try encodeConfigJSON(config)
            await applyConfig(config)
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
        }
    }

    @MainActor
    private func copyCurrentConfigJSON() async {
        if appState.currentAwgConfig == nil {
            await appState.refreshLocalAwgStatusNow(showMessages: false)
        }

        guard let config = appState.currentAwgConfig, config.hasNonDefaultValues else {
            statusMessage = nil
            errorMessage = "No AWG config to copy"
            return
        }

        do {
            let json = try encodeConfigJSON(config)
            jsonText = json
            #if canImport(UIKit)
            UIPasteboard.general.string = json
            statusMessage = "Copied"
            #else
            statusMessage = "Loaded current JSON"
            #endif
            errorMessage = nil
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
            loadJSON(from: appState.currentAwgConfig)
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

    private func decodeConfigJSON(_ text: String) throws -> AmneziaWGPrefs {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AwgSettingsError("JSON input is empty") }
        let data = Data(trimmed.utf8)
        let decoder = JSONDecoder()

        do {
            return try decoder.decode(AmneziaWGPrefs.self, from: data)
        } catch {
            if let wrapped = try? decoder.decode(AwgConfigJSONWrapper.self, from: data), let config = wrapped.AmneziaWG {
                return config
            }
            throw AwgSettingsError("Invalid JSON: \(error.localizedDescription)")
        }
    }

    private func encodeConfigJSON(_ config: AmneziaWGPrefs) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        return String(data: data, encoding: .utf8) ?? "{}"
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

    private func loadJSON(from config: AmneziaWGPrefs?) {
        guard let config, config.hasNonDefaultValues, let json = try? encodeConfigJSON(config) else {
            jsonText = ""
            return
        }
        jsonText = json
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

private struct AwgConfigJSONWrapper: Decodable {
        let AmneziaWG: AmneziaWGPrefs?
}

private struct AwgSettingsError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

private struct NotificationsSettingsView: View {
    @StateObject private var notifications = NotificationManager.shared

    private var statusText: String {
        switch notifications.authorizationStatus {
        case .notDetermined:
            return "Not Requested"
        case .denied:
            return "Off"
        case .authorized:
            return "On"
        case .provisional:
            return "Provisional"
        case .ephemeral:
            return "Temporary"
        @unknown default:
            return "Unknown"
        }
    }

    var body: some View {
        List {
            Section {
                HStack {
                    SettingsRowLabel(title: "Notification Permission", systemImage: "bell.badge")
                    Spacer()
                    Text(statusText)
                        .foregroundColor(notifications.isAuthorized ? .green : .secondary)
                }

                Button {
                    Task {
                        if notifications.authorizationStatus == .notDetermined {
                            _ = await notifications.requestAuthorization()
                        } else {
                            openAppNotificationSettings()
                        }
                        await notifications.checkAuthorizationStatus()
                    }
                } label: {
                    HStack {
                        SettingsIcon(systemImage: notifications.authorizationStatus == .notDetermined ? "checkmark.circle" : "gearshape", color: .accentColor)
                        Text(notifications.authorizationStatus == .notDetermined ? "Allow Notifications" : "Open System Settings")
                    }
                }
            } footer: {
                Text("Notifications are used for Taildrop files, key expiry reminders, and high-severity health warnings.")
            }

            Section {
                Button(role: .destructive) {
                    notifications.clearAllNotifications()
                } label: {
                    HStack {
                        SettingsIcon(systemImage: "xmark.circle", color: .red)
                        Text("Clear Notifications")
                    }
                }
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await notifications.checkAuthorizationStatus()
        }
    }

    private func openAppNotificationSettings() {
        #if canImport(UIKit)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #endif
    }
}
