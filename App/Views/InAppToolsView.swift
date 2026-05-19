import SwiftUI
import WebKit
import Network
import Security

struct InAppToolsView: View {
    @EnvironmentObject var appState: AppState

    private var currentExitNode: PeerNode? {
        guard let exitID = appState.effectiveExitNodeID, !exitID.isEmpty else { return nil }
        return appState.peers.first { $0.id == exitID }
    }

    var body: some View {
        List {
            Section {
                NavigationLink(destination: ExitNodeView()) {
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
                .disabled(!appState.appNetworkIsActive)
                .opacity(appState.appNetworkIsActive ? 1 : 0.45)
            } footer: {
                Text("When enabled, built-in apps can route internet connections through the selected exit node.")
            }

            Section {
                NavigationLink(destination: TailnetBrowserView()) {
                    InAppToolRow(
                        title: "Browser",
                        subtitle: "Open HTTP services on your tailnet",
                        systemImage: "safari",
                        color: .blue
                    )
                }
                .opacity(appState.appNetworkIsActive ? 1 : 0.45)

                NavigationLink(destination: TailnetTerminalView()) {
                    InAppToolRow(
                        title: "Terminal",
                        subtitle: "SSH into devices on your tailnet",
                        systemImage: "terminal",
                        color: .green
                    )
                }
                .opacity(appState.appNetworkIsActive ? 1 : 0.45)
            } footer: {
                if !appState.appNetworkIsActive {
                    Text("Connect in app-only mode to use built-in apps.")
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

struct TailnetBrowserView: View {
    @EnvironmentObject var appState: AppState
    @State private var tabs: [BrowserTab] = [BrowserTab.blank()]
    @State private var activeTabIndex = 0
    @State private var address = ""
    @State private var browserProxy: InAppBrowserProxy?
    @State private var history: [BrowserHistoryItem] = []
    @State private var bookmarks: [BrowserBookmark] = []
    @State private var showingHistory = false
    @State private var showingBookmarks = false
    @State private var showingTabs = false
    @State private var isLoading = false
    @FocusState private var addressFieldFocused: Bool

    private var activeTab: BrowserTab {
        guard tabs.indices.contains(activeTabIndex) else { return BrowserTab.blank() }
        return tabs[activeTabIndex]
    }

    private var activeURL: String {
        sanitizedBrowserURL(activeTab.url)
    }

    var body: some View {
        VStack(spacing: 0) {
            if activeTab.page == nil {
                HStack(spacing: 10) {
                    TextField("google.com or tailnet host", text: $address)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.go)
                        .focused($addressFieldFocused)
                        .onSubmit { loadPage(from: address) }

                    Button {
                        loadPage(from: address)
                    } label: {
                        Image(systemName: isLoading ? "hourglass" : "arrow.right.circle.fill")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isLoading || !appState.appNetworkIsActive || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Connect")
                }
                .padding(16)
            }

            Group {
                if isLoading {
                    ProgressView("Loading...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage = activeTab.errorMessage {
                    InAppEmptyState(systemImage: "exclamationmark.triangle", title: "Unable to Load", message: errorMessage)
                } else if let page = activeTab.page {
                    BrowserContentView(page: page, proxy: browserProxy)
                } else {
                    InAppEmptyState(systemImage: "globe", title: "Browser", message: "Enter a tailnet host or IP address.")
                }
            }
        }
        .navigationTitle("Browser")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    addBookmark()
                } label: {
                    Image(systemName: isBookmarked(activeURL) ? "star.fill" : "star")
                }
                .disabled(activeURL.isEmpty)
                .accessibilityLabel("Bookmark")

                Button {
                    showingHistory = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .accessibilityLabel("History")

                Button {
                    showingBookmarks = true
                } label: {
                    Image(systemName: "book")
                }
                .accessibilityLabel("Bookmarks")

                Button {
                    showingTabs = true
                } label: {
                    ZStack(alignment: .center) {
                        Image(systemName: "square.on.square")
                        Text("\(tabs.count)")
                            .font(.system(size: 9, weight: .bold))
                            .offset(y: -1)
                    }
                    .frame(width: 28, height: 28)
                }
                .accessibilityLabel("Tabs")
            }
        }
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
                onLoad: { index, url in
                    showingTabs = false
                    selectTab(index)
                    loadPage(from: url)
                },
                onClose: closeTab,
                onAdd: addTab
            )
        }
        .onAppear(perform: loadPersistedBrowserState)
    }

    private func loadPage(from rawURL: String? = nil) {
        guard appState.appNetworkIsActive else { return }
        let target = sanitizedBrowserURL(rawURL ?? activeURL)
        guard !target.isEmpty, target != "http://", target != "https://" else { return }

        if tabs.indices.contains(activeTabIndex) {
            tabs[activeTabIndex].url = target
            tabs[activeTabIndex].errorMessage = nil
        }
        isLoading = true
        let loadingIndex = activeTabIndex

        Task {
            do {
                let proxy = try await appState.inAppBrowserProxy()
                let loadedPage = try await appState.fetchInAppBrowserPage(target)
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
    }

    private func addTab() {
        tabs.append(BrowserTab.blank())
        activeTabIndex = tabs.count - 1
        address = ""
        saveTabs()
    }

    private func closeTab(_ index: Int) {
        guard tabs.count > 1, tabs.indices.contains(index) else { return }
        tabs.remove(at: index)
        activeTabIndex = min(activeTabIndex, tabs.count - 1)
        saveTabs()
    }

    private func openURL(_ url: String) {
        let url = sanitizedBrowserURL(url)
        if tabs.indices.contains(activeTabIndex) {
            tabs[activeTabIndex].url = url
            tabs[activeTabIndex].title = BrowserTab.title(for: url)
            tabs[activeTabIndex].page = nil
            tabs[activeTabIndex].errorMessage = nil
        }
        address = url
        loadPage(from: url)
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
        return trimmed == "http://" || trimmed == "https://" ? "" : trimmed
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

    init(id: UUID = UUID(), title: String, url: String, page: InAppBrowserPage? = nil, errorMessage: String? = nil) {
        self.id = id
        self.title = title
        self.url = url
        self.page = page
        self.errorMessage = errorMessage
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

private struct StoredBrowserTab: Codable {
    var title: String
    var url: String
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

private struct BrowserTabsSheet: View {
    let tabs: [BrowserTab]
    let activeIndex: Int
    let onSelect: (Int) -> Void
    let onLoad: (Int, String) -> Void
    let onClose: (Int) -> Void
    let onAdd: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draftURLs: [UUID: String] = [:]
    @FocusState private var focusedTabID: UUID?

    var body: some View {
        NavigationView {
            List {
                ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                    if index == activeIndex {
                        activeTabRow(tab: tab, index: index)
                    } else {
                        tabSelectionRow(tab: tab, index: index)
                    }
                }
            }
            .navigationTitle("Tabs")
            .onAppear {
                syncDraftURLs()
                focusActiveTab()
            }
            .onChange(of: activeIndex) { _ in
                syncDraftURLs()
                focusActiveTab()
            }
            .onChange(of: tabs.map(\.id)) { _ in
                syncDraftURLs()
                focusActiveTab()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        onAdd()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New tab")
                }
            }
        }
    }

    private func activeTabRow(tab: BrowserTab, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.accentColor)
                Text(tab.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                closeButton(index: index)
            }

            HStack(spacing: 10) {
                TextField("google.com or tailnet host", text: draftBinding(for: tab))
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.go)
                    .focused($focusedTabID, equals: tab.id)
                    .onSubmit { submit(tab: tab, index: index) }

                Button {
                    submit(tab: tab, index: index)
                } label: {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 24, weight: .semibold))
                }
                .disabled((draftURLs[tab.id] ?? tab.url).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Connect")
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            focusedTabID = tab.id
        }
    }

    private func tabSelectionRow(tab: BrowserTab, index: Int) -> some View {
        HStack(spacing: 12) {
            Button {
                onSelect(index)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "circle")
                        .foregroundColor(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tab.displayTitle)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Text(tab.url.isEmpty ? "New Tab" : tab.url)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()
            closeButton(index: index)
        }
    }

    @ViewBuilder
    private func closeButton(index: Int) -> some View {
        if tabs.count > 1 {
            Button {
                onClose(index)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close tab")
        }
    }

    private func draftBinding(for tab: BrowserTab) -> Binding<String> {
        Binding(
            get: { draftURLs[tab.id] ?? tab.url },
            set: { draftURLs[tab.id] = $0 }
        )
    }

    private func submit(tab: BrowserTab, index: Int) {
        let url = (draftURLs[tab.id] ?? tab.url).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        onLoad(index, url)
    }

    private func syncDraftURLs() {
        var next: [UUID: String] = [:]
        for tab in tabs {
            next[tab.id] = draftURLs[tab.id] ?? tab.url
        }
        draftURLs = next
    }

    private func focusActiveTab() {
        guard tabs.indices.contains(activeIndex) else { return }
        focusedTabID = tabs[activeIndex].id
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

    private var bodyText: String {
        page.body ?? page.bodyBase64.map { "Base64 response:\n\($0)" } ?? ""
    }

    private var isHTML: Bool {
        page.contentType.localizedCaseInsensitiveContains("text/html") || bodyText.localizedCaseInsensitiveContains("<html")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("HTTP \(page.statusCode)")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(statusColor)
                if page.truncated {
                    Text("Truncated")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                Spacer()
                Text(page.contentType)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.08))

            if isHTML {
                WebContentView(url: URL(string: page.url), html: bodyText, baseURL: URL(string: page.url), proxy: proxy)
                    .id("\(page.url)|\(proxy?.address ?? "direct")")
            } else {
                ScrollView {
                    Text(bodyText)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        }
    }

    private var statusColor: Color {
        (200..<400).contains(page.statusCode) ? .green : .orange
    }
}

private struct WebContentView: UIViewRepresentable {
    let url: URL?
    let html: String
    let baseURL: URL?
    let proxy: InAppBrowserProxy?

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
        return WKWebView(frame: .zero, configuration: configuration)
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if #available(iOS 17.0, *), proxy != nil, let url {
            webView.load(URLRequest(url: url))
        } else {
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }
}

struct TailnetTerminalView: View {
    @EnvironmentObject var appState: AppState
    private let initialSSHHint: String?
    @State private var host: String
    @State private var port: String
    @State private var username = ""
    @State private var password = ""
    @State private var privateKey = ""
    @State private var passphrase = ""
    @State private var authMode: SSHAuthMode = .password
    @State private var saveBookmark = true
    @State private var saveCredentials = true
    @State private var bookmarks: [SSHBookmark] = []
    @State private var showingConnectionEditor: Bool
    @State private var input = ""
    @State private var lines: [TerminalLine] = []
    @State private var sessionID: String?
    @State private var isConnected = false
    @State private var isConnecting = false
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var pollTask: Task<Void, Never>?

    init(initialHost: String = "", initialPort: Int = 22, sshHint: String? = nil) {
        self.initialSSHHint = sshHint
        _host = State(initialValue: initialHost)
        _port = State(initialValue: "\(initialPort)")
        _showingConnectionEditor = State(initialValue: !initialHost.isEmpty)
    }

    var body: some View {
        Group {
            if isConnected {
                connectedTerminalView
            } else {
                connectionLandingView
            }
        }
        .navigationTitle(isConnected ? "Terminal" : "Hosts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingConnectionEditor = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(isConnected)
                .opacity(isConnected ? 0 : 1)
                .accessibilityLabel("Add connection")
            }
        }
        .sheet(isPresented: $showingConnectionEditor) {
            NavigationView {
                connectionForm
                    .navigationTitle("Connection")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showingConnectionEditor = false }
                        }
                    }
            }
        }
        .onAppear(perform: loadBookmarks)
        .onDisappear {
            disconnect(appendNotice: false)
        }
    }

    private var connectionLandingView: some View {
        ZStack {
            TerminalTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Hosts")
                                .font(.largeTitle.weight(.bold))
                                .foregroundColor(.white)
                            Text("Personal")
                                .font(.subheadline)
                                .foregroundColor(TerminalTheme.secondaryText)
                        }

                        Spacer()

                        Button {
                            showingConnectionEditor = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 24, weight: .medium))
                                .foregroundColor(.white)
                                .frame(width: 56, height: 56)
                                .background(TerminalTheme.control)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(TerminalTheme.border, lineWidth: 1))
                        }
                        .accessibilityLabel("Add connection")
                    }

                    if let errorMessage {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.circle")
                            Text(errorMessage)
                                .lineLimit(3)
                        }
                        .font(.footnote)
                        .foregroundColor(TerminalTheme.error)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(TerminalTheme.card)
                        .cornerRadius(14)
                    }

                    if isConnecting {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Connecting to \(username)@\(host)")
                                .foregroundColor(.white)
                                .lineLimit(1)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(TerminalTheme.card)
                        .cornerRadius(18)
                    }

                    if bookmarks.isEmpty {
                        Button {
                            showingConnectionEditor = true
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 30, weight: .semibold))
                                    .foregroundColor(TerminalTheme.green)
                                Text("Add Connection")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                Text("SSH with password or private key")
                                    .font(.subheadline)
                                    .foregroundColor(TerminalTheme.secondaryText)
                            }
                            .padding(20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(TerminalTheme.card)
                            .cornerRadius(20)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Hosts")
                                .font(.headline)
                                .foregroundColor(TerminalTheme.secondaryText)

                            ForEach(bookmarks) { bookmark in
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
                }
                .padding(22)
            }
        }
    }

    private var connectedTerminalView: some View {
        VStack(spacing: 0) {
            connectedSessionBar
            TerminalOutputView(lines: lines, errorMessage: errorMessage)
            TerminalShortcutBar(onSend: sendShortcut)
            commandBar
        }
        .background(TerminalTheme.background.ignoresSafeArea())
    }

    private var commandBar: some View {
        HStack(spacing: 10) {
            TextField("Command", text: $input)
                .autocapitalization(.none)
                .autocorrectionDisabled()
                .textFieldStyle(.plain)
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(TerminalTheme.input)
                .cornerRadius(14)
                .onSubmit { sendCurrentInput() }

            Button {
                sendCurrentInput()
            } label: {
                Image(systemName: isSending ? "hourglass" : "return")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 46, height: 46)
                    .background(TerminalTheme.green.opacity(canSend ? 1 : 0.35))
                    .cornerRadius(14)
            }
            .disabled(!canSend || input.isEmpty)
        }
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(TerminalTheme.background)
    }

    private var connectionForm: some View {
        Form {
            Section {
                TextField("host or 100.x.y.z", text: $host)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                TextField("port", text: $port)
                    .keyboardType(.numberPad)
                TextField("username", text: $username)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()

                Picker("Auth", selection: $authMode) {
                    ForEach(SSHAuthMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if authMode == .password {
                    SecureField("password", text: $password)
                        .textContentType(.password)
                } else {
                    TextEditor(text: $privateKey)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 88)
                        .overlay(alignment: .topLeading) {
                            if privateKey.isEmpty {
                                Text("private key")
                                    .foregroundColor(.secondary)
                                    .padding(.top, 8)
                                    .padding(.leading, 4)
                            }
                        }
                    SecureField("passphrase (optional)", text: $passphrase)
                        .textContentType(.password)
                }

                Toggle("Save host", isOn: $saveBookmark)
                Toggle("Save credentials", isOn: $saveCredentials)
                    .disabled(!saveBookmark)

                Button {
                    connect()
                } label: {
                    Label(isConnecting ? "Connecting" : "Connect", systemImage: isConnecting ? "hourglass" : "bolt.horizontal.fill")
                }
                .disabled(!canConnect)
            } header: {
                Text("Quick Connect")
            } footer: {
                if let initialSSHHint {
                    Text(initialSSHHint)
                }
            }

            Section("Saved Hosts") {
                if bookmarks.isEmpty {
                    Text("No saved hosts")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(bookmarks) { bookmark in
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
        .disabled(isConnecting)
    }

    private var connectedSessionBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal.fill")
                .foregroundColor(TerminalTheme.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(username)@\(host)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text("port \(port)")
                    .font(.caption)
                    .foregroundColor(TerminalTheme.secondaryText)
            }
            Spacer()
            Button(role: .destructive) {
                disconnect()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
            }
        }
        .padding()
        .background(TerminalTheme.card)
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
        appState.appNetworkIsActive && isConnected && sessionID != nil && !isSending
    }

    private func sendCurrentInput() {
        let payload = input
        input = ""
        send(payload: payload, appendNewline: true, echoInput: !payload.isEmpty)
    }

    private func sendShortcut(_ payload: String) {
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
                    appendSSHResponse(response)
                    if response.active {
                        showingConnectionEditor = false
                        lines.append(TerminalLine(kind: .notice, text: "Connected"))
                        startPolling(sessionID: response.sessionID)
                    } else {
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
        guard canSend, let currentSessionID = sessionID else { return }
        isSending = true
        errorMessage = nil
        if echoInput && !payload.isEmpty {
            lines.append(TerminalLine(kind: .input, text: payload))
        }
        let inputPayload = appendNewline ? payload + "\n" : payload

        Task {
            do {
                let response = try await appState.sendInAppSSHInput(sessionID: currentSessionID, input: inputPayload)
                await MainActor.run {
                    appendSSHResponse(response)
                    if !response.active {
                        markDisconnected()
                    }
                    isSending = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    lines.append(TerminalLine(kind: .error, text: error.localizedDescription))
                    isSending = false
                }
            }
        }
    }

    private func startPolling(sessionID: String) {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                do {
                    let response = try await appState.readInAppSSHSession(sessionID: sessionID)
                    await MainActor.run {
                        appendSSHResponse(response)
                        if !response.active {
                            markDisconnected()
                        }
                    }
                    if !response.active { break }
                } catch {
                    await MainActor.run {
                        errorMessage = error.localizedDescription
                        lines.append(TerminalLine(kind: .error, text: error.localizedDescription))
                        markDisconnected()
                    }
                    break
                }

                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
    }

    private func appendSSHResponse(_ response: InAppSSHResponse) {
        let text = response.body ?? response.bodyBase64.map { "Base64 response:\n\($0)" } ?? ""
        if !text.isEmpty {
            lines.append(TerminalLine(kind: .output, text: text))
        }
        if response.truncated {
            lines.append(TerminalLine(kind: .notice, text: "Output truncated"))
        }
    }

    private func disconnect(appendNotice: Bool = true) {
        pollTask?.cancel()
        pollTask = nil
        let closingSessionID = sessionID
        sessionID = nil
        isConnected = false
        isConnecting = false
        isSending = false
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
        lines.append(TerminalLine(kind: .notice, text: "Disconnected"))
    }

    private func loadBookmarks() {
        bookmarks = SSHBookmarkStore.load()
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
        HStack(spacing: 10) {
            Button(action: onSelect) {
                HStack(spacing: 14) {
                    Image(systemName: bookmark.authMode == .password ? "server.rack" : "key.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(bookmark.authMode == .password ? Color.blue : TerminalTheme.green)
                        .cornerRadius(12)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(bookmark.name)
                            .font(.headline)
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text("ssh, \(bookmark.username), \(bookmark.authMode.title.lowercased())")
                            .font(.caption)
                            .foregroundColor(TerminalTheme.secondaryText)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            if bookmark.hasSavedCredential {
                Image(systemName: "key.fill")
                    .font(.caption)
                    .foregroundColor(TerminalTheme.secondaryText)
            }

            Button(action: onConnect) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(TerminalTheme.card)
        .cornerRadius(18)
        .swipeActions {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

private struct TerminalShortcutBar: View {
    let onSend: (String) -> Void

    private let keys: [(String, String)] = [
        ("esc", "\u{1b}"),
        ("tab", "\t"),
        ("ctrl-c", "\u{3}"),
        ("↑", "\u{1b}[A"),
        ("↓", "\u{1b}[B"),
        ("←", "\u{1b}[D"),
        ("→", "\u{1b}[C"),
        ("/", "/"),
        ("|", "|")
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(keys, id: \.0) { label, payload in
                    Button {
                        onSend(payload)
                    } label: {
                        Text(label)
                            .font(.system(.callout, design: .monospaced).weight(.semibold))
                            .foregroundColor(TerminalTheme.green)
                            .frame(minWidth: 42, minHeight: 34)
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 9)
        }
        .background(TerminalTheme.input)
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
    let errorMessage: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if lines.isEmpty {
                        Text(errorMessage ?? "Waiting for shell...")
                            .foregroundColor(.white.opacity(0.65))
                    }
                    ForEach(lines) { line in
                        Text(line.displayText)
                            .foregroundColor(line.color)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding()
            }
            .background(Color(red: 0.03, green: 0.05, blue: 0.08))
            .onChange(of: lines.count) { _ in
                if let last = lines.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
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
    let text: String

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
            return .white
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