import SwiftUI

/// Detailed view for a peer node.
/// Displays all available information about a device on the overlay network.
struct PeerDetailView: View {
    let peer: PeerNode
    @EnvironmentObject var appState: AppState
    @State private var showCopiedMessage: Bool = false
    @State private var copiedText: String = ""
    
    private var isExitNode: Bool {
        peer.isExitNode
    }
    
    private var isCurrentExitNode: Bool {
        guard let exitID = appState.effectiveExitNodeID else { return false }
        return peer.id == exitID
    }
    
    var body: some View {
        List {
            // Basic info section
            Section {
                InfoRow(label: "Name", value: peer.displayName) {
                    copyToClipboard(peer.displayName)
                }
                
                if let os = peer.os, !os.isEmpty {
                    InfoRow(label: "OS", value: os, icon: osIcon(for: os))
                }
                
                HStack {
                    Text("Status")
                        .foregroundColor(.secondary)
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(peer.online ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)
                        Text(peer.online ? "Online" : "Offline")
                    }
                }
                
                if peer.isCurrentDevice {
                    HStack {
                        Text("This Device")
                            .foregroundColor(.secondary)
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                }
            } header: {
                Text("Device")
            }
            
            // IP Addresses section
            Section {
                ForEach(peer.addresses, id: \.self) { address in
                    InfoRow(label: isIPv6(address) ? "IPv6" : "IPv4", value: address) {
                        copyToClipboard(address)
                    }
                }
            } header: {
                Text("Addresses")
            } footer: {
                Text("Tap an address to copy it to clipboard.")
            }
            
            // Exit Node section
            if isExitNode && !peer.isCurrentDevice {
                Section {
                    HStack {
                        Text("Exit Node")
                            .foregroundColor(.secondary)
                        Spacer()
                        if isCurrentExitNode {
                            Text("In Use")
                                .foregroundColor(.green)
                                .fontWeight(.medium)
                        } else {
                            Text("Available")
                                .foregroundColor(.blue)
                        }
                    }

                          if !appState.appNetworkIsActive {
                              HStack {
                                  Image(systemName: "lock.fill")
                                      .foregroundColor(.secondary)
                                  Text("Connect first")
                                      .foregroundColor(.secondary)
                                  Spacer()
                              }
                              .opacity(0.55)
                          } else if isCurrentExitNode {
                        Button(role: .destructive) {
                            appState.clearExitNode()
                        } label: {
                            HStack {
                                Spacer()
                                if appState.isUpdatingExitNode && appState.pendingExitNodeID == "" {
                                    ProgressView()
                                        .padding(.trailing, 8)
                                    Text("Stopping...")
                                } else {
                                    Text("Stop Using as Exit Node")
                                }
                                Spacer()
                            }
                        }
                        .disabled(appState.isUpdatingExitNode)
                    } else if peer.online {
                        Button {
                            appState.setExitNode(peer)
                        } label: {
                            HStack {
                                Spacer()
                                if appState.isUpdatingExitNode && appState.pendingExitNodeID == peer.id {
                                    ProgressView()
                                        .padding(.trailing, 8)
                                    Text("Updating...")
                                } else {
                                    Text("Use as Exit Node")
                                }
                                Spacer()
                            }
                        }
                        .disabled(appState.isUpdatingExitNode)
                    }
                } header: {
                    Text("Exit Node")
                }
            }
            
            // Key & Security section
            Section {
                if let keyExpiry = peer.keyExpiry {
                    let expiryDate = parseISO8601Date(keyExpiry)
                    InfoRow(
                        label: "Key Expires",
                        value: expiryDate.map { formatKeyExpiry($0) } ?? "Unknown",
                        valueColor: keyExpiryColor(expiryDate)
                    )
                }
                
                if let userDisplayName = peer.userDisplayName {
                    InfoRow(label: "Owner", value: userDisplayName)
                }
            } header: {
                Text("Security")
            }
            
            // Hostname section
            Section {
                InfoRow(label: "Hostname", value: peer.hostname) {
                    copyToClipboard(peer.hostname)
                }
                
                if let nodeKey = peer.nodeKey {
                    InfoRow(label: "Node Key", value: truncateNodeKey(nodeKey)) {
                        copyToClipboard(nodeKey)
                    }
                }
            } header: {
                Text("Network")
            }

            if !peer.isCurrentDevice && !peer.sshTargetHost.isEmpty {
                Section {
                    NavigationLink {
                        TailnetTerminalView(initialHost: peer.sshTargetHost, sshHint: peer.sshCapabilityLabel)
                    } label: {
                        HStack {
                            Image(systemName: "terminal")
                                .foregroundColor(.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("SSH")
                                Text(peer.sshCapabilityLabel)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Actions")
                }
            }
            
            // Diagnostics section
            if !peer.isCurrentDevice && peer.primaryIPv4Address != nil {
                Section {
                      if appState.usesVPNPermission {
                          NavigationLink {
                              PingView(peer: peer)
                          } label: {
                              HStack {
                                  Image(systemName: "waveform.path")
                                      .foregroundColor(.accentColor)
                                  Text("Ping")
                              }
                          }
                      } else {
                        HStack {
                            Image(systemName: "waveform.path")
                                  .foregroundColor(.secondary)
                            Text("Ping")
                              Spacer()
                              Text("VPN required")
                                  .font(.caption)
                                  .foregroundColor(.secondary)
                        }
                          .opacity(0.55)
                    }
                } header: {
                    Text("Diagnostics")
                }
            }
        }
        .navigationTitle(peer.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if showCopiedMessage {
                ToastView(message: "Copied: \(copiedText)")
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showCopiedMessage)
    }
    
    // MARK: - Helper Functions
    
    private func copyToClipboard(_ text: String) {
        UIPasteboard.general.string = text
        copiedText = text.count > 30 ? String(text.prefix(30)) + "..." : text
        showCopiedMessage = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showCopiedMessage = false
        }
    }
    
    private func isIPv6(_ address: String) -> Bool {
        address.contains(":")
    }
    
    private func osIcon(for os: String) -> String {
        let lower = os.lowercased()
        if lower.contains("ios") || lower.contains("iphone") || lower.contains("ipad") {
            return "iphone"
        } else if lower.contains("macos") || lower.contains("darwin") || lower.contains("mac") {
            return "laptopcomputer"
        } else if lower.contains("windows") {
            return "pc"
        } else if lower.contains("linux") {
            return "server.rack"
        } else if lower.contains("android") {
            return "smartphone"
        }
        return "desktopcomputer"
    }
    
    private func parseISO8601Date(_ dateString: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: dateString) {
            return date
        }
        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: dateString)
    }
    
    private func formatKeyExpiry(_ date: Date) -> String {
        let now = Date()
        if date < now {
            return "Expired"
        }
        
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
    
    private func keyExpiryColor(_ date: Date?) -> Color {
        guard let date = date else { return .primary }
        let now = Date()
        if date < now {
            return .red
        }
        let daysUntilExpiry = Calendar.current.dateComponents([.day], from: now, to: date).day ?? 0
        if daysUntilExpiry < 7 {
            return .orange
        }
        return .primary
    }
    
    private func truncateNodeKey(_ key: String) -> String {
        if key.count > 20 {
            return String(key.prefix(10)) + "..." + String(key.suffix(6))
        }
        return key
    }
}

/// Row displaying a label-value pair with optional copy action.
struct InfoRow: View {
    let label: String
    let value: String
    var icon: String? = nil
    var valueColor: Color = .primary
    var onTap: (() -> Void)? = nil
    
    var body: some View {
        Button(action: { onTap?() }) {
            HStack {
                Text(label)
                    .foregroundColor(.secondary)
                Spacer()
                HStack(spacing: 4) {
                    if let icon = icon {
                        Image(systemName: icon)
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                    Text(value)
                        .foregroundColor(valueColor)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil)
    }
}

/// Toast view for feedback messages.
struct ToastView: View {
    let message: String
    
    var body: some View {
        Text(message)
            .font(.caption)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(.systemGray5))
            .cornerRadius(20)
            .shadow(radius: 4)
            .padding(.bottom, 20)
    }
}

/// Ping diagnostics view.
struct PingView: View {
    let peer: PeerNode
    @EnvironmentObject var appState: AppState
    @State private var pingResults: [PingResult] = []
    @State private var isPinging: Bool = false
    @State private var pingCount: Int = 0
    @State private var pingTask: Task<Void, Never>?
    @State private var pingRunID: UUID?

    private let maxSamples = 30
    private let maxPingCount = 30
    private let pingTimeoutMillis = 5_000
    
    var body: some View {
        List {
            Section {
                HStack {
                    Text("Target")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(peer.displayName)
                }
                
                if let addr = peer.primaryIPv4Address ?? peer.addresses.first {
                    HStack {
                        Text("Address")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(addr)
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }
            
            Section {
                Button {
                    isPinging ? stopPing() : startPing()
                } label: {
                    HStack {
                        Spacer()
                        if isPinging {
                            Image(systemName: "stop.fill")
                            Text("Stop Ping")
                        } else {
                            Image(systemName: "waveform.path")
                            Text("Start Ping")
                        }
                        Spacer()
                    }
                }
                .disabled(peer.primaryIPv4Address == nil)
            }
            
            if !pingResults.isEmpty {
                Section {
                    PingLatencyChart(results: pingResults)
                        .frame(height: 230)
                        .padding(.vertical, 8)

                    PingStatsView(results: pingResults, sent: pingCount)
                } header: {
                    Text("Latency")
                }

                Section {
                    ForEach(pingResults.suffix(8).reversed()) { result in
                        PingResultRow(result: result)
                    }
                } header: {
                    Text("Recent")
                }
            }
        }
        .navigationTitle("Ping")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            stopPing()
        }
    }

    private func startPing() {
        guard let vpn = appState.vpnManager else { return }
        guard let targetIP = peer.primaryIPv4Address else {
            pingResults = [PingResult(seq: 1, error: "No IPv4 address")]
            return
        }
        guard canStartPing(vpn: vpn) else {
            pingResults = [PingResult(seq: 1, error: "VPN is not ready")]
            return
        }

        isPinging = true
        pingResults = []
        pingCount = 0
        pingTask?.cancel()
        let runID = UUID()
        pingRunID = runID

        pingTask = Task {
            var seq = 0
            while !Task.isCancelled && seq < maxPingCount {
                seq += 1

                do {
                    let canContinue = await MainActor.run {
                        canContinuePing(vpn: vpn)
                    }
                    guard canContinue else {
                        await MainActor.run {
                            appendPingResult(PingResult(seq: seq, error: "VPN stopped while pinging"))
                            stopPing()
                        }
                        break
                    }

                    let result = try await LocalAPIClient.vpn(vpn).ping(ip: targetIP, timeout: pingTimeoutMillis)
                    if Task.isCancelled { break }
                    if let error = result.Err, !error.isEmpty {
                        await MainActor.run {
                            appendPingResult(PingResult(seq: seq, error: normalizePingError(error)))
                        }
                    } else if let latency = result.LatencySeconds {
                        await MainActor.run {
                            appendPingResult(PingResult(seq: seq, latencyMs: latency * 1000))
                        }
                    } else {
                        await MainActor.run {
                            appendPingResult(PingResult(seq: seq, error: "Invalid response"))
                        }
                    }
                } catch {
                    if Task.isCancelled { break }
                    await MainActor.run {
                        appendPingResult(PingResult(seq: seq, error: normalizePingError(error.localizedDescription)))
                    }
                }

                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    break
                }
            }

            await MainActor.run {
                guard pingRunID == runID else { return }
                isPinging = false
                pingTask = nil
                pingRunID = nil
            }
        }
    }

    private func stopPing() {
        pingTask?.cancel()
        pingTask = nil
        pingRunID = nil
        isPinging = false
    }

    private func appendPingResult(_ result: PingResult) {
        pingCount = result.seq
        pingResults.append(result)
        if pingResults.count > maxSamples {
            pingResults.removeFirst(pingResults.count - maxSamples)
        }
    }

    private func canStartPing(vpn: VPNManager) -> Bool {
        appState.pendingWantRunning == nil
            && !appState.isUpdatingExitNode
            && appState.ipnState == .running
            && vpn.isTunnelActive
    }

    private func canContinuePing(vpn: VPNManager) -> Bool {
        appState.pendingWantRunning != false && vpn.isTunnelActive
    }

    private func normalizePingError(_ message: String) -> String {
        let lowercased = message.lowercased()
        if lowercased.contains("timeout") || lowercased.contains("timed out") {
            return "Timed out"
        }
        return message
    }

    private func latencyColor(_ ms: Double) -> Color {
        if ms < 50 { return .green }
        if ms < 150 { return .orange }
        return .red
    }
}

struct PingLatencyChart: View {
    let results: [PingResult]

    private var visibleResults: [PingResult] {
        Array(results.suffix(50))
    }

    private var latencies: [Double] {
        visibleResults.compactMap(\.latencyMs)
    }

    private var maxLatency: Double {
        niceCeiling(max(20, (latencies.max() ?? 10) * 1.25))
    }

    private var latestText: String {
        guard let latest = visibleResults.last else { return "--" }
        if let latency = latest.latencyMs {
            return String(format: "%.1f ms", latency)
        }
        return "Lost"
    }

    private var latestColor: Color {
        guard let latest = visibleResults.last?.latencyMs else { return .red }
        return latencyColor(latest)
    }

    private var averageText: String {
        guard !latencies.isEmpty else { return "--" }
        let average = latencies.reduce(0, +) / Double(latencies.count)
        return String(format: "%.1f ms", average)
    }

    private var lossText: String {
        guard !visibleResults.isEmpty else { return "--" }
        let lost = visibleResults.filter { $0.latencyMs == nil }.count
        if lost == 0 { return "0%" }
        let percent = Double(lost) / Double(visibleResults.count) * 100
        return String(format: "%.0f%%", percent)
    }

    private var axisValues: [Double] {
        [maxLatency, maxLatency * 0.75, maxLatency * 0.5, maxLatency * 0.25, 0]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                metric(title: "Current", value: latestText, color: latestColor, prominent: true)

                Spacer()

                metric(title: "Average", value: averageText)
                metric(title: "Loss", value: lossText, color: lossText == "0%" ? .secondary : .red)
            }

            GeometryReader { geometry in
                let labelWidth: CGFloat = 48
                let plotHeight = max(geometry.size.height - 18, 1)
                let plotWidth = max(geometry.size.width - labelWidth, 1)

                VStack(spacing: 4) {
                    HStack(alignment: .top, spacing: 0) {
                        ZStack(alignment: .topLeading) {
                            chartGrid(width: plotWidth, height: plotHeight)
                            latencyArea(width: plotWidth, height: plotHeight)
                            latencyLine(width: plotWidth, height: plotHeight)
                            lossMarkers(width: plotWidth, height: plotHeight)
                            latencyPoints(width: plotWidth, height: plotHeight)
                        }
                        .frame(width: plotWidth, height: plotHeight)

                        yAxisLabels(height: plotHeight)
                            .frame(width: labelWidth, height: plotHeight)
                    }

                    HStack {
                        Text(visibleResults.first.map { "#\($0.seq)" } ?? "")
                        Spacer()
                        Text("\(visibleResults.count) samples")
                        Spacer()
                        Text(visibleResults.last.map { "#\($0.seq)" } ?? "")
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.trailing, labelWidth)
                }
            }
            .frame(height: 164)

            HStack(spacing: 12) {
                PingLegendItem(color: .green, label: "< 50 ms")
                PingLegendItem(color: .orange, label: "50-150 ms")
                PingLegendItem(color: .red, label: "Slow/Lost")
            }
            .font(.caption2)
            .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func metric(title: String, value: String, color: Color = .secondary, prominent: Bool = false) -> some View {
        VStack(alignment: prominent ? .leading : .trailing, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(prominent ? .title3 : .caption, design: .monospaced))
                .fontWeight(prominent ? .semibold : .regular)
                .foregroundColor(color)
        }
    }

    @ViewBuilder
    private func chartGrid(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<5, id: \.self) { index in
                Rectangle()
                    .fill(Color(.separator).opacity(index == 4 ? 0.34 : 0.18))
                    .frame(width: width, height: 1)
                    .offset(y: height * CGFloat(index) / 4)
            }

            ForEach(0..<4, id: \.self) { index in
                Rectangle()
                    .fill(Color(.separator).opacity(0.10))
                    .frame(width: 1, height: height)
                    .offset(x: width * CGFloat(index) / 3)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func latencyArea(width: CGFloat, height: CGFloat) -> some View {
        Path { path in
            var segmentStart: CGPoint?
            var previousPoint: CGPoint?

            for (index, result) in visibleResults.enumerated() {
                guard let latency = result.latencyMs else {
                    if let segmentStart, let previousPoint {
                        path.addLine(to: CGPoint(x: previousPoint.x, y: height))
                        path.addLine(to: CGPoint(x: segmentStart.x, y: height))
                        path.closeSubpath()
                    }
                    segmentStart = nil
                    previousPoint = nil
                    continue
                }

                let point = chartPoint(index: index, latency: latency, width: width, height: height)
                if segmentStart == nil {
                    segmentStart = point
                    path.move(to: CGPoint(x: point.x, y: height))
                    path.addLine(to: point)
                } else {
                    path.addLine(to: point)
                }
                previousPoint = point
            }

            if let segmentStart, let previousPoint {
                path.addLine(to: CGPoint(x: previousPoint.x, y: height))
                path.addLine(to: CGPoint(x: segmentStart.x, y: height))
                path.closeSubpath()
            }
        }
        .fill(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.20), Color.accentColor.opacity(0.02)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func latencyLine(width: CGFloat, height: CGFloat) -> some View {
        Path { path in
            var isDrawingSegment = false

            for (index, result) in visibleResults.enumerated() {
                guard let latency = result.latencyMs else {
                    isDrawingSegment = false
                    continue
                }

                let point = chartPoint(index: index, latency: latency, width: width, height: height)
                if isDrawingSegment {
                    path.addLine(to: point)
                } else {
                    path.move(to: point)
                    isDrawingSegment = true
                }
            }
        }
        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func latencyPoints(width: CGFloat, height: CGFloat) -> some View {
        ForEach(Array(visibleResults.enumerated()), id: \.element.id) { index, result in
            if let latency = result.latencyMs {
                let point = chartPoint(index: index, latency: latency, width: width, height: height)
                Circle()
                    .fill(latencyColor(latency))
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                    .frame(width: 9, height: 9)
                    .position(point)
                    .accessibilityLabel("Ping \(result.seq), \(String(format: "%.1f", latency)) milliseconds")
            }
        }
    }

    @ViewBuilder
    private func lossMarkers(width: CGFloat, height: CGFloat) -> some View {
        ForEach(Array(visibleResults.enumerated()), id: \.element.id) { index, result in
            if result.latencyMs == nil {
                let x = chartX(index: index, width: width)
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.red.opacity(0.18))
                        .frame(width: 2, height: max(height - 18, 1))
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                        .foregroundColor(.red)
                        .background(Circle().fill(Color(.systemBackground)))
                }
                .frame(width: 16, height: height, alignment: .bottom)
                .position(x: x, y: height / 2)
                .accessibilityLabel("Ping \(result.seq), lost")
            }
        }
    }

    @ViewBuilder
    private func yAxisLabels(height: CGFloat) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(Array(axisValues.enumerated()), id: \.offset) { index, value in
                Text(index == axisValues.count - 1 ? "0 ms" : String(format: "%.0f", value))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                if index < axisValues.count - 1 {
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(height: height)
    }

    private func chartPoint(index: Int, latency: Double, width: CGFloat, height: CGFloat) -> CGPoint {
        let clampedLatency = min(max(latency, 0), maxLatency)
        return CGPoint(
            x: chartX(index: index, width: width),
            y: height - CGFloat(clampedLatency / maxLatency) * height
        )
    }

    private func chartX(index: Int, width: CGFloat) -> CGFloat {
        guard visibleResults.count > 1 else { return width / 2 }
        return width * CGFloat(index) / CGFloat(visibleResults.count - 1)
    }

    private func niceCeiling(_ value: Double) -> Double {
        if value <= 50 { return 50 }
        if value <= 100 { return 100 }
        if value <= 200 { return 200 }
        if value <= 500 { return 500 }
        return ceil(value / 500) * 500
    }

    private func latencyColor(_ ms: Double) -> Color {
        if ms < 50 { return .green }
        if ms < 150 { return .orange }
        return .red
    }
}

struct PingLegendItem: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
        }
    }
}

struct PingStatsView: View {
    let results: [PingResult]
    let sent: Int

    private var latencies: [Double] {
        results.compactMap(\.latencyMs)
    }

    private var received: Int { latencies.count }
    private var lossPercent: Double {
        guard sent > 0 else { return 0 }
        return Double(max(sent - received, 0)) / Double(sent) * 100
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                PingStatCell(title: "Sent", value: "\(sent)")
                PingStatCell(title: "Recv", value: "\(received)")
                PingStatCell(title: "Loss", value: String(format: "%.0f%%", lossPercent))
            }
            HStack {
                PingStatCell(title: "Min", value: formatted(latencies.min()))
                PingStatCell(title: "Avg", value: formatted(averageLatency))
                PingStatCell(title: "Max", value: formatted(latencies.max()))
            }
        }
    }

    private var averageLatency: Double? {
        guard !latencies.isEmpty else { return nil }
        return latencies.reduce(0, +) / Double(latencies.count)
    }

    private func formatted(_ latency: Double?) -> String {
        guard let latency else { return "--" }
        return String(format: "%.1f ms", latency)
    }
}

struct PingStatCell: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
    }
}

struct PingResultRow: View {
    let result: PingResult

    var body: some View {
        HStack {
            Text("#\(result.seq)")
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 48, alignment: .leading)

            Spacer()

            if let latency = result.latencyMs {
                Text(String(format: "%.1f ms", latency))
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(latencyColor(latency))
            } else if let error = result.error {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private func latencyColor(_ ms: Double) -> Color {
        if ms < 50 { return .green }
        if ms < 150 { return .orange }
        return .red
    }
}

/// Single ping result.
struct PingResult: Identifiable {
    let id = UUID()
    let seq: Int
    var latencyMs: Double? = nil
    var error: String? = nil
}

#Preview {
    NavigationView {
        PeerDetailView(peer: PeerNode(
            from: NetworkMap.NodeData(
                ID: 1,
                StableID: "abc123",
                Key: "nodekey:abc123def456",
                Name: "my-macbook.tailnet-name.ts.net",
                ComputedName: "my-macbook",
                Hostinfo: .init(Hostname: "my-macbook"),
                Addresses: ["100.100.1.1/32", "fd7a:115c:a1e0::1/128"],
                Online: true,
                OS: "macOS",
                UserID: 1,
                KeyExpiry: "2025-12-31T23:59:59Z",
                IsExitNode: true,
                AllowedIPs: ["0.0.0.0/0", "::/0"]
            ),
            isSelf: false,
            userProfile: nil
        ))
    }
}
