import SwiftUI

@main
struct TailscaleApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var vpnManager = VPNManager()
    @StateObject private var appState = AppState()
    @State private var didHandleDebugArguments = false

    private func refreshForegroundState() {
        appState.vpnManager = vpnManager
        Task { @MainActor in
            _ = await vpnManager.refreshStatus()
            appState.loadSharedState()
            appState.foregroundResume(vpnActive: vpnManager.isTunnelActive)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vpnManager)
                .environmentObject(appState)
                .onAppear {
                    refreshForegroundState()
                    #if DEBUG
                    if !didHandleDebugArguments,
                       ProcessInfo.processInfo.arguments.contains("-AutoStartLogin") {
                        didHandleDebugArguments = true
                        appState.startLogin()
                    }
                    #endif
                }
                .onChange(of: scenePhase) { phase in
                    if phase == .active {
                        refreshForegroundState()
                    }
                }
        }
    }
}
