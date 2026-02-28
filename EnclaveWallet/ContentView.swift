import SwiftUI
import WebKit
import WalletConnectSign
import BigInt
import os

private let log = Logger(subsystem: "com.plether.EnclaveWallet", category: "UI")

nonisolated enum AppProtocol: String, CaseIterable, Sendable {
    case https = "https://"
    case ipfs = "ipfs://"

    var placeholder: String {
        switch self {
        case .https: "app.example.com"
        case .ipfs: "bafy... or CID/path"
        }
    }
}

nonisolated struct AppEntry: Codable, Identifiable, Sendable {
    var id: String { url }
    let url: String

    var isIPFS: Bool { url.hasPrefix("ipfs://") }

    var icon: String {
        if isIPFS { return "cube" }
        return URL(string: url).flatMap(\.host)?.split(separator: ".").dropLast().last.map { String($0.prefix(1)).uppercased() } ?? "?"
    }
}

private let defaultApps = [
    AppEntry(url: "https://app.plether.com"),
    AppEntry(url: "https://app.uniswap.org"),
    AppEntry(url: "https://app.aave.com"),
]

struct ContentView: View {
    @State private var showSend = false
    @State private var showReceive = false
    @State private var activeURL = "kitchen_sink"
    @State private var visitedURLs: Set<String> = []
    @State private var currentURL = ""
    @State private var activityRefreshId = UUID()
    @State private var showSessions = false
    @State private var lastPasteboardCount = NSPasteboard.general.changeCount
    @State private var webViewCoordinator: WalledGardenWebView.Coordinator?
    @State private var apps: [AppEntry] = {
        guard let data = UserDefaults.standard.data(forKey: "savedApps"),
              let saved = try? JSONDecoder().decode([AppEntry].self, from: data) else {
            return defaultApps
        }
        return saved
    }()
    @State private var showAddApp = false
    @State private var showNewWallet = false
    @State private var newAppAddress = ""
    @State private var selectedProtocol: AppProtocol = .https

    @ObservedObject private var wcService = WalletConnectService.shared

    var body: some View {
        VStack(spacing: 0) {
            topBar.id(activityRefreshId)
            Divider()
            HSplitView {
                HStack(spacing: 0) {
                    appSidebar
                    Divider()
                    WalledGardenWebView(
                        urlString: activeURL,
                        currentURL: $currentURL,
                        coordinatorRef: $webViewCoordinator
                    )
                }
                .frame(minWidth: 300)
                ActivityWebView(
                    onSend: { showSend = true },
                    onReceive: { showReceive = true },
                    onPasteWC: { pasteWCURI() },
                    onSelectWallet: { index in
                        EnclaveEngine.shared.selectWallet(at: index)
                        refreshWallets()
                    },
                    onNewWallet: { showNewWallet = true }
                )
                    .frame(width: 360)
            }
        }
        .sheet(isPresented: $showSend) {
            SendView(onComplete: {
                refreshBalances()
                activityRefreshId = UUID()
            })
        }
        .sheet(isPresented: $showReceive) {
            ReceiveView()
        }
        .sheet(isPresented: $showNewWallet) {
            NewWalletView(onComplete: { refreshWallets() })
        }
        .sheet(item: $wcService.pendingProposal) { proposal in
            SessionProposalView(
                proposal: proposal,
                onApprove: { wcService.approveProposal() },
                onReject: { wcService.rejectProposal() }
            )
        }
        .sheet(item: $wcService.pendingRequest) { request in
            RequestApprovalView(
                request: request,
                onApprove: {
                    if request.method == "eth_sendTransaction" {
                        wcService.approveSendTransaction()
                    } else {
                        wcService.approveSignRequest()
                    }
                },
                onReject: { wcService.rejectRequest() }
            )
        }
        .sheet(isPresented: $showSessions) {
            SessionsListView(
                sessions: wcService.sessions,
                onDisconnect: { topic in wcService.disconnect(topic: topic) }
            )
        }
        .ignoresSafeArea()
        .task { refreshBalances() }
        .task { await monitorClipboard() }
        .background(WindowAccessor())
        .onReceive(NotificationCenter.default.publisher(for: .networkDidChange)) { _ in
            refreshBalances()
            notifyActivityWebView()
            activityRefreshId = UUID()
        }
    }

    private func refreshWallets() {
        refreshBalances()
        notifyActivityWebView()
        activityRefreshId = UUID()
        wcService.emitAccountsChanged()
    }

    private func saveApps() {
        if let data = try? JSONEncoder().encode(apps) {
            UserDefaults.standard.set(data, forKey: "savedApps")
        }
    }

    private func removeApp(_ app: AppEntry) {
        apps.removeAll { $0.url == app.url }
        saveApps()
        webViewCoordinator?.webViews.removeValue(forKey: app.url)
        visitedURLs.remove(app.url)
        if activeURL == app.url { activeURL = "kitchen_sink" }
    }

    private func refreshBalances() {
        guard let wallet = EnclaveEngine.shared.currentWallet else { return }
        Task {
            await EnclaveEngine.shared.refreshDeploymentStatus()
            do {
                let eth = try await RPCClient.shared.getBalance(address: wallet.address)
                let usdc = try await RPCClient.shared.getERC20Balance(
                    token: Config.activeNetwork.usdcAddress,
                    owner: wallet.address
                )
                await MainActor.run {
                    UserDefaults.standard.set(eth.ethFormatted, forKey: "cachedEthBalance")
                    UserDefaults.standard.set(usdc.usdcFormatted, forKey: "cachedUsdcBalance")
                    NotificationCenter.default.post(name: .balanceDidUpdate, object: nil)
                }
            } catch {
                log.error("Balance fetch failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func notifyActivityWebView() {
        NotificationCenter.default.post(name: .walletStateDidChange, object: nil)
    }

    private var topBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 14) {
                Button { webViewCoordinator?.webView?.goBack() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 16, weight: .medium))
                }
                .buttonStyle(.borderless)

                Button { webViewCoordinator?.webView?.goForward() } label: {
                    Image(systemName: "chevron.right").font(.system(size: 16, weight: .medium))
                }
                .buttonStyle(.borderless)

                Button { webViewCoordinator?.webView?.reload() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .medium))
                }
                .buttonStyle(.borderless)
            }
            .frame(width: 130, alignment: .leading)

            GeometryReader { geo in
                HStack(spacing: 0) {
                    Menu {
                        ForEach(Network.allCases, id: \.self) { network in
                            Button {
                                Config.activeNetwork = network
                                refreshWallets()
                            } label: {
                                HStack {
                                    Text(network.displayName)
                                    if network == Config.activeNetwork {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        Text(Config.activeNetwork.displayName)
                            .font(.system(size: 13))
                            .padding(.horizontal, 12)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    Divider()

                    Text(currentURL)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: geo.size.width * 0.5, height: 28)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 28)

            Button { showSessions = true } label: {
                Image(systemName: "gearshape").font(.system(size: 16, weight: .medium))
            }
            .buttonStyle(.borderless)
            .frame(width: 44, alignment: .trailing)
        }
        .padding(.leading, 88)
        .padding(.trailing, 16)
        .padding(.vertical, 12)
    }

    private var appSidebar: some View {
        VStack(spacing: 8) {
            sidebarButton("house.fill", url: "kitchen_sink")
            ForEach(apps) { app in
                sidebarButton(app.icon, url: app.url)
                    .contextMenu {
                        Button("Remove", role: .destructive) { removeApp(app) }
                    }
            }
            Spacer()
            Button { showAddApp = true } label: {
                Image(systemName: "plus")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showAddApp) {
                addAppPopover
            }
        }
        .padding(.vertical, 8)
        .frame(width: 44)
        .background(Color.black.opacity(0.03))
    }

    private func isConnected(url: String) -> Bool {
        guard let host = URL(string: url)?.host else { return false }
        return wcService.sessions.contains { $0.peer.url.contains(host) }
    }

    private var addAppPopover: some View {
        VStack(spacing: 12) {
            Text("Add App").font(.headline)
            HStack(spacing: 4) {
                Picker("", selection: $selectedProtocol) {
                    ForEach(AppProtocol.allCases, id: \.self) { Text($0.rawValue) }
                }
                .labelsHidden()
                .fixedSize()
                TextField(selectedProtocol.placeholder, text: $newAppAddress)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onSubmit { addApp() }
            }
            HStack {
                Button("Cancel") {
                    newAppAddress = ""
                    showAddApp = false
                }
                Spacer()
                Button("Add") { addApp() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newAppAddress.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
    }

    private func addApp() {
        let address = newAppAddress.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else { return }
        let url: String
        switch selectedProtocol {
        case .https: url = "https://" + address
        case .ipfs: url = "ipfs://" + address
        }
        guard !apps.contains(where: { $0.url == url }) else {
            newAppAddress = ""
            showAddApp = false
            return
        }
        apps.append(AppEntry(url: url))
        saveApps()
        newAppAddress = ""
        showAddApp = false
        visitedURLs.insert(activeURL)
        activeURL = url
    }

    private func sidebarButton(_ icon: String, url: String) -> some View {
        let isActive = activeURL == url
        let isCached = isActive || visitedURLs.contains(url)
        let connected = isConnected(url: url)
        return Button {
            visitedURLs.insert(activeURL)
            activeURL = url
        } label: {
            Group {
                if icon.count == 1 && !icon.contains(".") {
                    Text(icon).font(.system(.body, design: .rounded)).bold()
                } else {
                    Image(systemName: icon)
                }
            }
            .frame(width: 32, height: 32)
            .background(isActive ? Color.accentColor.opacity(0.2) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(isCached ? Color.secondary : Color.clear)
                .frame(width: 3, height: 16)
                .offset(x: -6)
        }
        .overlay(alignment: .topTrailing) {
            if connected {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                    .offset(x: 2, y: -2)
            }
        }
    }

    private func monitorClipboard() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            let count = NSPasteboard.general.changeCount
            guard count != lastPasteboardCount else { continue }
            lastPasteboardCount = count

            guard let str = NSPasteboard.general.string(forType: .string),
                  str.hasPrefix("wc:") else { continue }
            log.notice("Auto-detected WC URI in clipboard")
            WalletConnectService.shared.pair(uriString: str)
        }
    }

    private func pasteWCURI() {
        guard let str = NSPasteboard.general.string(forType: .string),
              str.hasPrefix("wc:") else {
            log.notice("Clipboard does not contain a WC URI")
            return
        }
        WalletConnectService.shared.pair(uriString: str)
    }
}

// MARK: - Session Proposal View

extension Session.Proposal: @retroactive Identifiable {}

struct SessionProposalView: View {
    let proposal: Session.Proposal
    let onApprove: () -> Void
    let onReject: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Connect").font(.title2).bold()

            HStack(spacing: 12) {
                if let iconURL = proposal.proposer.icons.first.flatMap({ URL(string: $0) }) {
                    AsyncImage(url: iconURL) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.2))
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(proposal.proposer.name).bold()
                    Text(proposal.proposer.url)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !proposal.proposer.description.isEmpty {
                Text(proposal.proposer.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            let allNamespaces = mergedNamespaces
            if !allNamespaces.chains.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Networks").font(.subheadline).bold()
                    FlowLayout(spacing: 6) {
                        ForEach(allNamespaces.chains, id: \.self) { chain in
                            let supported = Self.supportedChains.contains(chain)
                            Text(chainName(chain))
                                .font(.caption)
                                .foregroundColor(supported ? .primary : .secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(supported ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.08))
                                .clipShape(Capsule())
                                .opacity(supported ? 1 : 0.7)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !allNamespaces.methods.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Methods").font(.subheadline).bold()
                    FlowLayout(spacing: 6) {
                        ForEach(allNamespaces.methods.sorted(), id: \.self) { method in
                            let supported = !Self.unsupportedMethods.contains(method)
                            Text(method)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(supported ? .primary : .secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(supported ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.08))
                                .clipShape(Capsule())
                                .opacity(supported ? 1 : 0.7)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !allNamespaces.events.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Events").font(.subheadline).bold()
                    FlowLayout(spacing: 6) {
                        ForEach(allNamespaces.events.sorted(), id: \.self) { event in
                            let supported = Self.supportedEvents.contains(event)
                            Text(event)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(supported ? .primary : .secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(supported ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.08))
                                .clipShape(Capsule())
                                .opacity(supported ? 1 : 0.7)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Reject") {
                    onReject()
                    dismiss()
                }
                Spacer()
                Button("Approve") {
                    onApprove()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private var mergedNamespaces: (chains: [String], methods: [String], events: [String]) {
        var chains: [String] = []
        var methods: Set<String> = []
        var events: Set<String> = []

        for (_, ns) in proposal.requiredNamespaces {
            if let c = ns.chains { chains.append(contentsOf: c.map(\.absoluteString)) }
            methods.formUnion(ns.methods)
            events.formUnion(ns.events)
        }
        if let optional = proposal.optionalNamespaces {
            for (_, ns) in optional {
                if let c = ns.chains {
                    for chain in c where !chains.contains(chain.absoluteString) {
                        chains.append(chain.absoluteString)
                    }
                }
                methods.formUnion(ns.methods)
                events.formUnion(ns.events)
            }
        }
        return (chains, Array(methods), Array(events))
    }

    static let knownChains: [String: String] = [
        "eip155:1": "Ethereum",
        "eip155:10": "Optimism",
        "eip155:56": "BNB Chain",
        "eip155:100": "Gnosis",
        "eip155:130": "Engram",
        "eip155:137": "Polygon",
        "eip155:143": "Trikon",
        "eip155:196": "X Layer",
        "eip155:324": "zkSync Era",
        "eip155:480": "World Chain",
        "eip155:1101": "Polygon zkEVM",
        "eip155:1301": "Unichain Sepolia",
        "eip155:1329": "Sei",
        "eip155:1868": "Soneium",
        "eip155:5000": "Mantle",
        "eip155:7777777": "Zora",
        "eip155:8453": "Base",
        "eip155:34443": "Mode",
        "eip155:42161": "Arbitrum One",
        "eip155:42170": "Arbitrum Nova",
        "eip155:42220": "Celo",
        "eip155:43114": "Avalanche",
        "eip155:59144": "Linea",
        "eip155:81457": "Blast",
        "eip155:421614": "Arbitrum Sepolia",
        "eip155:534352": "Scroll",
        "eip155:11155111": "Sepolia",
        "eip155:11155420": "OP Sepolia",
        "eip155:168587773": "Blast Sepolia",
    ]

    private static let supportedChains: Set<String> = Set(
        Network.allCases.map(\.caip2)
    )

    private static let unsupportedMethods: Set<String> = [
        "eth_sign",
    ]

    private static let supportedEvents: Set<String> = [
        "chainChanged", "accountsChanged",
    ]

    private func chainName(_ caip2: String) -> String {
        Self.knownChains[caip2] ?? caip2
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Request Approval View

extension Request: @retroactive Identifiable {}

struct RequestApprovalView: View {
    let request: Request
    let onApprove: () -> Void
    let onReject: () -> Void
    @ObservedObject private var wcService = WalletConnectService.shared
    @Environment(\.dismiss) private var dismiss

    private static let knownChains = SessionProposalView.knownChains

    var body: some View {
        VStack(spacing: 16) {
            Text("Sign Request").font(.title2).bold()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Method:").foregroundColor(.secondary)
                    Text(request.method)
                        .font(.system(.body, design: .monospaced))
                }
                HStack {
                    Text("Chain:").foregroundColor(.secondary)
                    let caip2 = request.chainId.absoluteString
                    Text(Self.knownChains[caip2] ?? caip2)
                }

                if request.method == "personal_sign" {
                    personalSignDetails
                } else if request.method == "eth_signTypedData_v4" {
                    typedDataDetails
                } else if request.method == "eth_sendTransaction" {
                    sendTransactionDetails
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(8)

            switch wcService.signingStatus {
            case .signing:
                ProgressView("Waiting for authentication...")
            case .submitting:
                ProgressView("Submitting to bundler...")
            case .waiting:
                ProgressView("Waiting for confirmation...")
            case .success:
                Label("Signed successfully", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            case .error(let msg):
                VStack(spacing: 8) {
                    Label(msg, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Button("Dismiss") {
                        wcService.signingStatus = .idle
                        dismiss()
                    }
                }
            case .idle:
                HStack {
                    Button("Reject") {
                        onReject()
                        dismiss()
                    }
                    Spacer()
                    Button("Approve & Sign") {
                        onApprove()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: 420)
        .onChange(of: wcService.signingStatus) { _, status in
            if status == .success {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    wcService.signingStatus = .idle
                    dismiss()
                }
            }
        }
        .interactiveDismissDisabled(wcService.signingStatus != .idle)
        .onDisappear {
            wcService.signingStatus = .idle
        }
    }

    @ViewBuilder
    private var personalSignDetails: some View {
        if let params = try? request.params.get([String].self),
           let hex = params.first,
           let data = hex.stripHexPrefix().hexToData(),
           let message = String(data: data, encoding: .utf8) {
            Text("Message:").foregroundColor(.secondary)
            Text(message)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(10)
                .padding(8)
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(6)
        }
    }

    @ViewBuilder
    private var typedDataDetails: some View {
        if let params = try? request.params.get([String].self),
           params.count >= 2,
           let jsonData = params[1].data(using: .utf8),
           let typed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            if let domain = typed["domain"] as? [String: Any],
               let name = domain["name"] as? String {
                HStack {
                    Text("App:").foregroundColor(.secondary)
                    Text(name)
                }
            }
            if let primaryType = typed["primaryType"] as? String {
                HStack {
                    Text("Action:").foregroundColor(.secondary)
                    Text(primaryType)
                }
            }
            if let message = typed["message"] as? [String: Any] {
                let preview = message.keys.sorted().prefix(6).map { key in
                    let val = message[key]
                    let display = (val as? String) ?? String(describing: val ?? "")
                    let truncated = display.count > 40 ? String(display.prefix(37)) + "..." : display
                    return "\(key): \(truncated)"
                }.joined(separator: "\n")
                Text(preview)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(8)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.05))
                    .cornerRadius(6)
            }
        }
    }

    @ViewBuilder
    private var sendTransactionDetails: some View {
        if let txDicts = try? request.params.get([[String: String]].self),
           let tx = txDicts.first {
            if let to = tx["to"] {
                HStack {
                    Text("To:").foregroundColor(.secondary)
                    Text(String(to.prefix(6)) + "..." + String(to.suffix(4)))
                        .font(.system(.body, design: .monospaced))
                }
            }
            if let valueHex = tx["value"],
               let wei = BigUInt(valueHex.stripHexPrefix(), radix: 16), wei > 0 {
                HStack {
                    Text("Value:").foregroundColor(.secondary)
                    Text(Wei(bigUInt: wei).ethFormatted + " ETH")
                        .font(.system(.body, design: .monospaced))
                }
            }
            if let data = tx["data"], data != "0x", data.count > 2 {
                let selector = String(data.stripHexPrefix().prefix(8))
                HStack {
                    Text("Data:").foregroundColor(.secondary)
                    Text("0x\(selector)... (\(data.stripHexPrefix().count / 2) bytes)")
                        .font(.system(.caption, design: .monospaced))
                }
            }
        }
    }
}

// MARK: - Sessions List View

struct SessionsListView: View {
    let sessions: [Session]
    let onDisconnect: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Active Sessions").font(.title2).bold()

            if sessions.isEmpty {
                Text("No active sessions")
                    .foregroundColor(.secondary)
            } else {
                ForEach(sessions, id: \.topic) { session in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(session.peer.name).bold()
                            Text(session.peer.url)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Disconnect") {
                            onDisconnect(session.topic)
                        }
                        .foregroundColor(.red)
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.05))
                    .cornerRadius(6)
                }
            }

            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(width: 420)
    }
}

// MARK: - New Wallet View

struct NewWalletView: View {
    let onComplete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedType: WalletTypeChoice?
    @State private var walletName = ""
    @State private var errorMessage: String?

    enum WalletTypeChoice { case smart, eoa }

    var body: some View {
        VStack(spacing: 16) {
            if selectedType == nil {
                typeSelectionStep
            } else {
                nameInputStep
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private var typeSelectionStep: some View {
        VStack(spacing: 16) {
            Text("New Wallet").font(.title2).bold()

            Button { selectedType = .smart } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("P-256 Smart Wallet").fontWeight(.semibold)
                    Text("Key secured by Secure Enclave hardware. Uses ERC-4337 account abstraction. Requires on-chain deployment before sending transactions.")
                        .font(.caption).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)

            Button { selectedType = .eoa } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("secp256k1 Traditional Wallet (legacy)").fontWeight(.semibold)
                    Text("Standard Ethereum EOA. Compatible with all dApps and off-chain signing. Key stored in Keychain, encrypted by Secure Enclave.")
                        .font(.caption).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)

            Button("Cancel") { dismiss() }
                .foregroundColor(.secondary)
        }
    }

    private var nameInputStep: some View {
        VStack(spacing: 16) {
            Text("Name Your Wallet").font(.title2).bold()

            TextField("Wallet name", text: $walletName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { create() }

            if let errorMessage {
                Text(errorMessage).foregroundColor(.red).font(.caption)
            }

            HStack {
                Button("Back") {
                    selectedType = nil
                    errorMessage = nil
                }
                Spacer()
                Button("Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .disabled(walletName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func create() {
        let name = walletName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        do {
            switch selectedType {
            case .smart: try EnclaveEngine.shared.generateKey()
            case .eoa: try EnclaveEngine.shared.generateEOAKey()
            case nil: return
            }

            if let wallet = EnclaveEngine.shared.currentWallet {
                EnclaveEngine.shared.renameWallet(at: wallet.index, to: name)
            }

            onComplete()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Send View

struct SendView: View {
    let onComplete: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var recipient = ""
    @State private var amount = ""
    @State private var selectedToken: Token = .eth
    @State private var status: SendStatus = .idle
    @State private var txHash = ""
    @State private var pendingOp: UserOperation?
    @State private var decodedActions: [DecodedAction] = []
    @State private var estimatedGasCost: String = ""

    enum Token: String, CaseIterable {
        case eth = "ETH"
        case usdc = "USDC"
    }

    enum SendStatus {
        case idle, building, previewing, signing, submitting, waiting, success, error(String)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Send").font(.title2).bold()

            TextField("Recipient address (0x...)", text: $recipient)
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)

            HStack {
                TextField("Amount", text: $amount)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)

                Picker("Token", selection: $selectedToken) {
                    ForEach(Token.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
            }

            if !recipient.isEmpty && !amount.isEmpty {
                preview
            }

            if case .previewing = status {
                TransactionPreviewView(
                    actions: decodedActions,
                    estimatedGas: estimatedGasCost,
                    onApprove: { confirmAndSign() },
                    onReject: {
                        status = .idle
                        pendingOp = nil
                    }
                )
            }

            statusView

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Send") { buildTransaction() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSend)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private var canSend: Bool {
        if case .idle = status {} else { return false }
        return !recipient.isEmpty && !amount.isEmpty && recipient.hasPrefix("0x") && recipient.count == 42
    }

    private var preview: some View {
        HStack {
            Text("Send \(amount) \(selectedToken.rawValue) to")
                .foregroundColor(.secondary)
            Text(String(recipient.prefix(6)) + "..." + String(recipient.suffix(4)))
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .idle: EmptyView()
        case .building: ProgressView("Building transaction...")
        case .previewing: EmptyView()
        case .signing: ProgressView("Waiting for Touch ID...")
        case .submitting: ProgressView("Submitting to bundler...")
        case .waiting: ProgressView("Waiting for confirmation...")
        case .success:
            VStack(spacing: 4) {
                Label("Transaction confirmed", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                if !txHash.isEmpty {
                    Text(txHash).font(.system(.caption2, design: .monospaced)).foregroundColor(.secondary)
                }
            }
        case .error(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
        }
    }

    private func buildTransaction() {
        guard let wallet = EnclaveEngine.shared.currentWallet else { return }
        guard wallet.isSmartWallet else {
            status = .error("Sending from EOA wallets is not yet supported")
            return
        }

        Task {
            do {
                status = .building

                var op = UserOperation(sender: wallet.address)

                let nonce = try await RPCClient.shared.getEntryPointNonce(sender: wallet.address)
                op.nonce = "0x" + String(nonce, radix: 16)

                if !wallet.isDeployed, let x = wallet.pubKeyX, let y = wallet.pubKeyY {
                    op.initCode = UserOperation.buildInitCode(
                        pubKeyX: x,
                        pubKeyY: y,
                        salt: UInt64(wallet.index)
                    )
                }

                switch selectedToken {
                case .eth:
                    let weiAmount = parseETHToWei(amount)
                    op.callData = UserOperation.buildETHTransfer(to: recipient, weiAmount: weiAmount)
                case .usdc:
                    let usdcAmount = parseUSDCToBase(amount)
                    op.callData = UserOperation.buildERC20Transfer(
                        token: Config.activeNetwork.usdcAddress,
                        to: recipient,
                        amount: usdcAmount
                    )
                }

                let (gasPrice, priorityFee) = try await (
                    RPCClient.shared.getGasPrice(),
                    RPCClient.shared.getMaxPriorityFeePerGas()
                )
                op.maxFeePerGas = gasPrice * 12 / 10
                op.maxPriorityFeePerGas = priorityFee
                op.signature = Data(repeating: 0, count: 64)

                var estimateOp = op
                estimateOp.preVerificationGas = 0
                estimateOp.verificationGasLimit = 0
                estimateOp.callGasLimit = 0

                let gasEstimate = try await BundlerClient.shared.estimateGas(
                    estimateOp.toDict(), entryPoint: Config.entryPointAddress
                )
                op.preVerificationGas = UInt64(gasEstimate.preVerificationGas.stripHexPrefix(), radix: 16) ?? 0
                op.verificationGasLimit = UInt64(gasEstimate.verificationGasLimit.stripHexPrefix(), radix: 16) ?? 0
                op.callGasLimit = UInt64(gasEstimate.callGasLimit.stripHexPrefix(), radix: 16) ?? 0

                let totalGas = op.preVerificationGas + op.verificationGasLimit + op.callGasLimit
                let gasCostWei = BigUInt(totalGas) * BigUInt(op.maxFeePerGas)
                estimatedGasCost = Wei(bigUInt: gasCostWei).ethFormatted + " ETH"

                decodedActions = CalldataDecoder.decode(callData: op.callData)
                pendingOp = op
                status = .previewing
            } catch {
                status = .error(error.localizedDescription)
                log.error("Build failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func confirmAndSign() {
        guard var op = pendingOp,
              let wallet = EnclaveEngine.shared.currentWallet else { return }

        Task {
            do {
                status = .signing

                let chainId = Config.activeNetwork.chainId
                let opHash = op.computeHash(entryPoint: Config.entryPointAddress, chainId: chainId)
                log.notice("UserOp hash: 0x\(opHash.map { String(format: "%02x", $0) }.joined(), privacy: .public)")
                let signature = try EnclaveEngine.shared.signEVMHashRaw(payloadHash: opHash)
                log.notice("Signature: 0x\(signature.map { String(format: "%02x", $0) }.joined(), privacy: .public)")
                op.signature = signature

                status = .submitting

                var userOpHash: String
                do {
                    userOpHash = try await BundlerClient.shared.sendUserOperation(
                        op.toDict(), entryPoint: Config.entryPointAddress
                    )
                } catch RPCError.replacementUnderpriced(let curMaxFee, let curPriorityFee) {
                    log.notice("Replacement underpriced, bumping gas to replace stuck op")
                    op.maxFeePerGas = curMaxFee * 13 / 10
                    op.maxPriorityFeePerGas = curPriorityFee * 13 / 10

                    let retryHash = op.computeHash(entryPoint: Config.entryPointAddress, chainId: chainId)
                    op.signature = try EnclaveEngine.shared.signEVMHashRaw(payloadHash: retryHash)

                    userOpHash = try await BundlerClient.shared.sendUserOperation(
                        op.toDict(), entryPoint: Config.entryPointAddress
                    )
                }

                status = .waiting

                let receipt = try await BundlerClient.shared.waitForReceipt(hash: userOpHash)
                txHash = receipt.receipt?.transactionHash ?? userOpHash

                if receipt.success {
                    status = .success
                    pendingOp = nil
                    await TransactionHistoryService.shared.recordSend(
                        from: wallet.address,
                        to: recipient,
                        value: amount,
                        tokenSymbol: selectedToken.rawValue,
                        txHash: txHash
                    )
                    onComplete()
                } else {
                    status = .error("Transaction reverted")
                }
            } catch {
                status = .error(error.localizedDescription)
                log.error("Send failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func parseETHToWei(_ str: String) -> BigUInt {
        guard let dotIndex = str.firstIndex(of: ".") else {
            return (BigUInt(str) ?? 0) * BigUInt(10).power(18)
        }
        let whole = String(str[str.startIndex..<dotIndex])
        var fraction = String(str[str.index(after: dotIndex)...])
        if fraction.count > 18 { fraction = String(fraction.prefix(18)) }
        fraction = fraction + String(repeating: "0", count: 18 - fraction.count)
        let wholePart = (BigUInt(whole) ?? 0) * BigUInt(10).power(18)
        let fracPart = BigUInt(fraction) ?? 0
        return wholePart + fracPart
    }

    private func parseUSDCToBase(_ str: String) -> BigUInt {
        guard let dotIndex = str.firstIndex(of: ".") else {
            return (BigUInt(str) ?? 0) * BigUInt(10).power(6)
        }
        let whole = String(str[str.startIndex..<dotIndex])
        var fraction = String(str[str.index(after: dotIndex)...])
        if fraction.count > 6 { fraction = String(fraction.prefix(6)) }
        fraction = fraction + String(repeating: "0", count: 6 - fraction.count)
        let wholePart = (BigUInt(whole) ?? 0) * BigUInt(10).power(6)
        let fracPart = BigUInt(fraction) ?? 0
        return wholePart + fracPart
    }
}

// MARK: - Receive View

struct ReceiveView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private var address: String {
        EnclaveEngine.shared.currentWallet?.address ?? ""
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Receive").font(.title2).bold()

            if let qrImage = generateQRCode(from: address) {
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 200, height: 200)
            }

            Text(address)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)

            Button(copied ? "Copied!" : "Copy Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(address, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
            }
            .buttonStyle(.borderedProminent)

            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(width: 320)
    }

    private func generateQRCode(from string: String) -> NSImage? {
        guard let data = string.data(using: .ascii),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")

        guard let ciImage = filter.outputImage else { return nil }
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let rep = NSCIImageRep(ciImage: scaled)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
    }
}

// MARK: - Transaction Preview

struct TransactionPreviewView: View {
    let actions: [DecodedAction]
    let estimatedGas: String
    let onApprove: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Review Transaction")
                .font(.headline)

            ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                HStack(spacing: 8) {
                    Image(systemName: iconForAction(action))
                        .foregroundColor(colorForAction(action))
                    Text(action.description)
                        .font(.system(.body, design: .monospaced))
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(6)
            }

            if !estimatedGas.isEmpty {
                HStack {
                    Text("Estimated gas:")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(estimatedGas)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            HStack {
                Button("Reject") { onReject() }
                Spacer()
                Button("Approve & Sign") { onApprove() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(10)
    }

    private func iconForAction(_ action: DecodedAction) -> String {
        switch action {
        case .ethTransfer: return "arrow.up.circle.fill"
        case .erc20Transfer: return "arrow.up.circle.fill"
        case .erc20Approve: return "checkmark.shield.fill"
        case .contractCall: return "doc.text.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    private func colorForAction(_ action: DecodedAction) -> Color {
        switch action {
        case .ethTransfer, .erc20Transfer: return .orange
        case .erc20Approve: return .yellow
        case .contractCall: return .blue
        case .unknown: return .gray
        }
    }
}

// MARK: - Window Accessor

private class WindowConfigView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyConfig()
    }

    override func layout() {
        super.layout()
        applyConfig()
    }

    private func applyConfig() {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
        window.isMovableByWindowBackground = true

        if window.toolbar == nil {
            let toolbar = NSToolbar(identifier: "main")
            toolbar.showsBaselineSeparator = false
            window.toolbar = toolbar
            window.toolbarStyle = .unified
        }
    }
}

struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowConfigView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
