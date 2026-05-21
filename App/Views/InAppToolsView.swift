import SwiftUI
import WebKit
import Network
import Security
import UIKit

struct InAppToolsView: View {
    @EnvironmentObject var appState: AppState

    private var currentExitNode: PeerNode? {
        guard let exitID = appState.effectiveExitNodeID, !exitID.isEmpty else { return nil }
        return appState.peers.first { $0.id == exitID }
    }

    var body: some View {
        List {
            if BrowserRuntime.supportsLiveProxy {
                Section {
                    Button {
                        appState.presentInAppExitNodePicker()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 36, height: 36)
                                .background(Color.orange)
                                .cornerRadius(8)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Use Exit Node")
                                    .font(.headline)
                                Text(currentExitNode?.exitNodeDisplayName ?? "Off")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .disabled(!appState.appNetworkIsActive)
                    .opacity(appState.appNetworkIsActive ? 1 : 0.45)
                } footer: {
                    Text("When enabled, built-in apps can route internet connections through the selected exit node.")
                }
            }

            Section {
                if BrowserRuntime.supportsLiveProxy {
                    Button {
                        appState.presentInAppBrowser()
                    } label: {
                        InAppToolRow(
                            title: "Browser",
                            subtitle: "Open HTTP services on your tailnet",
                            systemImage: "safari",
                            color: .blue
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!appState.appNetworkIsActive)
                    .opacity(appState.appNetworkIsActive ? 1 : 0.45)
                }

                Button {
                    appState.presentInAppTerminal()
                } label: {
                    InAppToolRow(
                        title: "Terminal",
                        subtitle: "SSH into devices on your tailnet",
                        systemImage: "terminal",
                        color: .green
                    )
                }
                .buttonStyle(.plain)
                .disabled(!appState.appNetworkIsActive)
                .opacity(appState.appNetworkIsActive ? 1 : 0.45)
            } footer: {
                if !appState.appNetworkIsActive {
                    Text("Connect in app-only mode to use built-in apps.")
                } else if !BrowserRuntime.supportsLiveProxy {
                    Text("Browser and built-in app exit nodes require iOS 17 or later. Terminal can still connect to tailnet hosts such as 100.x.y.z.")
                }
            }
        }
        .navigationTitle("Built-in Apps")
    }
}

private struct InAppToolRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 36, height: 36)
                .background(color)
                .cornerRadius(8)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private enum BrowserRuntime {
    static var supportsLiveProxy: Bool {
        if #available(iOS 17.0, *) {
            return true
        }
        return false
    }

    static var unsupportedMessage: String {
        "Browser requires iOS 17 or later because live WKWebView proxying is only available there. Use Terminal for SSH and tailnet TCP hosts on older iOS versions."
    }
}

struct TailnetBrowserView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var tabs: [BrowserTab] = [BrowserTab.blank()]
    @State private var activeTabIndex = 0
    @State private var address = ""
    @State private var browserProxy: InAppBrowserProxy?
    @StateObject private var webNavigation = BrowserWebNavigation()
    @State private var history: [BrowserHistoryItem] = []
    @State private var bookmarks: [BrowserBookmark] = []
    @State private var showingHistory = false
    @State private var showingBookmarks = false
    @State private var showingTabs = false
    @State private var isLoading = false
    @State private var browserChromeCollapsed = false
    @State private var showingCloseConfirmation = false
    @State private var isAddressEditing = false
    @State private var addressFieldFocused = false
    @State private var addressSelectionToken = 0
    @State private var addressCursorEndToken = 0
    @State private var didLoadPersistedState = false

    private var activeTab: BrowserTab {
        guard tabs.indices.contains(activeTabIndex) else { return BrowserTab.blank() }
        return tabs[activeTabIndex]
    }

    private var activeURL: String {
        if activeTab.page != nil,
           let currentURL = webNavigation.currentURL,
           let scheme = currentURL.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return sanitizedBrowserURL(currentURL.absoluteString)
        }
        return sanitizedBrowserURL(activeTab.url)
    }

    private var isStartPage: Bool {
        activeTab.page == nil
    }

    private var shouldShowExpandedAddressBar: Bool {
        isStartPage || isAddressEditing
    }

    private var shouldShowBottomBar: Bool {
        isStartPage || !browserChromeCollapsed || isAddressEditing
    }

    private var collapsedAddressLabel: String {
        let url = activeURL
        guard !url.isEmpty else { return "Enter address" }
        return URL(string: url)?.host ?? url
    }

    var body: some View {
        Group {
            if BrowserRuntime.supportsLiveProxy {
                ZStack(alignment: .bottom) {
                    browserMainContent

                    if shouldShowBottomBar {
                        browserBottomBar
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .background(Color(uiColor: .systemGroupedBackground))
            } else {
                InAppEmptyState(systemImage: "safari", title: "Browser Requires iOS 17", message: BrowserRuntime.unsupportedMessage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(BrowserRuntime.supportsLiveProxy ? "" : "Browser")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(BrowserRuntime.supportsLiveProxy)
        .navigationBarHidden(BrowserRuntime.supportsLiveProxy)
        .sheet(isPresented: $showingHistory) {
            BrowserHistorySheet(history: history, onSelect: { url in
                showingHistory = false
                openURL(url)
            }, onClear: {
                history = []
                saveHistory()
            })
        }
        .sheet(isPresented: $showingBookmarks) {
            BrowserBookmarkSheet(bookmarks: bookmarks, onSelect: { url in
                showingBookmarks = false
                openURL(url)
            }, onDelete: { bookmark in
                bookmarks.removeAll { $0.id == bookmark.id }
                saveBookmarks()
            })
        }
        .sheet(isPresented: $showingTabs) {
            BrowserTabsSheet(
                tabs: tabs,
                activeIndex: activeTabIndex,
                onSelect: { index in
                    showingTabs = false
                    selectTab(index)
                },
                onClose: closeTab,
                onAdd: addTab
            )
        }
        .alert("Close Browser?", isPresented: $showingCloseConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Close", role: .destructive) {
                dismiss()
            }
        } message: {
            Text("This will close the current browser view. Your tabs and history will stay saved.")
        }
        .onAppear {
            if !didLoadPersistedState {
                didLoadPersistedState = true
                loadPersistedBrowserState()
            }
        }
        .onChange(of: addressFieldFocused) { focused in
            guard !focused, activeTab.page != nil, isAddressEditing else { return }
            cancelAddressEditing()
        }
        .onReceive(webNavigation.$currentURL) { currentURL in
            guard !addressFieldFocused,
                  let currentURL,
                  let scheme = currentURL.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return }
            let nextURL = sanitizedBrowserURL(currentURL.absoluteString)
            address = nextURL
            if tabs.indices.contains(activeTabIndex) {
                tabs[activeTabIndex].url = nextURL
                tabs[activeTabIndex].title = BrowserTab.title(for: nextURL)
            }
        }
    }

    @ViewBuilder
    private var browserMainContent: some View {
        Group {
            if isLoading {
                ProgressView("Loading...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let page = activeTab.page {
                BrowserContentView(
                    page: page,
                    proxy: browserProxy,
                    navigation: webNavigation,
                    chromeCollapsed: browserChromeCollapsed,
                    bottomContentInset: webContentBottomInset,
                    onChromeCollapsedChange: setBrowserChromeCollapsed,
                    onLoadFailed: handleWebNavigationFailure
                )
            } else {
                BrowserStartPage(
                    bookmarks: Array(bookmarks.prefix(8)),
                    history: Array(history.prefix(6)),
                    errorMessage: activeTab.errorMessage,
                    onSelectBookmark: openURL,
                    onSelectHistory: openURL,
                    onShowBookmarks: {
                        showingBookmarks = true
                    },
                    onShowHistory: {
                        showingHistory = true
                    },
                    onShowTabs: showTabs
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var browserBottomBar: some View {
        Group {
            if shouldShowExpandedAddressBar {
                expandedAddressBar
            } else {
                collapsedBrowserBottomBar
            }
        }
        .frame(maxWidth: .infinity)
        .foregroundColor(.primary)
        .padding(.horizontal, shouldShowExpandedAddressBar ? 16 : 10)
        .padding(.top, 10)
        .padding(.bottom, isStartPage ? 10 : 28)
        .background(.ultraThinMaterial)
        .shadow(color: Color.black.opacity(0.12), radius: 14, x: 0, y: -4)
        .animation(.easeInOut(duration: 0.18), value: browserChromeCollapsed)
        .animation(.easeInOut(duration: 0.18), value: shouldShowExpandedAddressBar)
    }

    private var webContentBottomInset: CGFloat {
        guard activeTab.page != nil, shouldShowBottomBar else { return 0 }
        return shouldShowExpandedAddressBar ? 104 : 92
    }

    private var expandedAddressBar: some View {
        HStack(spacing: 12) {
            if isStartPage {
                Button {
                    requestCloseBrowser()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 34, height: 42)
                }
                .accessibilityLabel("Close Browser")
            }

            HStack(spacing: 10) {
                Image(systemName: "globe")
                    .foregroundColor(.secondary)

                BrowserAddressTextField(
                    text: $address,
                    isFocused: $addressFieldFocused,
                    placeholder: "Enter address",
                    selectionToken: addressSelectionToken,
                    cursorEndToken: addressCursorEndToken,
                    onSubmit: commitAddressEntry
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 24)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .layoutPriority(1)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .clipped()

            if !isStartPage {
                Button("Cancel") {
                    cancelAddressEditing()
                }
                .font(.body.weight(.medium))
                .foregroundColor(.primary)
            }
        }
    }

    private var collapsedBrowserBottomBar: some View {
        HStack(spacing: 10) {
            Button {
                goBackOrDismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 34, height: 42)
            }
            .disabled(!webNavigation.canGoBack)
            .accessibilityLabel("Back")

            Button {
                requestCloseBrowser()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 34, height: 42)
            }
            .accessibilityLabel("Close Browser")

            Button {
                beginAddressEditing(selectAll: false)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                        .foregroundColor(.secondary)
                    Text(collapsedAddressLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .frame(height: 42)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit Address")

            Button {
                webNavigation.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 34, height: 42)
            }
            .accessibilityLabel("Reload")

            Button {
                showTabs()
            } label: {
                ZStack(alignment: .center) {
                    Image(systemName: "square.on.square")
                        .font(.system(size: 18, weight: .medium))
                    Text("\(tabs.count)")
                        .font(.system(size: 9, weight: .bold))
                        .offset(y: -1)
                }
                .frame(width: 34, height: 42)
            }
            .accessibilityLabel("Tabs")

            Menu {
                Button {
                    addBookmark()
                } label: {
                    Label(isBookmarked(activeURL) ? "Bookmarked" : "Bookmark", systemImage: isBookmarked(activeURL) ? "star.fill" : "star")
                }
                .disabled(activeURL.isEmpty || isBookmarked(activeURL))

                Button {
                    showingHistory = true
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }

                Button {
                    showingBookmarks = true
                } label: {
                    Label("Bookmarks", systemImage: "book")
                }

                Button {
                    addTab()
                } label: {
                    Label("New Tab", systemImage: "plus")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 34, height: 42)
            }
            .accessibilityLabel("More")
        }
    }

    private func showTabs() {
        captureActiveTabSnapshot()
        showingTabs = true
    }

    private func requestCloseBrowser() {
        guard activeTab.page != nil else {
            dismiss()
            return
        }
        showingCloseConfirmation = true
    }

    private func captureActiveTabSnapshot() {
        guard tabs.indices.contains(activeTabIndex), activeTab.page != nil else { return }
        let index = activeTabIndex
        webNavigation.takeSnapshot { image in
            guard let data = image?.jpegData(compressionQuality: 0.62) else { return }
            DispatchQueue.main.async {
                guard tabs.indices.contains(index) else { return }
                tabs[index].snapshotData = data
            }
        }
    }

    private func loadPage(from rawURL: String? = nil) {
        guard BrowserRuntime.supportsLiveProxy else {
            if tabs.indices.contains(activeTabIndex) {
                tabs[activeTabIndex].errorMessage = BrowserRuntime.unsupportedMessage
            }
            return
        }
        guard appState.appNetworkIsActive else { return }
        let target = sanitizedBrowserURL(rawURL ?? activeURL)
        guard !target.isEmpty, target != "http://", target != "https://" else { return }

        webNavigation.reset()
        setBrowserChromeCollapsed(false, animated: false)

        if tabs.indices.contains(activeTabIndex) {
            tabs[activeTabIndex].url = target
            tabs[activeTabIndex].errorMessage = nil
        }
        isLoading = true
        let loadingIndex = activeTabIndex

        Task {
            do {
                let proxy = try await appState.inAppBrowserProxy()
                let loadedPage = InAppBrowserPage.liveProxy(url: target)
                await MainActor.run {
                    guard tabs.indices.contains(loadingIndex) else { return }
                    browserProxy = proxy
                    tabs[loadingIndex].page = loadedPage
                    tabs[loadingIndex].url = loadedPage.url
                    tabs[loadingIndex].title = BrowserTab.title(for: loadedPage.url)
                    tabs[loadingIndex].errorMessage = nil
                    address = loadedPage.url
                    addHistory(url: loadedPage.url, title: tabs[loadingIndex].title)
                    saveTabs()
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    if tabs.indices.contains(loadingIndex) {
                        tabs[loadingIndex].errorMessage = error.localizedDescription
                    }
                    isLoading = false
                }
            }
        }
    }

    private func selectTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeTabIndex = index
        address = sanitizedBrowserURL(tabs[index].url)
        webNavigation.reset()
        isAddressEditing = false
        addressFieldFocused = false
        setBrowserChromeCollapsed(false, animated: false)
    }

    private func addTab() {
        tabs.append(BrowserTab.blank())
        activeTabIndex = tabs.count - 1
        address = ""
        webNavigation.reset()
        isAddressEditing = false
        addressFieldFocused = false
        setBrowserChromeCollapsed(false, animated: false)
        saveTabs()
    }

    private func closeTab(_ index: Int) {
        guard tabs.count > 1, tabs.indices.contains(index) else { return }
        tabs.remove(at: index)
        activeTabIndex = min(activeTabIndex, tabs.count - 1)
        webNavigation.reset()
        isAddressEditing = false
        addressFieldFocused = false
        setBrowserChromeCollapsed(false, animated: false)
        saveTabs()
        if tabs.indices.contains(activeTabIndex) {
            address = sanitizedBrowserURL(tabs[activeTabIndex].url)
        }
    }

    private func openURL(_ url: String) {
        let url = sanitizedBrowserURL(url)
        addressFieldFocused = false
        isAddressEditing = false
        if tabs.indices.contains(activeTabIndex) {
            tabs[activeTabIndex].url = url
            tabs[activeTabIndex].title = BrowserTab.title(for: url)
            tabs[activeTabIndex].page = nil
            tabs[activeTabIndex].errorMessage = nil
        }
        address = url
        loadPage(from: url)
    }

    private func goBackOrDismiss() {
        if webNavigation.canGoBack {
            webNavigation.goBack()
        } else {
            requestCloseBrowser()
        }
    }

    private func setBrowserChromeCollapsed(_ collapsed: Bool) {
        setBrowserChromeCollapsed(collapsed, animated: true)
    }

    private func beginAddressEditing(selectAll: Bool) {
        address = activeURL.isEmpty ? address : activeURL
        isAddressEditing = true
        requestAddressFocus(selectAll: selectAll)
    }

    private func endAddressEditing(resetToCurrent: Bool) {
        if resetToCurrent {
            address = activeURL
        }
        addressFieldFocused = false
        isAddressEditing = false
    }

    private func commitAddressEntry() {
        let target = address
        addressFieldFocused = false
        isAddressEditing = false
        loadPage(from: target)
    }

    private func cancelAddressEditing() {
        endAddressEditing(resetToCurrent: true)
        guard activeTab.page != nil else { return }
        setBrowserChromeCollapsed(true)
    }

    private func handleWebNavigationFailure(_ message: String) {
        guard tabs.indices.contains(activeTabIndex) else { return }
        tabs[activeTabIndex].errorMessage = message
        tabs[activeTabIndex].page = nil
        setBrowserChromeCollapsed(false, animated: false)
    }

    private func requestAddressFocus(selectAll: Bool) {
        if selectAll {
            addressSelectionToken += 1
        } else {
            addressCursorEndToken += 1
        }
        DispatchQueue.main.async {
            addressFieldFocused = true
        }
    }

    private func setBrowserChromeCollapsed(_ collapsed: Bool, animated: Bool) {
        guard activeTab.page != nil || !collapsed else { return }
        guard browserChromeCollapsed != collapsed else { return }

        if animated {
            withAnimation(.easeInOut(duration: 0.18)) {
                browserChromeCollapsed = collapsed
            }
        } else {
            browserChromeCollapsed = collapsed
        }
    }

    private func addBookmark() {
        let url = activeURL
        guard !url.isEmpty, !isBookmarked(url) else { return }
        bookmarks.insert(BrowserBookmark(url: url, title: activeTab.title), at: 0)
        saveBookmarks()
    }

    private func addHistory(url: String, title: String) {
        history.removeAll { $0.url == url }
        history.insert(BrowserHistoryItem(url: url, title: title, date: Date()), at: 0)
        if history.count > 50 {
            history.removeLast(history.count - 50)
        }
        saveHistory()
    }

    private func isBookmarked(_ url: String) -> Bool {
        bookmarks.contains { $0.url == url }
    }

    private func loadPersistedBrowserState() {
        history = BrowserStorage.load([BrowserHistoryItem].self, key: BrowserStorage.historyKey) ?? []
        bookmarks = BrowserStorage.load([BrowserBookmark].self, key: BrowserStorage.bookmarksKey) ?? []
        if let storedTabs = BrowserStorage.load([StoredBrowserTab].self, key: BrowserStorage.tabsKey), !storedTabs.isEmpty {
            tabs = storedTabs.map { BrowserTab(title: $0.title, url: sanitizedBrowserURL($0.url)) }
            activeTabIndex = 0
            address = sanitizedBrowserURL(tabs[0].url)
        }
    }

    private func sanitizedBrowserURL(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != "http://", trimmed != "https://" else { return "" }
        guard !trimmed.isEmpty else { return "" }
        if trimmed.contains("://") {
            return trimmed
        }
        return "\(defaultScheme(for: trimmed))://\(trimmed)"
    }

    private func defaultScheme(for rawURL: String) -> String {
        let host = URLHostParser.host(from: rawURL)
        return URLHostParser.shouldDefaultToHTTP(host: host) ? "http" : "https"
    }

    private func saveHistory() {
        BrowserStorage.save(history, key: BrowserStorage.historyKey)
    }

    private func saveBookmarks() {
        BrowserStorage.save(bookmarks, key: BrowserStorage.bookmarksKey)
    }

    private func saveTabs() {
        BrowserStorage.save(tabs.map { StoredBrowserTab(title: $0.title, url: sanitizedBrowserURL($0.url)) }, key: BrowserStorage.tabsKey)
    }
}

private struct BrowserTab: Identifiable {
    let id: UUID
    var title: String
    var url: String
    var page: InAppBrowserPage?
    var errorMessage: String?
    var snapshotData: Data?

    init(id: UUID = UUID(), title: String, url: String, page: InAppBrowserPage? = nil, errorMessage: String? = nil, snapshotData: Data? = nil) {
        self.id = id
        self.title = title
        self.url = url
        self.page = page
        self.errorMessage = errorMessage
        self.snapshotData = snapshotData
    }

    static func blank() -> BrowserTab {
        BrowserTab(title: "New Tab", url: "")
    }

    static func title(for url: String) -> String {
        guard let host = URL(string: url)?.host, !host.isEmpty else { return url }
        return host
    }

    var displayTitle: String {
        title.isEmpty ? "New Tab" : title
    }
}

private extension InAppBrowserPage {
    static func liveProxy(url: String) -> InAppBrowserPage {
        InAppBrowserPage(
            url: url,
            statusCode: 0,
            headers: [:],
            contentType: "text/html",
            body: "",
            bodyBase64: nil,
            truncated: false
        )
    }
}

private struct StoredBrowserTab: Codable {
    var title: String
    var url: String
}

private enum URLHostParser {
    static func host(from rawURL: String) -> String {
        let head = rawURL.split(whereSeparator: { $0 == "/" || $0 == "?" || $0 == "#" }).first.map(String.init) ?? rawURL
        let authority = head.split(separator: "@").last.map(String.init) ?? head

        if authority.hasPrefix("["),
           let end = authority.firstIndex(of: "]") {
            return String(authority[authority.index(after: authority.startIndex)..<end]).lowercased()
        }

        return authority.split(separator: ":").first.map { String($0).lowercased() } ?? ""
    }

    static func shouldDefaultToHTTP(host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        if normalized == "localhost" || !normalized.contains(".") {
            return true
        }
        if normalized.hasSuffix(".ts.net") || normalized.hasSuffix(".beta.tailscale.net") {
            return true
        }
        if let octets = ipv4Octets(normalized) {
            return isPrivateOrTailnetIPv4(octets)
        }
        return normalized == "::1"
            || normalized.hasPrefix("fe80:")
            || normalized.hasPrefix("fc")
            || normalized.hasPrefix("fd")
    }

    private static func ipv4Octets(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard let value = UInt8(part) else { return nil }
            octets.append(value)
        }
        return octets
    }

    private static func isPrivateOrTailnetIPv4(_ octets: [UInt8]) -> Bool {
        let first = octets[0]
        let second = octets[1]
        if first == 10 || first == 127 {
            return true
        }
        if first == 172 && (16...31).contains(second) {
            return true
        }
        if first == 192 && second == 168 {
            return true
        }
        if first == 100 && (64...127).contains(second) {
            return true
        }
        if first == 169 && second == 254 {
            return true
        }
        return false
    }
}

private final class BrowserWebNavigation: ObservableObject {
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var currentURL: URL?
    private weak var webView: WKWebView?

    func attach(_ webView: WKWebView) {
        self.webView = webView
        update(from: webView)
    }

    func update(from webView: WKWebView) {
        if canGoBack != webView.canGoBack {
            canGoBack = webView.canGoBack
        }
        if canGoForward != webView.canGoForward {
            canGoForward = webView.canGoForward
        }
        if currentURL != webView.url {
            currentURL = webView.url
        }
    }

    func goBack() {
        webView?.goBack()
    }

    func reload() {
        webView?.reload()
    }

    func takeSnapshot(completion: @escaping (UIImage?) -> Void) {
        guard let webView else {
            completion(nil)
            return
        }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        webView.takeSnapshot(with: configuration) { image, _ in
            completion(image)
        }
    }

    func reset() {
        webView = nil
        canGoBack = false
        canGoForward = false
        currentURL = nil
    }
}

private struct BrowserHistoryItem: Codable, Identifiable {
    let id: UUID
    var url: String
    var title: String
    var date: Date

    init(id: UUID = UUID(), url: String, title: String, date: Date) {
        self.id = id
        self.url = url
        self.title = title
        self.date = date
    }
}

private struct BrowserBookmark: Codable, Identifiable {
    let id: UUID
    var url: String
    var title: String

    init(id: UUID = UUID(), url: String, title: String) {
        self.id = id
        self.url = url
        self.title = title
    }
}

private struct BrowserStartPage: View {
    let bookmarks: [BrowserBookmark]
    let history: [BrowserHistoryItem]
    let errorMessage: String?
    let onSelectBookmark: (String) -> Void
    let onSelectHistory: (String) -> Void
    let onShowBookmarks: () -> Void
    let onShowHistory: () -> Void
    let onShowTabs: () -> Void

    private let bookmarkColumns = [GridItem(.adaptive(minimum: 78), spacing: 14)]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Browser")
                        .font(.largeTitle.weight(.bold))

                    Text("Open tailnet hosts, local services, or public websites through the in-app browser.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 12) {
                    BrowserStartQuickAction(title: "Tabs", systemImage: "square.on.square", action: onShowTabs)
                    BrowserStartQuickAction(title: "Bookmarks", systemImage: "book", action: onShowBookmarks)
                    BrowserStartQuickAction(title: "History", systemImage: "clock.arrow.circlepath", action: onShowHistory)
                }

                if let errorMessage, !errorMessage.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Unable to Load", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundColor(.orange)
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }

                if !bookmarks.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        BrowserStartSectionHeader(title: "Latest Bookmarks", actionTitle: bookmarks.count > 6 ? "See All" : nil, action: onShowBookmarks)

                        LazyVGrid(columns: bookmarkColumns, spacing: 16) {
                            ForEach(bookmarks) { bookmark in
                                BrowserStartBookmarkTile(bookmark: bookmark) {
                                    onSelectBookmark(bookmark.url)
                                }
                            }
                        }
                    }
                }

                if !history.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        BrowserStartSectionHeader(title: "Recent History", actionTitle: history.count > 4 ? "See All" : nil, action: onShowHistory)

                        VStack(spacing: 0) {
                            ForEach(Array(history.enumerated()), id: \.element.id) { index, item in
                                Button {
                                    onSelectHistory(item.url)
                                } label: {
                                    HStack(spacing: 14) {
                                        Image(systemName: "clock.arrow.circlepath")
                                            .font(.system(size: 18, weight: .medium))
                                            .foregroundColor(.secondary)
                                            .frame(width: 34, height: 34)
                                            .background(Color(uiColor: .tertiarySystemFill))
                                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(item.title.isEmpty ? (URL(string: item.url)?.host ?? item.url) : item.title)
                                                .font(.body.weight(.medium))
                                                .foregroundColor(.primary)
                                                .lineLimit(1)

                                            Text(item.url)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                        }

                                        Spacer(minLength: 12)

                                        Text(item.date, style: .relative)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 14)
                                }
                                .buttonStyle(.plain)

                                if index < history.count - 1 {
                                    Divider()
                                        .padding(.leading, 64)
                                }
                            }
                        }
                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                }

                if bookmarks.isEmpty && history.isEmpty && errorMessage == nil {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Enter an address below")
                            .font(.headline)
                        Text("Recent bookmarks and history will appear here once you browse a few pages.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 120)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct BrowserStartQuickAction: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .frame(maxWidth: .infinity)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct BrowserStartSectionHeader: View {
    let title: String
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .font(.title3.weight(.semibold))

            Spacer()

            if let actionTitle {
                Button(actionTitle, action: action)
                    .font(.subheadline.weight(.medium))
            }
        }
    }
}

private struct BrowserStartBookmarkTile: View {
    let bookmark: BrowserBookmark
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                        .frame(height: 72)

                    Text(monogram)
                        .font(.title2.weight(.semibold))
                        .foregroundColor(.primary)
                }

                Text(displayTitle)
                    .font(.footnote)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.plain)
    }

    private var displayTitle: String {
        if !bookmark.title.isEmpty {
            return bookmark.title
        }
        return URL(string: bookmark.url)?.host ?? bookmark.url
    }

    private var monogram: String {
        let trimmed = displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "?" : String(trimmed.prefix(1)).uppercased()
    }
}

private struct BrowserAddressTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let placeholder: String
    let selectionToken: Int
    let cursorEndToken: Int
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused, onSubmit: onSubmit)
    }

    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField(frame: .zero)
        textField.delegate = context.coordinator
        textField.addTarget(context.coordinator, action: #selector(Coordinator.textDidChange(_:)), for: .editingChanged)
        textField.keyboardType = .URL
        textField.returnKeyType = .go
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.clearButtonMode = .whileEditing
        textField.adjustsFontForContentSizeCategory = true
        textField.font = UIFont.preferredFont(forTextStyle: .body)
        textField.textColor = .label
        textField.tintColor = .systemBlue
        textField.placeholder = placeholder
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return textField
    }

    func updateUIView(_ textField: UITextField, context: Context) {
        context.coordinator.onSubmit = onSubmit
        if textField.text != text {
            textField.text = text
        }
        if textField.placeholder != placeholder {
            textField.placeholder = placeholder
        }

        if isFocused {
            if !textField.isFirstResponder {
                textField.becomeFirstResponder()
            }
            if context.coordinator.appliedSelectionToken != selectionToken {
                context.coordinator.appliedSelectionToken = selectionToken
                DispatchQueue.main.async {
                    guard textField.isFirstResponder else { return }
                    textField.selectAll(nil)
                }
            }
            if context.coordinator.appliedCursorEndToken != cursorEndToken {
                context.coordinator.appliedCursorEndToken = cursorEndToken
                DispatchQueue.main.async {
                    guard textField.isFirstResponder,
                          let endPosition = textField.position(from: textField.endOfDocument, offset: 0),
                          let endRange = textField.textRange(from: endPosition, to: endPosition) else { return }
                    textField.selectedTextRange = endRange
                }
            }
        } else if textField.isFirstResponder {
            textField.resignFirstResponder()
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        private let text: Binding<String>
        private let isFocused: Binding<Bool>
        var onSubmit: () -> Void
        var appliedSelectionToken = -1
        var appliedCursorEndToken = -1

        init(text: Binding<String>, isFocused: Binding<Bool>, onSubmit: @escaping () -> Void) {
            self.text = text
            self.isFocused = isFocused
            self.onSubmit = onSubmit
        }

        @objc func textDidChange(_ textField: UITextField) {
            text.wrappedValue = textField.text ?? ""
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            isFocused.wrappedValue = true
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            text.wrappedValue = textField.text ?? ""
            isFocused.wrappedValue = false
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            text.wrappedValue = textField.text ?? ""
            onSubmit()
            return false
        }
    }
}

private struct BrowserTabsSheet: View {
    let tabs: [BrowserTab]
    let activeIndex: Int
    let onSelect: (Int) -> Void
    let onClose: (Int) -> Void
    let onAdd: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.33, green: 0.08, blue: 0.18),
                        Color(red: 0.09, green: 0.17, blue: 0.42)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    ScrollView {
                        LazyVGrid(columns: gridColumns, spacing: 24) {
                            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                                BrowserTabPreviewCard(
                                    tab: tab,
                                    isActive: index == activeIndex,
                                    canClose: tabs.count > 1,
                                    onSelect: {
                                        onSelect(index)
                                        dismiss()
                                    },
                                    onClose: {
                                        onClose(index)
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 24)
                        .padding(.bottom, 110)
                    }

                    HStack(spacing: 14) {
                        Button {
                            onAdd()
                            dismiss()
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 26, weight: .medium))
                                .foregroundColor(.white)
                                .frame(width: 58, height: 58)
                                .background(Color.white.opacity(0.10))
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Color.blue.opacity(0.55), lineWidth: 2))
                        }
                        .accessibilityLabel("New tab")

                        Spacer()

                        Text("\(tabs.count) \(tabs.count == 1 ? "Tab" : "Tabs")")
                            .font(.headline.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 20)
                            .frame(height: 48)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .background(Color.white.opacity(0.10))
                            .cornerRadius(24)
                            .overlay(
                                RoundedRectangle(cornerRadius: 24)
                                    .stroke(Color.blue.opacity(0.55), lineWidth: 1)
                            )

                        Spacer()

                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "checkmark")
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 58, height: 58)
                                .background(Color.blue.opacity(0.72))
                                .clipShape(Circle())
                        }
                        .accessibilityLabel("Done")
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                    .background(.ultraThinMaterial)
                }
            }
            .navigationBarHidden(true)
        }
    }

    private var gridColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 18),
            GridItem(.flexible(), spacing: 18)
        ]
    }
}

private struct BrowserTabPreviewCard: View {
    let tab: BrowserTab
    let isActive: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                preview
                    .aspectRatio(0.54, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 190)
                    .background(Color(uiColor: .systemBackground))
                    .cornerRadius(16)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(isActive ? Color.blue : Color.white.opacity(0.18), lineWidth: isActive ? 3 : 1)
                    )
                    .clipped()
                    .contentShape(RoundedRectangle(cornerRadius: 16))
                    .onTapGesture(perform: onSelect)

                if canClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 34, height: 34)
                            .background(Color.black.opacity(0.62))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .accessibilityLabel("Close tab")
                }
            }

            Button(action: onSelect) {
                HStack(spacing: 8) {
                    Image(systemName: tab.errorMessage == nil ? "globe" : "exclamationmark.triangle")
                        .foregroundColor(.white.opacity(0.82))
                    Text(tab.displayTitle)
                        .font(.headline)
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let snapshotData = tab.snapshotData,
           let image = UIImage(data: snapshotData) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            VStack(spacing: 14) {
                Image(systemName: tab.errorMessage == nil ? "safari" : "exclamationmark.triangle")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundColor(.secondary)

                Text(tab.errorMessage == nil ? previewURL : "Webpage Crashed")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                if let errorMessage = tab.errorMessage {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemBackground))
        }
    }

    private var previewURL: String {
        tab.url.isEmpty ? "New Tab" : tab.url
    }
}

private struct BrowserHistorySheet: View {
    let history: [BrowserHistoryItem]
    let onSelect: (String) -> Void
    let onClear: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                if history.isEmpty {
                    Text("No history yet")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(history) { item in
                        Button {
                            onSelect(item.url)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title)
                                    .foregroundColor(.primary)
                                Text(item.url)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Clear", action: onClear)
                        .disabled(history.isEmpty)
                }
            }
        }
    }
}

private struct BrowserBookmarkSheet: View {
    let bookmarks: [BrowserBookmark]
    let onSelect: (String) -> Void
    let onDelete: (BrowserBookmark) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                if bookmarks.isEmpty {
                    Text("No bookmarks yet")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(bookmarks) { bookmark in
                        Button {
                            onSelect(bookmark.url)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(bookmark.title)
                                    .foregroundColor(.primary)
                                Text(bookmark.url)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                onDelete(bookmark)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Bookmarks")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private enum BrowserStorage {
    static let historyKey = "top.yesican.awgscale.inapp.browser.history.v1"
    static let bookmarksKey = "top.yesican.awgscale.inapp.browser.bookmarks.v1"
    static let tabsKey = "top.yesican.awgscale.inapp.browser.tabs.v1"

    static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

private struct BrowserContentView: View {
    let page: InAppBrowserPage
    let proxy: InAppBrowserProxy?
    @ObservedObject var navigation: BrowserWebNavigation
    let chromeCollapsed: Bool
    let bottomContentInset: CGFloat
    let onChromeCollapsedChange: (Bool) -> Void
    let onLoadFailed: (String) -> Void

    var body: some View {
        WebContentView(
            url: URL(string: page.url),
            proxy: proxy,
            chromeCollapsed: chromeCollapsed,
            navigation: navigation,
            bottomContentInset: bottomContentInset,
            onChromeCollapsedChange: onChromeCollapsedChange,
            onLoadFailed: onLoadFailed
        )
        .id("\(page.url)|\(proxy?.address ?? "direct")")
    }
}

private struct WebContentView: UIViewRepresentable {
    let url: URL?
    let proxy: InAppBrowserProxy?
    let chromeCollapsed: Bool
    @ObservedObject var navigation: BrowserWebNavigation
    let bottomContentInset: CGFloat
    let onChromeCollapsedChange: (Bool) -> Void
    let onLoadFailed: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(navigation: navigation, onChromeCollapsedChange: onChromeCollapsedChange, onLoadFailed: onLoadFailed)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        if #available(iOS 17.0, *), let proxy {
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(proxy.host),
                port: NWEndpoint.Port(integerLiteral: UInt16(proxy.port))
            )
            let proxyConfiguration = ProxyConfiguration(socksv5Proxy: endpoint)
            let dataStore = WKWebsiteDataStore.nonPersistent()
            dataStore.proxyConfigurations = [proxyConfiguration]
            configuration.websiteDataStore = dataStore
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.scrollView.delegate = context.coordinator
        context.coordinator.attach(webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onChromeCollapsedChange = onChromeCollapsedChange
        context.coordinator.onLoadFailed = onLoadFailed
        context.coordinator.attach(webView)
        context.coordinator.syncChromeCollapsed(chromeCollapsed)
        context.coordinator.syncBottomContentInset(bottomContentInset)

        let key = loadKey
        guard context.coordinator.loadedKey != key else { return }
        context.coordinator.loadedKey = key

        if #available(iOS 17.0, *), proxy != nil, let url {
            webView.load(URLRequest(url: url, timeoutInterval: 18))
        } else {
            webView.loadHTMLString("", baseURL: nil)
        }
    }

    private var loadKey: String {
        if #available(iOS 17.0, *), let proxy, let url {
            return "url:\(url.absoluteString)|proxy:\(proxy.address)"
        }
        return "unsupported"
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, UIScrollViewDelegate {
        private let navigation: BrowserWebNavigation
        var onChromeCollapsedChange: (Bool) -> Void
        var onLoadFailed: (String) -> Void
        var loadedKey: String?
        private weak var webView: WKWebView?
        private var observations: [NSKeyValueObservation] = []
        private var lastScrollY: CGFloat = 0
        private var accumulatedScrollDelta: CGFloat = 0
        private var chromeCollapsed = false
        private var bottomContentInset: CGFloat = 0
        private var bottomRevealLocked = false
        private var ignoreScrollChromeUntil = Date.distantPast

        init(navigation: BrowserWebNavigation, onChromeCollapsedChange: @escaping (Bool) -> Void, onLoadFailed: @escaping (String) -> Void) {
            self.navigation = navigation
            self.onChromeCollapsedChange = onChromeCollapsedChange
            self.onLoadFailed = onLoadFailed
        }

        func attach(_ webView: WKWebView) {
            guard self.webView !== webView else {
                publishNavigationState(webView)
                return
            }

            self.webView = webView
            applyBottomContentInset(to: webView.scrollView)
            observations.removeAll()
            observations = [
                webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] webView, _ in
                    self?.publishNavigationState(webView)
                },
                webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] webView, _ in
                    self?.publishNavigationState(webView)
                }
            ]
            publishNavigationState(webView)
        }

        func syncChromeCollapsed(_ collapsed: Bool) {
            chromeCollapsed = collapsed
        }

        func syncBottomContentInset(_ bottomContentInset: CGFloat) {
            self.bottomContentInset = bottomContentInset
            guard let webView else { return }
            applyBottomContentInset(to: webView.scrollView)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            loadedKey = nil
            webView.reload()
            publishNavigationState(webView)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            publishNavigationState(webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            publishNavigationState(webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            publishNavigationState(webView)
            handleNavigationError(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            publishNavigationState(webView)
            handleNavigationError(error)
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            lastScrollY = normalizedOffsetY(scrollView)
            accumulatedScrollDelta = 0
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let y = normalizedOffsetY(scrollView)
            defer { lastScrollY = y }

            if Date() < ignoreScrollChromeUntil {
                accumulatedScrollDelta = 0
                return
            }

            let maxY = maxScrollY(scrollView)
            if y < 6 {
                bottomRevealLocked = false
                setChromeCollapsed(false)
                accumulatedScrollDelta = 0
                return
            }
            if y >= maxY - 10 {
                bottomRevealLocked = true
                setChromeCollapsed(false)
                accumulatedScrollDelta = 0
                return
            }
            if bottomRevealLocked {
                if y < maxY - 96 {
                    bottomRevealLocked = false
                } else {
                    accumulatedScrollDelta = 0
                    return
                }
            }

            let delta = y - lastScrollY
            guard abs(delta) > 0.5 else { return }
            if (delta > 0 && accumulatedScrollDelta < 0) || (delta < 0 && accumulatedScrollDelta > 0) {
                accumulatedScrollDelta = 0
            }
            accumulatedScrollDelta += delta

            if accumulatedScrollDelta > 18 {
                setChromeCollapsed(true)
                accumulatedScrollDelta = 0
            } else if accumulatedScrollDelta < -24 {
                setChromeCollapsed(false)
                accumulatedScrollDelta = 0
            }
        }

        private func normalizedOffsetY(_ scrollView: UIScrollView) -> CGFloat {
            scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        }

        private func maxScrollY(_ scrollView: UIScrollView) -> CGFloat {
            let visibleHeight = scrollView.bounds.height - scrollView.adjustedContentInset.top - scrollView.adjustedContentInset.bottom
            return max(0, scrollView.contentSize.height - visibleHeight)
        }

        private func setChromeCollapsed(_ collapsed: Bool) {
            guard chromeCollapsed != collapsed else { return }
            chromeCollapsed = collapsed
            DispatchQueue.main.async { [onChromeCollapsedChange] in
                onChromeCollapsedChange(collapsed)
            }
        }

        private func handleNavigationError(_ error: Error) {
            let nsError = error as NSError
            guard nsError.domain != NSURLErrorDomain || nsError.code != NSURLErrorCancelled else { return }
            DispatchQueue.main.async { [onLoadFailed] in
                onLoadFailed(nsError.localizedDescription)
            }
        }

        private func applyBottomContentInset(to scrollView: UIScrollView) {
            var contentInset = scrollView.contentInset
            guard abs(contentInset.bottom - bottomContentInset) > 0.5 else { return }
            let wasNearBottom = normalizedOffsetY(scrollView) >= maxScrollY(scrollView) - 12
            ignoreScrollChromeUntil = Date().addingTimeInterval(0.28)
            contentInset.bottom = bottomContentInset
            scrollView.contentInset = contentInset
            scrollView.verticalScrollIndicatorInsets.bottom = bottomContentInset
            if wasNearBottom {
                let targetOffsetY = maxScrollY(scrollView) - scrollView.adjustedContentInset.top
                scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: targetOffsetY), animated: false)
            }
        }

        private func publishNavigationState(_ webView: WKWebView) {
            DispatchQueue.main.async { [navigation] in
                navigation.attach(webView)
            }
        }
    }
}

struct TailnetTerminalView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    private let initialSSHHint: String?
    private let autoConnectInitialHost: Bool
    @State private var host: String
    @State private var port: String
    @State private var username = ""
    @State private var password = ""
    @State private var privateKey = ""
    @State private var passphrase = ""
    @State private var authMode: SSHAuthMode = .password
    @State private var saveBookmark = true
    @State private var saveCredentials = true
    @State private var hostSearch = ""
    @State private var bookmarks: [SSHBookmark] = []
    @State private var showingConnectionEditor: Bool
    @State private var terminalKeyboardMode: TerminalKeyboardMode = .system
    @State private var queuedSSHInput = ""
    @State private var lines: [TerminalLine] = []
    @State private var terminalScreen = TerminalScreenBuffer()
    @State private var terminalOutputRevision = 0
    @State private var sessionID: String?
    @State private var isConnected = false
    @State private var isConnecting = false
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var pollTask: Task<Void, Never>?
    @State private var consecutivePollFailures = 0
    @State private var didHandleInitialHost = false

    init(initialHost: String = "", initialPort: Int = 22, sshHint: String? = nil, autoConnectInitialHost: Bool = false) {
        self.initialSSHHint = sshHint
        self.autoConnectInitialHost = autoConnectInitialHost
        _host = State(initialValue: initialHost)
        _port = State(initialValue: "\(initialPort)")
        _showingConnectionEditor = State(initialValue: !initialHost.isEmpty && !autoConnectInitialHost)
    }

    var body: some View {
        Group {
            if isConnected {
                connectedTerminalView
            } else {
                connectionLandingView
            }
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showingConnectionEditor) {
            NavigationView {
                connectionForm
                    .navigationTitle("Connection")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showingConnectionEditor = false }
                        }
                    }
            }
            .accentColor(TerminalTheme.green)
        }
        .onAppear {
            loadBookmarks()
            handleInitialHostIfNeeded()
        }
        .onDisappear {
            disconnect(appendNotice: false)
        }
    }

    private var filteredBookmarks: [SSHBookmark] {
        let query = hostSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return bookmarks }
        return bookmarks.filter { bookmark in
            bookmark.name.lowercased().contains(query)
                || bookmark.host.lowercased().contains(query)
                || bookmark.username.lowercased().contains(query)
        }
    }

    private var connectionLandingView: some View {
        ZStack {
            TerminalTheme.background.ignoresSafeArea()

            VStack(spacing: 16) {
                terminalHostHeader
                terminalSearchBar

                if let errorMessage {
                    terminalStatusBanner(
                        systemImage: "exclamationmark.circle",
                        text: errorMessage,
                        tint: TerminalTheme.error
                    )
                }

                if isConnecting {
                    terminalStatusBanner(
                        systemImage: "hourglass",
                        text: "Connecting to \(username)@\(host)",
                        tint: TerminalTheme.green
                    )
                }

                hostList
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
        }
    }

    private var connectedTerminalView: some View {
        ZStack {
            TerminalTheme.background.ignoresSafeArea()
            TerminalOutputView(
                lines: lines,
                outputRevision: terminalOutputRevision,
                errorMessage: errorMessage
            )
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TerminalInputDock(
                host: host,
                username: username,
                port: port,
                keyboardMode: $terminalKeyboardMode,
                onSendInput: sendKeyboardInput,
                onDisconnect: { disconnect() }
            )
        }
    }

    private var terminalHostHeader: some View {
        ZStack {
            HStack(spacing: 14) {
                Button {
                    dismiss()
                } label: {
                    TerminalRoundIcon(systemName: "chevron.left")
                }
                .accessibilityLabel("Back")

                Spacer()

                Button {
                    prepareNewConnection()
                } label: {
                    TerminalRoundIcon(systemName: "plus")
                }
                .accessibilityLabel("Add connection")

                Menu {
                    Button {
                        prepareNewConnection()
                    } label: {
                        Label("New Connection", systemImage: "plus")
                    }

                    Button {
                        loadBookmarks()
                    } label: {
                        Label("Reload Hosts", systemImage: "arrow.clockwise")
                    }
                } label: {
                    TerminalRoundIcon(systemName: "ellipsis")
                }
            }

            VStack(spacing: 2) {
                Text("Hosts")
                    .font(.title3.weight(.bold))
                    .foregroundColor(.white)
                Text("Personal")
                    .font(.footnote.weight(.medium))
                    .foregroundColor(TerminalTheme.secondaryText)
            }
        }
    }

    private var terminalSearchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))

            TextField("Search", text: $hostSearch)
                .autocapitalization(.none)
                .autocorrectionDisabled()
                .textFieldStyle(.plain)
                .font(.title3.weight(.semibold))
                .foregroundColor(.white)

            if !hostSearch.isEmpty {
                Button {
                    hostSearch = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(TerminalTheme.secondaryText)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
        .background(TerminalTheme.control)
        .cornerRadius(24)
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(TerminalTheme.border.opacity(0.9), lineWidth: 1)
        )
    }

    private var hostList: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Text("Hosts")
                        .font(.headline)
                        .foregroundColor(TerminalTheme.secondaryText)
                    Rectangle()
                        .fill(TerminalTheme.border.opacity(0.28))
                        .frame(height: 1)
                }
                .padding(.top, 8)

                if bookmarks.isEmpty {
                    Button {
                        prepareNewConnection()
                    } label: {
                        TerminalEmptyHostCard(
                            systemImage: "plus.circle.fill",
                            title: "Add Connection",
                            subtitle: "SSH with password or private key"
                        )
                    }
                    .buttonStyle(.plain)
                } else if filteredBookmarks.isEmpty {
                    TerminalEmptyHostCard(
                        systemImage: "magnifyingglass",
                        title: "No Matching Hosts",
                        subtitle: "Try another hostname, IP, or username"
                    )
                } else {
                    ForEach(filteredBookmarks) { bookmark in
                        SSHBookmarkRow(
                            bookmark: bookmark,
                            onSelect: {
                                applyBookmark(bookmark)
                                showingConnectionEditor = true
                            },
                            onConnect: {
                                applyBookmark(bookmark)
                                if bookmark.hasSavedCredential {
                                    connect()
                                } else {
                                    showingConnectionEditor = true
                                }
                            },
                            onDelete: { deleteBookmark(bookmark) }
                        )
                    }
                }
            }
            .padding(.bottom, 28)
        }
    }

    private func terminalStatusBanner(systemImage: String, text: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
            Text(text)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .font(.footnote.weight(.medium))
        .foregroundColor(tint)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TerminalTheme.card)
        .cornerRadius(16)
    }

    private var connectionForm: some View {
        ZStack {
            TerminalTheme.background.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    if let initialSSHHint {
                        terminalStatusBanner(
                            systemImage: "info.circle",
                            text: initialSSHHint,
                            tint: TerminalTheme.secondaryText
                        )
                    }

                    TerminalFormSection(title: "Quick Connect", systemImage: "bolt.horizontal.fill") {
                        TerminalConnectionField(
                            title: "Host",
                            placeholder: "host or 100.x.y.z",
                            text: $host
                        )

                        HStack(spacing: 12) {
                            TerminalConnectionField(
                                title: "Port",
                                placeholder: "22",
                                text: $port,
                                keyboardType: .numberPad
                            )
                            TerminalConnectionField(
                                title: "Username",
                                placeholder: "root",
                                text: $username
                            )
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Auth")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(TerminalTheme.secondaryText)
                            Picker("Auth", selection: $authMode) {
                                ForEach(SSHAuthMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        if authMode == .password {
                            TerminalConnectionField(
                                title: "Password",
                                placeholder: "Required",
                                text: $password,
                                isSecure: true
                            )
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Private Key")
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(TerminalTheme.secondaryText)
                                ZStack(alignment: .topLeading) {
                                    TextEditor(text: $privateKey)
                                        .font(.system(.footnote, design: .monospaced))
                                        .foregroundColor(.white)
                                        .frame(minHeight: 112)
                                        .padding(6)
                                        .background(TerminalTheme.input)
                                        .cornerRadius(14)
                                    if privateKey.isEmpty {
                                        Text("Paste private key")
                                            .font(.footnote)
                                            .foregroundColor(TerminalTheme.secondaryText)
                                            .padding(.top, 14)
                                            .padding(.leading, 12)
                                            .allowsHitTesting(false)
                                    }
                                }
                            }

                            TerminalConnectionField(
                                title: "Passphrase",
                                placeholder: "Optional",
                                text: $passphrase,
                                isSecure: true
                            )
                        }

                        Toggle(isOn: $saveBookmark) {
                            Label("Save host", systemImage: "bookmark")
                                .foregroundColor(.white)
                        }
                        .toggleStyle(SwitchToggleStyle(tint: TerminalTheme.green))

                        Toggle(isOn: $saveCredentials) {
                            Label("Save credentials", systemImage: "key.fill")
                                .foregroundColor(.white)
                        }
                        .toggleStyle(SwitchToggleStyle(tint: TerminalTheme.green))
                        .disabled(!saveBookmark)

                        Button {
                            connect()
                        } label: {
                            HStack {
                                Image(systemName: isConnecting ? "hourglass" : "bolt.horizontal.fill")
                                Text(isConnecting ? "Connecting" : "Connect")
                            }
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(TerminalTheme.green.opacity(canConnect ? 1 : 0.35))
                            .cornerRadius(16)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canConnect)
                    }

                    TerminalFormSection(title: "Saved Hosts", systemImage: "server.rack") {
                        if bookmarks.isEmpty {
                            Text("No saved hosts")
                                .font(.subheadline)
                                .foregroundColor(TerminalTheme.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(Array(bookmarks.prefix(6))) { bookmark in
                                SSHBookmarkRow(
                                    bookmark: bookmark,
                                    onSelect: { applyBookmark(bookmark) },
                                    onConnect: {
                                        applyBookmark(bookmark)
                                        connect()
                                    },
                                    onDelete: { deleteBookmark(bookmark) }
                                )
                            }
                        }
                    }
                }
                .padding(18)
            }
        }
        .disabled(isConnecting)
    }

    private var canConnect: Bool {
        let hasAuth: Bool
        switch authMode {
        case .password:
            hasAuth = !password.isEmpty
        case .privateKey:
            hasAuth = !privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return appState.appNetworkIsActive
            && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasAuth
            && Int(port) != nil
            && !isConnecting
    }

    private var canSend: Bool {
        appState.appNetworkIsActive && isConnected && sessionID != nil
    }

    private func sendKeyboardInput(_ payload: String) {
        send(payload: payload, appendNewline: false, echoInput: false)
    }

    private func connect() {
        guard canConnect, let portNumber = Int(port) else { return }
        let targetHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetPassword = authMode == .password ? password : ""
        let targetPrivateKey = authMode == .privateKey ? privateKey : ""
        let targetPassphrase = authMode == .privateKey ? passphrase : ""

        if saveBookmark {
            do {
                try saveCurrentBookmark(host: targetHost, port: portNumber, username: targetUser)
            } catch {
                lines.append(TerminalLine(kind: .error, text: "Failed to save credentials: \(error.localizedDescription)"))
            }
        }

        isConnecting = true
        errorMessage = nil
        terminalScreen.reset()
        lines = []
        lines.append(TerminalLine(kind: .notice, text: "Connecting to \(targetUser)@\(targetHost):\(portNumber)"))

        Task {
            do {
                let response = try await appState.openInAppSSHSession(
                    host: targetHost,
                    port: portNumber,
                    username: targetUser,
                    password: targetPassword,
                    privateKey: targetPrivateKey,
                    passphrase: targetPassphrase
                )
                await MainActor.run {
                    password = ""
                    privateKey = ""
                    passphrase = ""
                    sessionID = response.sessionID
                    isConnected = response.active
                    isConnecting = false
                    terminalKeyboardMode = .system
                    if response.active {
                        consecutivePollFailures = 0
                        showingConnectionEditor = false
                        lines.append(TerminalLine(kind: .notice, text: "Connected"))
                        appendSSHResponse(response)
                        startPolling(sessionID: response.sessionID)
                    } else {
                        appendSSHResponse(response)
                        lines.append(TerminalLine(kind: .error, text: "SSH session closed immediately"))
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    lines.append(TerminalLine(kind: .error, text: error.localizedDescription))
                    isConnecting = false
                }
            }
        }
    }

    private func send(payload: String, appendNewline: Bool = true, echoInput: Bool = true) {
        guard canSend else { return }
        let inputPayload = appendNewline ? payload + "\n" : payload
        guard !inputPayload.isEmpty else { return }

        if echoInput && !payload.isEmpty {
            lines.append(TerminalLine(kind: .input, text: payload))
        }

        queuedSSHInput += inputPayload
        flushQueuedSSHInput()
    }

    private func flushQueuedSSHInput() {
        guard canSend, !isSending, !queuedSSHInput.isEmpty, let currentSessionID = sessionID else { return }
        isSending = true
        errorMessage = nil
        let inputPayload = queuedSSHInput
        queuedSSHInput = ""

        Task {
            do {
                let response = try await appState.sendInAppSSHInput(sessionID: currentSessionID, input: inputPayload)
                await MainActor.run {
                    appendSSHResponse(response)
                    if !response.active {
                        markDisconnected()
                    }
                    isSending = false
                    flushQueuedSSHInput()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    lines.append(TerminalLine(kind: .error, text: error.localizedDescription))
                    isSending = false
                    flushQueuedSSHInput()
                }
            }
        }
    }

    private func startPolling(sessionID: String) {
        pollTask?.cancel()
        consecutivePollFailures = 0
        pollTask = Task {
            while !Task.isCancelled {
                do {
                    let response = try await appState.readInAppSSHSession(sessionID: sessionID)
                    await MainActor.run {
                        consecutivePollFailures = 0
                        appendSSHResponse(response)
                        if !response.active {
                            markDisconnected()
                        }
                    }
                    if !response.active { break }
                } catch {
                    if Task.isCancelled { break }
                    let shouldDisconnect = await MainActor.run { () -> Bool in
                        consecutivePollFailures += 1
                        errorMessage = error.localizedDescription
                        if consecutivePollFailures >= 3 {
                            lines.append(TerminalLine(kind: .error, text: error.localizedDescription))
                            markDisconnected()
                            return true
                        }
                        return false
                    }
                    if shouldDisconnect { break }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    continue
                }
            }
        }
    }

    private func appendSSHResponse(_ response: InAppSSHResponse) {
        if let bodyData = response.terminalOutputData, !bodyData.isEmpty {
            appendTerminalOutput(bodyData)
        }
        if response.truncated {
            lines.append(TerminalLine(kind: .notice, text: "Output truncated"))
        }
    }

    private func appendTerminalOutput(_ data: Data) {
        terminalScreen.append(data)
        let text = terminalScreen.renderedTextWithCursor
        if let lastIndex = lines.indices.last, lines[lastIndex].kind == .output {
            lines[lastIndex].text = text
        } else {
            lines.append(TerminalLine(kind: .output, text: text))
        }
        terminalOutputRevision &+= 1
    }

    private func disconnect(appendNotice: Bool = true) {
        pollTask?.cancel()
        pollTask = nil
        let closingSessionID = sessionID
        sessionID = nil
        isConnected = false
        isConnecting = false
        isSending = false
        queuedSSHInput = ""
        consecutivePollFailures = 0
        if appendNotice, closingSessionID != nil {
            lines.append(TerminalLine(kind: .notice, text: "Disconnected"))
        }
        if let closingSessionID {
            Task {
                await appState.closeInAppSSHSession(sessionID: closingSessionID)
            }
        }
    }

    private func markDisconnected() {
        pollTask?.cancel()
        pollTask = nil
        sessionID = nil
        isConnected = false
        isConnecting = false
        isSending = false
        queuedSSHInput = ""
        consecutivePollFailures = 0
        lines.append(TerminalLine(kind: .notice, text: "Disconnected"))
    }

    private func loadBookmarks() {
        bookmarks = SSHBookmarkStore.load()
    }

    private func handleInitialHostIfNeeded() {
        guard !didHandleInitialHost else { return }
        let targetHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetHost.isEmpty else { return }
        didHandleInitialHost = true

        guard autoConnectInitialHost else {
            showingConnectionEditor = true
            return
        }

        if let bookmark = bookmarks.first(where: { bookmarkMatchesHost($0, targetHost) }) {
            applyBookmark(bookmark)
            if bookmark.hasSavedCredential {
                connect()
            } else {
                showingConnectionEditor = true
            }
        } else {
            showingConnectionEditor = true
        }
    }

    private func bookmarkMatchesHost(_ bookmark: SSHBookmark, _ targetHost: String) -> Bool {
        normalizeSSHHost(bookmark.host) == normalizeSSHHost(targetHost)
    }

    private func normalizeSSHHost(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }

    private func prepareNewConnection() {
        host = ""
        port = "22"
        username = ""
        password = ""
        privateKey = ""
        passphrase = ""
        authMode = .password
        saveBookmark = true
        saveCredentials = true
        errorMessage = nil
        showingConnectionEditor = true
    }

    private func applyBookmark(_ bookmark: SSHBookmark) {
        host = bookmark.host
        port = "\(bookmark.port)"
        username = bookmark.username
        authMode = bookmark.authMode
        saveBookmark = true
        saveCredentials = bookmark.hasSavedCredential
        password = bookmark.authMode == .password ? (InAppCredentialStore.load(account: bookmark.account(for: .password)) ?? "") : ""
        privateKey = bookmark.authMode == .privateKey ? (InAppCredentialStore.load(account: bookmark.account(for: .privateKey)) ?? "") : ""
        passphrase = bookmark.authMode == .privateKey ? (InAppCredentialStore.load(account: bookmark.account(for: .passphrase)) ?? "") : ""
    }

    private func saveCurrentBookmark(host: String, port: Int, username: String) throws {
        var bookmark = bookmarks.first { existing in
            existing.host == host && existing.port == port && existing.username == username
        } ?? SSHBookmark(name: "\(username)@\(host)", host: host, port: port, username: username, authModeRaw: authMode.rawValue)

        bookmark.name = "\(username)@\(host)"
        bookmark.authModeRaw = authMode.rawValue
        bookmark.hasSavedPassword = false
        bookmark.hasSavedPrivateKey = false
        bookmark.hasSavedPassphrase = false

        if saveCredentials {
            switch authMode {
            case .password:
                try InAppCredentialStore.save(password, account: bookmark.account(for: .password))
                bookmark.hasSavedPassword = true
            case .privateKey:
                try InAppCredentialStore.save(privateKey, account: bookmark.account(for: .privateKey))
                bookmark.hasSavedPrivateKey = true
                if !passphrase.isEmpty {
                    try InAppCredentialStore.save(passphrase, account: bookmark.account(for: .passphrase))
                    bookmark.hasSavedPassphrase = true
                } else {
                    InAppCredentialStore.delete(account: bookmark.account(for: .passphrase))
                }
            }
        } else {
            InAppCredentialStore.deleteAll(for: bookmark)
        }

        if let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
            bookmarks[index] = bookmark
        } else {
            bookmarks.insert(bookmark, at: 0)
        }
        SSHBookmarkStore.save(bookmarks)
    }

    private func deleteBookmark(_ bookmark: SSHBookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        InAppCredentialStore.deleteAll(for: bookmark)
        SSHBookmarkStore.save(bookmarks)
    }
}

private enum SSHAuthMode: String, CaseIterable, Identifiable, Codable {
    case password
    case privateKey

    var id: String { rawValue }

    var title: String {
        switch self {
        case .password: return "Password"
        case .privateKey: return "Key"
        }
    }
}

private enum SSHCredentialKind: String {
    case password
    case privateKey
    case passphrase
}

private enum TerminalTheme {
    static let background = Color(red: 0.07, green: 0.09, blue: 0.16)
    static let card = Color(red: 0.18, green: 0.21, blue: 0.32)
    static let control = Color(red: 0.13, green: 0.16, blue: 0.28)
    static let input = Color(red: 0.15, green: 0.18, blue: 0.29)
    static let border = Color(red: 0.31, green: 0.36, blue: 0.62)
    static let green = Color(red: 0.10, green: 0.82, blue: 0.47)
    static let secondaryText = Color(red: 0.66, green: 0.68, blue: 0.78)
    static let error = Color(red: 1.0, green: 0.34, blue: 0.38)
}

private struct TerminalRoundIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 24, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 58, height: 58)
            .background(TerminalTheme.control)
            .clipShape(Circle())
            .overlay(Circle().stroke(TerminalTheme.border, lineWidth: 1))
    }
}

private struct TerminalEmptyHostCard: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .semibold))
                .foregroundColor(TerminalTheme.green)
            Text(title)
                .font(.headline)
                .foregroundColor(.white)
            Text(subtitle)
                .font(.subheadline)
                .foregroundColor(TerminalTheme.secondaryText)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TerminalTheme.card)
        .cornerRadius(20)
    }
}

private struct TerminalFormSection<Content: View>: View {
    let title: String
    let systemImage: String
    private let content: Content

    init(title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundColor(.white)

            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TerminalTheme.card)
        .cornerRadius(20)
    }
}

private struct TerminalConnectionField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var keyboardType: UIKeyboardType = .default
    var isSecure = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundColor(TerminalTheme.secondaryText)

            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                        .textContentType(.password)
                } else {
                    TextField(placeholder, text: $text)
                        .keyboardType(keyboardType)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                }
            }
            .textFieldStyle(.plain)
            .font(.body.weight(.semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background(TerminalTheme.input)
            .cornerRadius(14)
        }
    }
}

private enum TerminalKeyboardMode: Equatable {
    case system
    case preset

    var accessibilityLabel: String {
        switch self {
        case .system:
            return "Use preset keyboard"
        case .preset:
            return "Use phone keyboard"
        }
    }
}

private struct TerminalInputDock: View {
    let host: String
    let username: String
    let port: String
    @Binding var keyboardMode: TerminalKeyboardMode
    let onSendInput: (String) -> Void
    let onDisconnect: () -> Void

    private var sessionTitle: String {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else { return trimmedHost }
        return "\(username)@\(trimmedHost)"
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button(action: onDisconnect) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(TerminalTheme.green)
                        .frame(width: 44, height: 44)
                        .background(TerminalTheme.control)
                        .cornerRadius(14)
                }
                .accessibilityLabel("Close terminal")

                HStack(spacing: 10) {
                    Image(systemName: "terminal.fill")
                        .foregroundColor(TerminalTheme.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(sessionTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(TerminalTheme.green)
                            .lineLimit(1)
                        Text("ssh, port \(port)")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(TerminalTheme.secondaryText)
                    }
                    Spacer(minLength: 0)
                    Button(action: onDisconnect) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(TerminalTheme.green.opacity(0.85))
                    }
                    .accessibilityLabel("Disconnect")
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(TerminalTheme.green.opacity(0.16))
                .cornerRadius(16)

                Button {
                    toggleKeyboardMode()
                } label: {
                    Group {
                        if keyboardMode == .preset {
                            Text("ABC")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                        } else {
                            Image(systemName: "keyboard")
                                .font(.system(size: 19, weight: .semibold))
                        }
                    }
                    .foregroundColor(TerminalTheme.green)
                    .frame(width: 44, height: 44)
                    .background(TerminalTheme.control)
                    .cornerRadius(14)
                }
                .accessibilityLabel(keyboardMode.accessibilityLabel)
            }

            if keyboardMode == .system {
                TerminalKeyboardCaptureView(
                    isFirstResponder: true,
                    onInput: onSendInput
                )
                .frame(width: 1, height: 1)
                .opacity(0.01)
            } else {
                TerminalPresetKeyboard(onSend: onSendInput)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(TerminalTheme.background.opacity(0.98))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(TerminalTheme.border.opacity(0.28))
                .frame(height: 1)
        }
        .animation(.easeInOut(duration: 0.18), value: keyboardMode)
    }

    private func toggleKeyboardMode() {
        keyboardMode = keyboardMode == .preset ? .system : .preset
    }
}

private struct TerminalKeyboardCaptureView: UIViewRepresentable {
    let isFirstResponder: Bool
    let onInput: (String) -> Void

    func makeUIView(context: Context) -> TerminalInputView {
        let view = TerminalInputView(frame: .zero)
        view.onInput = context.coordinator.onInput
        view.backgroundColor = .clear
        view.tintColor = .clear
        view.accessibilityLabel = "Terminal input"
        return view
    }

    func updateUIView(_ uiView: TerminalInputView, context: Context) {
        context.coordinator.onInput = onInput
        uiView.onInput = context.coordinator.onInput
        if isFirstResponder {
            DispatchQueue.main.async {
                if !uiView.isFirstResponder {
                    uiView.becomeFirstResponder()
                }
            }
        } else if uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onInput: onInput)
    }

    final class Coordinator: NSObject {
        var onInput: (String) -> Void

        init(onInput: @escaping (String) -> Void) {
            self.onInput = onInput
        }
    }

    final class TerminalInputView: UIView, UIKeyInput {
        var onInput: ((String) -> Void)?

        override var canBecomeFirstResponder: Bool {
            true
        }

        var hasText: Bool {
            true
        }

        var keyboardType: UIKeyboardType {
            get { .asciiCapable }
            set { }
        }

        var autocapitalizationType: UITextAutocapitalizationType {
            get { .none }
            set { }
        }

        var autocorrectionType: UITextAutocorrectionType {
            get { .no }
            set { }
        }

        var spellCheckingType: UITextSpellCheckingType {
            get { .no }
            set { }
        }

        var smartDashesType: UITextSmartDashesType {
            get { .no }
            set { }
        }

        var smartQuotesType: UITextSmartQuotesType {
            get { .no }
            set { }
        }

        var smartInsertDeleteType: UITextSmartInsertDeleteType {
            get { .no }
            set { }
        }

        var returnKeyType: UIReturnKeyType {
            get { .default }
            set { }
        }

        func insertText(_ text: String) {
            if text == "\n" {
                onInput?("\r")
            } else if !text.isEmpty {
                onInput?(text)
            }
        }

        func deleteBackward() {
            onInput?("\u{7f}")
        }
    }
}

private struct SSHBookmark: Codable, Identifiable {
    let id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var authModeRaw: String
    var hasSavedPassword: Bool
    var hasSavedPrivateKey: Bool
    var hasSavedPassphrase: Bool

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int,
        username: String,
        authModeRaw: String,
        hasSavedPassword: Bool = false,
        hasSavedPrivateKey: Bool = false,
        hasSavedPassphrase: Bool = false
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authModeRaw = authModeRaw
        self.hasSavedPassword = hasSavedPassword
        self.hasSavedPrivateKey = hasSavedPrivateKey
        self.hasSavedPassphrase = hasSavedPassphrase
    }

    var authMode: SSHAuthMode {
        SSHAuthMode(rawValue: authModeRaw) ?? .password
    }

    var hasSavedCredential: Bool {
        hasSavedPassword || hasSavedPrivateKey
    }

    func account(for kind: SSHCredentialKind) -> String {
        "top.yesican.awgscale.inapp.ssh.\(id.uuidString).\(kind.rawValue)"
    }
}

private struct SSHBookmarkRow: View {
    let bookmark: SSHBookmark
    let onSelect: () -> Void
    let onConnect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onConnect) {
                rowContent
            }
            .buttonStyle(.plain)

            Menu {
                Button {
                    onConnect()
                } label: {
                    Label("Connect", systemImage: "cable.connector")
                }

                Button {
                    onSelect()
                } label: {
                    Label("Edit", systemImage: "pencil")
                }

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: bookmark.hasSavedCredential ? "ellipsis" : "exclamationmark")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(bookmark.hasSavedCredential ? TerminalTheme.secondaryText : TerminalTheme.error)
                    .frame(width: 42, height: 42)
                    .overlay(
                        Circle()
                            .stroke(bookmark.hasSavedCredential ? Color.clear : TerminalTheme.error.opacity(0.9), lineWidth: 2)
                    )
            }
            .accessibilityLabel("Host actions")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(TerminalTheme.card)
        .cornerRadius(18)
        .contextMenu {
            Button {
                onConnect()
            } label: {
                Label("Connect", systemImage: "cable.connector")
            }
            Button {
                onSelect()
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 14) {
            Image(systemName: bookmark.authMode == .password ? "server.rack" : "key.fill")
                .font(.system(size: 19, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 48, height: 48)
                .background(bookmark.authMode == .password ? Color.blue : TerminalTheme.green)
                .cornerRadius(14)

            VStack(alignment: .leading, spacing: 4) {
                Text(bookmark.host)
                    .font(.headline.weight(.semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text("ssh, \(bookmark.username), \(bookmark.authMode.title.lowercased())")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(TerminalTheme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }
}

private struct TerminalPresetKeyboard: View {
    let onSend: (String) -> Void

    private struct PresetKey: Identifiable {
        let id = UUID()
        let label: String
        let payload: String
    }

    private let columns: [GridItem] = Array(
        repeating: GridItem(.flexible(minimum: 30, maximum: 64), spacing: 6),
        count: 8
    )

    private let keys: [PresetKey] = [
        PresetKey(label: "esc", payload: "\u{1b}"),
        PresetKey(label: "tab", payload: "\t"),
        PresetKey(label: "^C", payload: "\u{3}"),
        PresetKey(label: "^D", payload: "\u{4}"),
        PresetKey(label: "←", payload: "\u{1b}[D"),
        PresetKey(label: "↑", payload: "\u{1b}[A"),
        PresetKey(label: "↓", payload: "\u{1b}[B"),
        PresetKey(label: "→", payload: "\u{1b}[C"),
        PresetKey(label: "home", payload: "\u{1b}[H"),
        PresetKey(label: "pgUp", payload: "\u{1b}[5~"),
        PresetKey(label: "pgDn", payload: "\u{1b}[6~"),
        PresetKey(label: "end", payload: "\u{1b}[F"),
        PresetKey(label: "/", payload: "/"),
        PresetKey(label: "|", payload: "|"),
        PresetKey(label: "~", payload: "~"),
        PresetKey(label: "-", payload: "-"),
        PresetKey(label: "=", payload: "="),
        PresetKey(label: ":", payload: ":"),
        PresetKey(label: ";", payload: ";"),
        PresetKey(label: "!", payload: "!"),
        PresetKey(label: "*", payload: "*"),
        PresetKey(label: "$", payload: "$"),
        PresetKey(label: "%", payload: "%"),
        PresetKey(label: "^", payload: "^"),
        PresetKey(label: "{", payload: "{"),
        PresetKey(label: "}", payload: "}"),
        PresetKey(label: "[", payload: "["),
        PresetKey(label: "]", payload: "]"),
        PresetKey(label: "del", payload: "\u{7f}"),
        PresetKey(label: "ins", payload: "\u{1b}[2~"),
        PresetKey(label: "@", payload: "@"),
        PresetKey(label: "enter", payload: "\r")
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(keys) { key in
                Button {
                    onSend(key.payload)
                } label: {
                    Text(key.label)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundColor(TerminalTheme.green)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(TerminalTheme.control.opacity(0.85))
                        .cornerRadius(9)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private enum SSHBookmarkStore {
    private static let key = "top.yesican.awgscale.inapp.ssh.bookmarks.v1"

    static func load() -> [SSHBookmark] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SSHBookmark].self, from: data)) ?? []
    }

    static func save(_ bookmarks: [SSHBookmark]) {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

private enum InAppCredentialStore {
    private static let service = "top.yesican.awgscale.inapp.ssh"
    private static let keychainGroups: [String?] = [
        "TROLLSTORE.\(IPCConstants.keychainGroupID)",
        IPCConstants.keychainGroupID,
        nil,
    ]

    static func save(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        var lastStatus: OSStatus = errSecSuccess
        for group in keychainGroups {
            var deleteQuery = baseQuery(account: account, group: group)
            SecItemDelete(deleteQuery as CFDictionary)
            deleteQuery.removeAll()

            var addQuery = baseQuery(account: account, group: group)
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(addQuery as CFDictionary, nil)
            if status == errSecSuccess { return }
            lastStatus = status
        }
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(lastStatus))
    }

    static func load(account: String) -> String? {
        for group in keychainGroups {
            var query = baseQuery(account: account, group: group)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess, let data = result as? Data {
                return String(data: data, encoding: .utf8)
            }
        }
        return nil
    }

    static func delete(account: String) {
        for group in keychainGroups {
            SecItemDelete(baseQuery(account: account, group: group) as CFDictionary)
        }
    }

    static func deleteAll(for bookmark: SSHBookmark) {
        delete(account: bookmark.account(for: .password))
        delete(account: bookmark.account(for: .privateKey))
        delete(account: bookmark.account(for: .passphrase))
    }

    private static func baseQuery(account: String, group: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let group {
            query[kSecAttrAccessGroup as String] = group
        }
        return query
    }
}

private struct TerminalOutputView: View {
    let lines: [TerminalLine]
    let outputRevision: Int
    let errorMessage: String?
    private let bottomID = "terminal-output-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if lines.isEmpty {
                        Text(errorMessage ?? "Waiting for shell...")
                            .foregroundColor(.white.opacity(0.65))
                    }
                    ForEach(lines) { line in
                        Text(line.displayText)
                            .foregroundColor(line.color)
                            .font(.system(size: 14, weight: .regular, design: .monospaced))
                            .lineSpacing(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id(line.id)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 14)
            }
            .background(Color(red: 0.03, green: 0.05, blue: 0.08))
            .onAppear {
                scrollToBottom(proxy)
            }
            .onChange(of: lines.count) { _ in
                scrollToBottom(proxy)
            }
            .onChange(of: outputRevision) { _ in
                scrollToBottom(proxy)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
    }
}

private struct TerminalLine: Identifiable {
    enum Kind {
        case input
        case output
        case notice
        case error
    }

    let id = UUID()
    let kind: Kind
    var text: String

    var displayText: String {
        switch kind {
        case .input:
            return "> \(text)"
        case .output:
            return text
        case .notice:
            return "[\(text)]"
        case .error:
            return "! \(text)"
        }
    }

    var color: Color {
        switch kind {
        case .input:
            return Color(red: 0.62, green: 0.85, blue: 1.0)
        case .output:
            return TerminalTheme.green
        case .notice:
            return .orange
        case .error:
            return .red
        }
    }
}

private struct InAppEmptyState: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .semibold))
                .foregroundColor(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
