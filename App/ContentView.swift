import SwiftUI
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
        .background(
            LoginWebAuthenticationPresenter(
                url: appState.isLoggingIn
                    ? appState.browseToURL.flatMap(URL.init(string:))
                    : nil
            ) { _, error in
                if let error {
                    let nsError = error as NSError
                    if nsError.domain == ASWebAuthenticationSessionError.errorDomain,
                       nsError.code == ASWebAuthenticationSessionError.Code.canceledLogin.rawValue {
                        appState.loginBrowserDidDismiss()
                    } else {
                        appState.loginBrowserDidFail(error)
                    }
                } else {
                    appState.loginBrowserDidDismiss()
                }
            }
            .frame(width: 0, height: 0)
        )
        .fullScreenCover(isPresented: Binding(
            get: { appState.isInAppExitNodePickerPresented },
            set: { presented in
                if !presented {
                    appState.dismissInAppExitNodePicker()
                }
            }
        )) {
            NavigationView {
                ExitNodeView(showsAllowLANAccess: false)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") {
                                appState.dismissInAppExitNodePicker()
                            }
                        }
                    }
            }
            .environmentObject(appState)
        }
        .fullScreenCover(isPresented: Binding(
            get: { appState.isInAppBrowserPresented },
            set: { presented in
                if !presented {
                    appState.dismissInAppBrowser()
                }
            }
        )) {
            TailnetBrowserView()
                .environmentObject(appState)
        }
        .fullScreenCover(item: Binding(
            get: { appState.inAppTerminalPresentation },
            set: { presentation in
                if presentation == nil {
                    appState.dismissInAppTerminal()
                }
            }
        )) { presentation in
            TailnetTerminalView(
                initialHost: presentation.initialHost,
                initialPort: presentation.initialPort,
                sshHint: presentation.sshHint,
                autoConnectInitialHost: presentation.autoConnectInitialHost
            )
            .environmentObject(appState)
        }
    }
}

/// Presents login with the system web-authentication UI used for OAuth flows.
/// Backend `LoginFinished` remains authoritative; a browser callback or user
/// dismissal only starts completion polling.
private struct LoginWebAuthenticationPresenter: UIViewControllerRepresentable {
    let url: URL?
    let onCompletion: (URL?, Error?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> PresentationViewController {
        let viewController = PresentationViewController()
        context.coordinator.presentationViewController = viewController
        viewController.onDidAppear = { [weak coordinator = context.coordinator] in
            coordinator?.startIfPossible()
        }
        return viewController
    }

    func updateUIViewController(_ uiViewController: PresentationViewController, context: Context) {
        context.coordinator.update(url: url, onCompletion: onCompletion)
    }

    static func dismantleUIViewController(
        _ uiViewController: PresentationViewController,
        coordinator: Coordinator
    ) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
        weak var presentationViewController: UIViewController?

        private var requestedURL: URL?
        private var activeSessionID: UUID?
        private var session: ASWebAuthenticationSession?
        private var onCompletion: ((URL?, Error?) -> Void)?

        func update(url: URL?, onCompletion: @escaping (URL?, Error?) -> Void) {
            self.onCompletion = onCompletion
            guard requestedURL != url else { return }

            requestedURL = url
            stop()
            startIfPossible()
        }

        func startIfPossible() {
            guard session == nil,
                  let url = requestedURL,
                  presentationViewController?.viewIfLoaded?.window != nil else {
                return
            }

            let sessionID = UUID()
            let authSession = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: nil
            ) { [weak self] callbackURL, error in
                DispatchQueue.main.async {
                    self?.complete(
                        sessionID: sessionID,
                        callbackURL: callbackURL,
                        error: error
                    )
                }
            }
            authSession.presentationContextProvider = self
            authSession.prefersEphemeralWebBrowserSession = false

            activeSessionID = sessionID
            session = authSession

            guard authSession.start() else {
                activeSessionID = nil
                session = nil
                onCompletion?(
                    nil,
                    NSError(
                        domain: "AwgScale.WebAuthentication",
                        code: 1,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "The system authentication session could not be started."
                        ]
                    )
                )
                return
            }
        }

        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            presentationViewController?.view.window ?? ASPresentationAnchor()
        }

        func stop() {
            activeSessionID = nil
            session?.cancel()
            session = nil
        }

        private func complete(sessionID: UUID, callbackURL: URL?, error: Error?) {
            guard activeSessionID == sessionID else { return }

            activeSessionID = nil
            session = nil
            onCompletion?(callbackURL, error)
        }
    }

    final class PresentationViewController: UIViewController {
        var onDidAppear: (() -> Void)?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onDidAppear?()
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
