import SwiftUI
import UniformTypeIdentifiers

/// Taildrop file transfer view.
/// Displays received files and provides options to accept/share them.
struct TaildropView: View {
    @EnvironmentObject var appState: AppState
    @State private var incomingFiles: [TaildropFile] = []
    @State private var isLoading: Bool = true
    @State private var error: String?
    @State private var selectedFile: TaildropFile?
    @State private var showingShareSheet: Bool = false
    @State private var showingSaveDialog: Bool = false
    
    var body: some View {
        List {
            if isLoading {
                Section {
                    HStack {
                        ProgressView()
                            .padding(.trailing, 8)
                        Text("Checking for incoming files...")
                            .foregroundColor(.secondary)
                    }
                }
            } else if let error = error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundColor(.red)
                }
            } else if incomingFiles.isEmpty {
                Section {
                    VStack(alignment: .center, spacing: 16) {
                        Image(systemName: "arrow.down.doc")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        
                        Text("No incoming files")
                            .font(.headline)
                        
                        Text("Files sent to this device via Taildrop will appear here.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                }
            } else {
                // Incoming files
                Section {
                    ForEach(incomingFiles) { file in
                        TaildropFileRow(file: file) {
                            selectedFile = file
                            showingShareSheet = true
                        }
                    }
                } header: {
                    Text("Incoming Files (\(incomingFiles.count))")
                }
            }
            
            // Send files section
            Section {
                NavigationLink(destination: TaildropSendView()) {
                    HStack {
                        Image(systemName: "arrow.up.doc")
                            .foregroundColor(.accentColor)
                        Text("Send Files")
                    }
                }
            }
            
            // Info section
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text("Taildrop lets you transfer files between your Tailscale devices.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } icon: {
                        Image(systemName: "info.circle")
                            .foregroundColor(.blue)
                    }
                    
                    Label {
                        Text("Note: Resume for interrupted transfers is not supported when receiving on iOS.")
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
        .navigationTitle("Taildrop")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await loadIncomingFiles()
        }
        .onAppear {
            Task {
                await loadIncomingFiles()
            }
        }
        .sheet(isPresented: $showingShareSheet) {
            if let file = selectedFile, let url = file.localURL {
                ShareSheet(activityItems: [url])
            }
        }
    }
    
    @MainActor
    private func loadIncomingFiles() async {
        guard let vpn = appState.vpnManager else {
            error = "VPN manager not available"
            isLoading = false
            return
        }
        
        isLoading = true
        error = nil
        
        do {
            let resp = try await vpn.callLocalAPI(method: "GET", endpoint: "/localapi/v0/files")
            
            guard resp.statusCode == 200,
                  let bodyB64 = resp.bodyBase64,
                  let bodyData = Data(base64Encoded: bodyB64) else {
                if resp.statusCode == 404 {
                    incomingFiles = loadLocalIncomingFiles()
                    isLoading = false
                    return
                }
                // 204 or empty response means no files
                if resp.statusCode == 204 || resp.statusCode == 200 {
                    incomingFiles = []
                    isLoading = false
                    return
                }
                error = "Failed to load files (status \(resp.statusCode))"
                isLoading = false
                return
            }
            
            let files = try JSONDecoder().decode([TaildropFileResponse].self, from: bodyData)
            incomingFiles = files.map { TaildropFile(from: $0) }
            isLoading = false
        } catch {
            // Empty array is also valid for decoding errors
            if error is DecodingError {
                incomingFiles = []
                isLoading = false
                return
            }
            self.error = "Failed to load files: \(error.localizedDescription)"
            isLoading = false
        }
    }

    private func loadLocalIncomingFiles() -> [TaildropFile] {
        guard let groupContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.tailscale.ipn.ios") else {
            return []
        }
        let taildropDir = groupContainer.appendingPathComponent("taildrop", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: taildropDir,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory != true else { return nil }
            return TaildropFile(localURL: url)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// Row displaying a single Taildrop file.
struct TaildropFileRow: View {
    let file: TaildropFile
    let onShare: () -> Void
    
    var body: some View {
        HStack {
            Image(systemName: fileIcon)
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 40)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(file.name)
                    .font(.body)
                    .lineLimit(1)
                
                HStack(spacing: 8) {
                    Text(formatFileSize(file.size))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if let sender = file.sender {
                        Text("from \(sender)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
            
            Button(action: onShare) {
                Image(systemName: "square.and.arrow.up")
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
    
    private var fileIcon: String {
        let ext = (file.name as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.fill"
        case "jpg", "jpeg", "png", "gif", "heic": return "photo"
        case "mp4", "mov", "m4v": return "video"
        case "mp3", "m4a", "wav": return "music.note"
        case "zip", "tar", "gz": return "archivebox"
        case "txt", "md": return "doc.text"
        default: return "doc"
        }
    }
    
    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

/// View for sending files via Taildrop.
struct TaildropSendView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingFilePicker: Bool = false
    @State private var selectedPeer: PeerNode?
    @State private var selectedFileURLs: [URL] = []
    @State private var isSending: Bool = false
    @State private var sendProgress: Double = 0
    @State private var sendError: String?
    
    private var eligiblePeers: [PeerNode] {
        appState.peers.filter { !$0.isCurrentDevice && $0.online }
    }
    
    var body: some View {
        List {
            // File selection
            Section {
                Button {
                    showingFilePicker = true
                } label: {
                    HStack {
                        Image(systemName: "doc.badge.plus")
                            .foregroundColor(.accentColor)
                        Text(selectedFileURLs.isEmpty ? "Select Files" : "\(selectedFileURLs.count) file(s) selected")
                    }
                }
                
                ForEach(selectedFileURLs, id: \.absoluteString) { url in
                    HStack {
                        Image(systemName: "doc")
                            .foregroundColor(.secondary)
                        Text(url.lastPathComponent)
                            .font(.caption)
                        Spacer()
                        Button {
                            selectedFileURLs.removeAll { $0 == url }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("Files to Send")
            }
            
            // Peer selection
            Section {
                if eligiblePeers.isEmpty {
                    Text("No online devices available")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(eligiblePeers) { peer in
                        Button {
                            selectedPeer = peer
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(peer.displayName)
                                        .foregroundColor(.primary)
                                    if let os = peer.os {
                                        Text(os)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                if selectedPeer?.id == peer.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("Send To")
            }
            
            // Send button
            if !selectedFileURLs.isEmpty && selectedPeer != nil {
                Section {
                    Button {
                        sendFiles()
                    } label: {
                        HStack {
                            Spacer()
                            if isSending {
                                ProgressView()
                                    .padding(.trailing, 8)
                                Text("Sending...")
                            } else {
                                Image(systemName: "paperplane.fill")
                                Text("Send Files")
                            }
                            Spacer()
                        }
                    }
                    .disabled(isSending)
                }
                
                if isSending {
                    Section {
                        ProgressView(value: sendProgress)
                    }
                }
            }
            
            if let error = sendError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundColor(.red)
                }
            }
        }
        .navigationTitle("Send Files")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingFilePicker) {
            DocumentPicker(selectedURLs: $selectedFileURLs)
        }
    }
    
    private func sendFiles() {
        guard let peer = selectedPeer,
              let vpn = appState.vpnManager,
              !selectedFileURLs.isEmpty else { return }
        
        isSending = true
        sendError = nil
        sendProgress = 0
        
        Task {
            do {
                let totalFiles = selectedFileURLs.count
                for (index, url) in selectedFileURLs.enumerated() {
                    // Read file data
                    guard url.startAccessingSecurityScopedResource() else {
                        throw TaildropError.accessDenied
                    }
                    defer { url.stopAccessingSecurityScopedResource() }
                    
                    let data = try Data(contentsOf: url)
                    let fileName = url.lastPathComponent
                    
                    // PUT to /localapi/v0/file-put/{peerID}/{filename}
                    let endpoint = "/localapi/v0/file-put/\(peer.id)/\(fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName)"
                    let _ = try await vpn.callLocalAPI(method: "PUT", endpoint: endpoint, body: data)
                    
                    await MainActor.run {
                        sendProgress = Double(index + 1) / Double(totalFiles)
                    }
                }
                
                await MainActor.run {
                    isSending = false
                    selectedFileURLs = []
                    selectedPeer = nil
                }
            } catch {
                await MainActor.run {
                    sendError = "Failed to send: \(error.localizedDescription)"
                    isSending = false
                }
            }
        }
    }
}

enum TaildropError: Error {
    case accessDenied
    case sendFailed
}

/// Document picker for selecting files.
struct DocumentPicker: UIViewControllerRepresentable {
    @Binding var selectedURLs: [URL]
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPicker
        
        init(_ parent: DocumentPicker) {
            self.parent = parent
        }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.selectedURLs.append(contentsOf: urls)
        }
    }
}

/// Share sheet for sharing files.
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Models

/// Response from /localapi/v0/files
struct TaildropFileResponse: Codable {
    let Name: String
    let Size: Int64
    let Sender: String?
    let Started: String?
}

/// Parsed Taildrop file for display.
struct TaildropFile: Identifiable {
    let id: String
    let name: String
    let size: Int64
    let sender: String?
    let started: Date?
    var localURL: URL?
    
    init(from response: TaildropFileResponse) {
        self.id = response.Name
        self.name = response.Name
        self.size = response.Size
        self.sender = response.Sender
        self.started = nil // Parse if needed
        
        // Construct the local file URL from the Taildrop directory
        // Files are stored in App Group container under taildrop/
        if let groupContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.tailscale.ipn.ios") {
            let taildropDir = groupContainer.appendingPathComponent("taildrop", isDirectory: true)
            self.localURL = taildropDir.appendingPathComponent(response.Name)
        } else {
            self.localURL = nil
        }
    }

    init(localURL: URL) {
        self.id = localURL.path
        self.name = localURL.lastPathComponent
        self.sender = nil
        let values = try? localURL.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
        self.size = Int64(values?.fileSize ?? 0)
        self.started = values?.creationDate
        self.localURL = localURL
    }
}

#Preview {
    NavigationView {
        TaildropView()
            .environmentObject(AppState())
    }
}
