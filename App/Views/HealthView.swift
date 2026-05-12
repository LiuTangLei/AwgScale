import SwiftUI

/// Health warnings detail view.
/// Displays all health warnings with severity levels and details.
struct HealthView: View {
    @EnvironmentObject var appState: AppState
    
    private var warnings: [(code: String, state: UnhealthyState)] {
        guard let health = appState.health,
              let warnings = health.Warnings else { return [] }
        return warnings.map { (code: $0.key, state: $0.value) }
            .sorted { severityOrder($0.state.Severity) < severityOrder($1.state.Severity) }
    }
    
    private var hasWarnings: Bool {
        !warnings.isEmpty
    }
    
    var body: some View {
        List {
            if hasWarnings {
                ForEach(warnings, id: \.code) { warning in
                    HealthWarningRow(code: warning.code, state: warning.state)
                }
            } else {
                Section {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.title)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("All Systems Healthy")
                                .font(.headline)
                            Text("No warnings or issues detected.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .navigationTitle("Health")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private func severityOrder(_ severity: String?) -> Int {
        switch severity?.lowercased() {
        case "high": return 0
        case "medium": return 1
        case "low": return 2
        default: return 3
        }
    }
}

/// Row displaying a single health warning.
struct HealthWarningRow: View {
    let code: String
    let state: UnhealthyState
    @State private var isExpanded: Bool = false
    
    private var severityColor: Color {
        switch state.Severity?.lowercased() {
        case "high": return .red
        case "medium": return .orange
        case "low": return .yellow
        default: return .gray
        }
    }
    
    private var severityIcon: String {
        switch state.Severity?.lowercased() {
        case "high": return "exclamationmark.triangle.fill"
        case "medium": return "exclamationmark.circle.fill"
        case "low": return "info.circle.fill"
        default: return "questionmark.circle"
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: severityIcon)
                        .foregroundColor(severityColor)
                        .font(.title3)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(state.Title ?? code)
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                        
                        HStack(spacing: 8) {
                            Text(state.Severity?.capitalized ?? "Unknown")
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(severityColor.opacity(0.2))
                                .foregroundColor(severityColor)
                                .cornerRadius(4)
                            
                            if state.ImpactsConnectivity == true {
                                Text("Impacts Connectivity")
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.red.opacity(0.2))
                                    .foregroundColor(.red)
                                    .cornerRadius(4)
                            }
                        }
                    }
                    
                    Spacer()
                    
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
            .buttonStyle(.plain)
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                        .padding(.vertical, 8)
                    
                    if let text = state.Text, !text.isEmpty {
                        Text(text)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    if let brokenSince = state.BrokenSince {
                        HStack {
                            Text("Since:")
                                .foregroundColor(.secondary)
                            Text(formatDate(brokenSince))
                        }
                        .font(.caption)
                    }
                    
                    if let warnableCode = state.WarnableCode, !warnableCode.isEmpty {
                        HStack {
                            Text("Code:")
                                .foregroundColor(.secondary)
                            Text(warnableCode)
                                .font(.system(.caption, design: .monospaced))
                        }
                        .font(.caption)
                    }
                }
                .padding(.leading, 36)
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 8)
    }
    
    private func formatDate(_ dateString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        guard let date = formatter.date(from: dateString) else {
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: dateString) else {
                return dateString
            }
            return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
        }
        
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }
}

/// Summary badge for health status in main view.
struct HealthBadge: View {
    let health: HealthState?
    
    private var warningCount: Int {
        health?.Warnings?.count ?? 0
    }
    
    private var highSeverityCount: Int {
        health?.Warnings?.values.filter { $0.Severity?.lowercased() == "high" }.count ?? 0
    }
    
    var body: some View {
        if warningCount > 0 {
            HStack(spacing: 4) {
                Image(systemName: highSeverityCount > 0 ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill")
                    .foregroundColor(highSeverityCount > 0 ? .red : .orange)
                Text("\(warningCount)")
                    .font(.caption)
                    .fontWeight(.medium)
            }
        } else {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        }
    }
}

#Preview("With Warnings") {
    NavigationView {
        HealthView()
            .environmentObject({
                let state = AppState()
                // Mock health data would be set here
                return state
            }())
    }
}

#Preview("Healthy") {
    NavigationView {
        HealthView()
            .environmentObject(AppState())
    }
}
