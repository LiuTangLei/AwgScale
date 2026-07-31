import AVFoundation
import SwiftUI

enum TailnetLockSigningURLValidationError: LocalizedError, Equatable {
    case empty
    case unsupportedURL
    case missingParameter(String)

    var errorDescription: String? {
        switch self {
        case .empty:
            return "The QR code is empty."
        case .unsupportedURL:
            return "This is not a supported Tailnet Lock signing QR code."
        case .missingParameter(let name):
            return "The Tailnet Lock signing URL is missing \(name)."
        }
    }
}

/// Performs structural validation only. LocalAPI remains authoritative for the
/// Tailnet Lock HMAC and signing-key validation.
func validatedTailnetLockSigningURL(from payload: String) throws -> String {
    let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw TailnetLockSigningURLValidationError.empty
    }

    guard var components = URLComponents(string: trimmed),
          components.scheme?.lowercased() == "tailscale",
          components.host?.lowercased() == "sign-device",
          components.port == nil,
          components.user == nil,
          components.password == nil,
          components.percentEncodedPath == "/v1/",
          components.fragment == nil else {
        throw TailnetLockSigningURLValidationError.unsupportedURL
    }

    let values = Dictionary(
        grouping: components.queryItems ?? [],
        by: \.name
    ).mapValues { items in
        items.first?.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    for parameter in ["nk", "tp", "dn", "os", "em", "hm"] where values[parameter]?.isEmpty != false {
        throw TailnetLockSigningURLValidationError.missingParameter(parameter)
    }

    // Go normalizes the scheme but compares the command host literally.
    components.scheme = "tailscale"
    components.host = "sign-device"
    return components.string ?? trimmed
}

/// Tailnet Lock management view.
/// Shows lock status and allows signing operations.
struct TailnetLockView: View {
    @EnvironmentObject var appState: AppState
    @State private var lockStatus: TailnetLockStatus?
    @State private var isLoading: Bool = true
    @State private var error: String?
    @State private var showingQRScanner: Bool = false
    @State private var showingSignURL: Bool = false
    @State private var signURL: String = ""
    @State private var isSigning: Bool = false
    @State private var lastSignedDevice: String?
    
    var body: some View {
        List {
            if isLoading {
                Section {
                    HStack {
                        ProgressView()
                            .padding(.trailing, 8)
                        Text("Loading Tailnet Lock status...")
                            .foregroundColor(.secondary)
                    }
                }
            } else if let error = error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundColor(.red)
                }
            } else if let status = lockStatus {
                // Lock status
                Section {
                    HStack {
                        Image(systemName: status.enabled ? "lock.shield.fill" : "lock.open")
                            .foregroundColor(status.enabled ? .green : .secondary)
                            .font(.title2)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Tailnet Lock")
                                .font(.headline)
                            Text(status.enabled ? "Enabled" : "Not Enabled")
                                .font(.subheadline)
                                .foregroundColor(status.enabled ? .green : .secondary)
                        }
                    }
                } footer: {
                    Text("Tailnet Lock requires nodes to be signed by trusted signing keys before they can join your network.")
                }
                
                // This node's status
                if status.enabled {
                    Section {
                        // Node key
                        if let nodeKey = status.nodeKey {
                            CopyableRow(label: "Node Key", value: truncateKey(nodeKey), fullValue: nodeKey)
                        }
                        
                        // Node key signature status
                        HStack {
                            Text("Signature")
                            Spacer()
                            if status.nodeKeySigned {
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.seal.fill")
                                        .foregroundColor(.green)
                                    Text("Signed")
                                        .foregroundColor(.green)
                                }
                            } else {
                                HStack(spacing: 4) {
                                    Image(systemName: "questionmark.circle")
                                        .foregroundColor(.orange)
                                    Text("Not Signed")
                                        .foregroundColor(.orange)
                                }
                            }
                        }
                    } header: {
                        Text("This Device")
                    }
                    
                    // Signing key (if this device can sign)
                    if let tlPubKey = status.publicKey {
                        Section {
                            CopyableRow(label: "TL Public Key", value: truncateKey(tlPubKey), fullValue: tlPubKey)
                            
                            HStack {
                                Text("Can Sign")
                                Spacer()
                                if status.isSigningKey {
                                    HStack(spacing: 4) {
                                        Image(systemName: "signature")
                                            .foregroundColor(.green)
                                        Text("Yes")
                                            .foregroundColor(.green)
                                    }
                                } else {
                                    Text("No")
                                        .foregroundColor(.secondary)
                                }
                            }
                        } header: {
                            Text("Tailnet Lock Key")
                        } footer: {
                            if status.isSigningKey {
                                Text("This device is a trusted signing node and can sign other nodes.")
                            } else {
                                Text("This device cannot sign other nodes. A Tailnet admin can add this key as a signing key.")
                            }
                        }
                    }
                    
                    // Signing operations (if this device can sign)
                    if status.isSigningKey {
                        Section {
                            if let lastSignedDevice {
                                Label("Signed \(lastSignedDevice)", systemImage: "checkmark.seal.fill")
                                    .foregroundColor(.green)
                            }

                            Button {
                                showingQRScanner = true
                            } label: {
                                HStack {
                                    Image(systemName: "qrcode.viewfinder")
                                        .foregroundColor(.accentColor)
                                    Text("Scan QR Code to Sign")
                                }
                            }
                            
                            Button {
                                showingSignURL = true
                            } label: {
                                HStack {
                                    Image(systemName: "link")
                                        .foregroundColor(.accentColor)
                                    Text("Sign via URL")
                                }
                            }
                        } header: {
                            Text("Sign Nodes")
                        } footer: {
                            Text("Sign other devices to allow them to join your Tailnet.")
                        }
                    }
                    
                    // Trusted keys
                    if !status.trustedKeys.isEmpty {
                        Section {
                            ForEach(status.trustedKeys, id: \.self) { key in
                                Text(truncateKey(key))
                                    .font(.system(.caption, design: .monospaced))
                            }
                        } header: {
                            Text("Trusted Signing Keys (\(status.trustedKeys.count))")
                        }
                    }
                }
            } else {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tailnet Lock Not Available")
                            .font(.headline)
                        Text("Tailnet Lock is not configured for this Tailnet. Contact your Tailnet admin to enable it.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .navigationTitle("Tailnet Lock")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await loadLockStatus()
        }
        .onAppear {
            Task {
                await loadLockStatus()
            }
        }
        .sheet(isPresented: $showingSignURL) {
            NavigationView {
                SignURLView(onSign: { url in
                    signURL = url
                    showingSignURL = false
                    signNode(url: url)
                })
            }
        }
        .sheet(isPresented: $showingQRScanner) {
            TailnetLockQRScannerSheet { url in
                showingQRScanner = false
                signNode(url: url)
            }
        }
        .overlay {
            if isSigning {
                ZStack {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Signing node...")
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
    private func loadLockStatus() async {
        guard let vpn = appState.vpnManager else {
            error = "VPN manager not available"
            isLoading = false
            return
        }
        
        isLoading = true
        error = nil
        
        do {
            switch try await LocalAPIClient.vpn(vpn).tkaStatus() {
            case .unavailable:
                lockStatus = nil
            case .status(let status):
                lockStatus = TailnetLockStatus(from: status)
            }
            isLoading = false
        } catch {
            self.error = "Failed to load status: \(error.localizedDescription)"
            isLoading = false
        }
    }
    
    private func signNode(url: String) {
        guard let vpn = appState.vpnManager else { return }
        
        isSigning = true
        lastSignedDevice = nil
        
        Task {
            do {
                let result = try await LocalAPIClient.vpn(vpn).tkaSign(url: url)
                
                await MainActor.run {
                    lastSignedDevice = result.DeviceName ?? result.NodeKey ?? "node"
                    isSigning = false
                    error = nil
                }
                await loadLockStatus()
            } catch {
                await MainActor.run {
                    isSigning = false
                    appState.lastError = "Signing failed: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func truncateKey(_ key: String) -> String {
        if key.count > 24 {
            return String(key.prefix(12)) + "..." + String(key.suffix(8))
        }
        return key
    }
}

private enum TailnetLockQRScannerError: LocalizedError, Equatable {
    case permissionDenied
    case cameraUnavailable
    case configurationFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Camera access is disabled. Allow camera access in Settings to scan a Tailnet Lock QR code."
        case .cameraUnavailable:
            return "A camera is not available on this device."
        case .configurationFailed:
            return "The camera could not be configured for QR code scanning."
        }
    }
}

private struct TailnetLockQRScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var scannerID = UUID()
    @State private var scannerError: Error?

    let onSign: (String) -> Void

    var body: some View {
        NavigationView {
            Group {
                if let scannerError {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.orange)
                        Text(scannerError.localizedDescription)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)

                        if (scannerError as? TailnetLockQRScannerError) == .permissionDenied {
                            Button("Open Settings") {
                                guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else {
                                    return
                                }
                                UIApplication.shared.open(settingsURL)
                            }
                        }

                        Button("Try Again") {
                            self.scannerError = nil
                            scannerID = UUID()
                        }
                    }
                } else {
                    ZStack(alignment: .bottom) {
                        TailnetLockQRScannerView { result in
                            handle(result)
                        }
                        .id(scannerID)
                        .ignoresSafeArea(edges: .bottom)

                        Text("Align the Tailnet Lock QR code within the camera view.")
                            .font(.footnote)
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .padding()
                            .background(.black.opacity(0.65))
                            .cornerRadius(10)
                            .padding()
                    }
                }
            }
            .navigationTitle("Scan to Sign")
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

    private func handle(_ result: Result<String, Error>) {
        switch result {
        case .success(let payload):
            do {
                let url = try validatedTailnetLockSigningURL(from: payload)
                onSign(url)
            } catch {
                scannerError = error
            }
        case .failure(let error):
            scannerError = error
        }
    }
}

private struct TailnetLockQRScannerView: UIViewControllerRepresentable {
    let completion: (Result<String, Error>) -> Void

    func makeUIViewController(context: Context) -> TailnetLockQRScannerViewController {
        TailnetLockQRScannerViewController(completion: completion)
    }

    func updateUIViewController(
        _ uiViewController: TailnetLockQRScannerViewController,
        context: Context
    ) {}
}

private final class TailnetLockQRScannerViewController: UIViewController,
    AVCaptureMetadataOutputObjectsDelegate
{
    private let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "top.yesican.awgscale.qr-scanner")
    private let completion: (Result<String, Error>) -> Void
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var isVisible = false
    private var isConfigured = false
    private var didComplete = false

    init(completion: @escaping (Result<String, Error>) -> Void) {
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        self.previewLayer = previewLayer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            isVisible = true
            authorizeAndStart()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            isVisible = false
            if captureSession.isRunning {
                captureSession.stopRunning()
            }
        }
    }

    private func authorizeAndStart() {
        guard isVisible, !didComplete else { return }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                self?.sessionQueue.async {
                    guard let self, self.isVisible, !self.didComplete else { return }
                    if granted {
                        self.configureAndStart()
                    } else {
                        self.finish(.failure(TailnetLockQRScannerError.permissionDenied))
                    }
                }
            }
        case .denied, .restricted:
            finish(.failure(TailnetLockQRScannerError.permissionDenied))
        @unknown default:
            finish(.failure(TailnetLockQRScannerError.permissionDenied))
        }
    }

    private func configureAndStart() {
        guard isVisible, !didComplete else { return }

        if !isConfigured {
            guard let camera = AVCaptureDevice.default(for: .video) else {
                finish(.failure(TailnetLockQRScannerError.cameraUnavailable))
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: camera)
                let output = AVCaptureMetadataOutput()

                captureSession.beginConfiguration()
                defer { captureSession.commitConfiguration() }

                guard captureSession.canAddInput(input),
                      captureSession.canAddOutput(output) else {
                    finish(.failure(TailnetLockQRScannerError.configurationFailed))
                    return
                }

                captureSession.addInput(input)
                captureSession.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: sessionQueue)
                guard output.availableMetadataObjectTypes.contains(.qr) else {
                    finish(.failure(TailnetLockQRScannerError.configurationFailed))
                    return
                }
                output.metadataObjectTypes = [.qr]
                isConfigured = true
            } catch {
                finish(.failure(TailnetLockQRScannerError.configurationFailed))
                return
            }
        }

        guard isVisible, !captureSession.isRunning else { return }
        captureSession.startRunning()
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let qrCode = metadataObjects
            .compactMap({ $0 as? AVMetadataMachineReadableCodeObject })
            .first(where: { $0.type == .qr }),
              let payload = qrCode.stringValue else {
            return
        }
        finish(.success(payload))
    }

    private func finish(_ result: Result<String, Error>) {
        guard !didComplete else { return }
        didComplete = true
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
        DispatchQueue.main.async { [completion] in
            completion(result)
        }
    }
}

/// Copyable row with tap to copy functionality.
struct CopyableRow: View {
    let label: String
    let value: String
    let fullValue: String
    @State private var showCopied: Bool = false
    
    var body: some View {
        Button {
            UIPasteboard.general.string = fullValue
            showCopied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                showCopied = false
            }
        } label: {
            HStack {
                Text(label)
                    .foregroundColor(.secondary)
                Spacer()
                if showCopied {
                    Text("Copied!")
                        .font(.caption)
                        .foregroundColor(.green)
                } else {
                    Text(value)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.primary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// View for entering a sign URL.
struct SignURLView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var url: String = ""
    
    var onSign: (String) -> Void
    
    var body: some View {
        Form {
            Section {
                TextField("Sign URL", text: $url)
                    .textContentType(.URL)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
            } header: {
                Text("Sign URL")
            } footer: {
                Text("Enter the signing URL from the node that needs to be signed.")
            }
            
            Section {
                Button {
                    onSign(url)
                } label: {
                    HStack {
                        Spacer()
                        Text("Sign Node")
                        Spacer()
                    }
                }
                .disabled(url.isEmpty)
            }
        }
        .navigationTitle("Sign via URL")
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

// MARK: - Models

/// Parsed Tailnet Lock status.
struct TailnetLockStatus {
    let enabled: Bool
    let head: String?
    let publicKey: String?
    let nodeKey: String?
    let nodeKeySigned: Bool
    let isSigningKey: Bool
    let trustedKeys: [String]
    
    init(from response: TKAStatusResponse) {
        self.enabled = response.Enabled ?? false
        self.head = response.Head
        self.publicKey = response.PublicKey
        self.nodeKey = response.NodeKey
        self.nodeKeySigned = response.NodeKeySigned ?? false
        self.isSigningKey = response.IsSigningKey ?? false
        self.trustedKeys = response.TrustedKeys ?? []
    }
}

#Preview {
    NavigationView {
        TailnetLockView()
            .environmentObject(AppState())
    }
}
