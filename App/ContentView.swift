import SwiftUI
import SafariServices
import AuthenticationServices

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var vpnManager: VPNManager

    var body: some View {
        Group {
            if appState.isLoggingIn && !appState.isAwaitingMachineAuth {
                LoginView()
            } else if appState.isAwaitingMachineAuth {
                MachineAuthView()
            } else if appState.shouldShowLoginView {
                LoginView()
            } else {
                MainView()
            }
        }
        .sheet(isPresented: Binding(
            get: { appState.isLoggingIn && appState.browseToURL != nil },
            set: { presented in
                if !presented && appState.isLoggingIn {
                    appState.loginBrowserDidDismiss()
                }
            }
        ), onDismiss: {
            if appState.isLoggingIn {
                appState.loginBrowserDidDismiss()
            }
        }) {
            if let urlStr = appState.browseToURL, let url = URL(string: urlStr) {
                SafariView(url: url) {
                    appState.cancelLogin()
                }
            }
        }
    }
}

/// Wraps SFSafariViewController for SwiftUI.
/// Used for the login OAuth flow. Login completion is signaled by
/// Notify.LoginFinished from the Go backend, NOT by a URL callback.
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let vc = SFSafariViewController(url: url)
        vc.preferredControlTintColor = .systemBlue
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            onFinish()
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(AppState())
            .environmentObject(VPNManager())
    }
}
