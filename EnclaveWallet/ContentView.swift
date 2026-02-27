import SwiftUI
import WalletConnectSign
import BigInt
import os

private let log = Logger(subsystem: "com.plether.EnclaveWallet", category: "UI")

struct ContentView: View {
    @State private var showSend = false
    @State private var showReceive = false
    @State private var activeURL = "kitchen_sink"
    @State private var visitedURLs: Set<String> = []
    @State private var currentURL = ""
    @State private var activityRefreshId = UUID()
    @State private var showSessions = false
    @State private var lastPasteboardCount = NSPasteboard.general.changeCount

    @ObservedObject private var wcService = WalletConnectService.shared

    var body: some View {
        HSplitView {
            HStack(spacing: 0) {
                appSidebar
                Divider()
                WalledGardenWebView(urlString: activeURL, currentURL: $currentURL)
            }
            .frame(minWidth: 300)
            ActivityWebView(
                onSend: { showSend = true },
                onReceive: { showReceive = true },
                onPasteWC: { pasteWCURI() },
                onShowSessions: { showSessions = true },
                onSelectWallet: { index in
                    EnclaveEngine.shared.selectWallet(at: index)
                    refreshWallets()
                },
                onNewWallet: {
                    do {
                        try EnclaveEngine.shared.generateKey()
                        refreshWallets()
                    } catch {
                        log.error("Key generation failed: \(error.localizedDescription, privacy: .public)")
                    }
                },
                onSwitchNetwork: { raw in
                    if let network = Network(rawValue: raw) {
                        Config.activeNetwork = network
                        refreshBalances()
                        activityRefreshId = UUID()
                    }
                }
            )
                .id(activityRefreshId)
                .frame(minWidth: 220, idealWidth: 280, maxWidth: 360)
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
        .task { refreshBalances() }
        .task { await monitorClipboard() }
    }

    private func refreshWallets() {
        refreshBalances()
        notifyActivityWebView()
        activityRefreshId = UUID()
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
                    notifyActivityWebView()
                }
            } catch {
                log.error("Balance fetch failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func notifyActivityWebView() {
        NotificationCenter.default.post(name: .walletStateDidChange, object: nil)
    }

    private var appSidebar: some View {
        VStack(spacing: 8) {
            sidebarButton("house.fill", url: "kitchen_sink")
            sidebarButton("P", url: "https://app.plether.com")
            sidebarButton("U", url: "https://app.uniswap.org")
            sidebarButton("A", url: "https://app.aave.com")
            Spacer()
        }
        .padding(.vertical, 8)
        .frame(width: 44)
        .background(Color.black.opacity(0.03))
    }

    private func sidebarButton(_ icon: String, url: String) -> some View {
        let isActive = activeURL == url
        let isCached = isActive || visitedURLs.contains(url)
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
                .fill(isCached ? Color.accentColor : Color.clear)
                .frame(width: 3, height: 16)
                .offset(x: -6)
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
            Text("Session Proposal").font(.title2).bold()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("dApp:").foregroundColor(.secondary)
                    Text(proposal.proposer.name).bold()
                }
                HStack {
                    Text("URL:").foregroundColor(.secondary)
                    Text(proposal.proposer.url)
                        .font(.system(.body, design: .monospaced))
                }

                if !proposal.requiredNamespaces.isEmpty {
                    Text("Requested chains:").foregroundColor(.secondary)
                    ForEach(Array(proposal.requiredNamespaces.keys), id: \.self) { key in
                        if let ns = proposal.requiredNamespaces[key] {
                            Text("  \(key): \(ns.methods.joined(separator: ", "))")
                                .font(.caption)
                        }
                    }
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(8)

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
}

// MARK: - Request Approval View

extension Request: @retroactive Identifiable {}

struct RequestApprovalView: View {
    let request: Request
    let onApprove: () -> Void
    let onReject: () -> Void
    @Environment(\.dismiss) private var dismiss

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
                    Text(request.chainId.absoluteString)
                }

                if request.method == "personal_sign" {
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
            }
            .padding()
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(8)

            HStack {
                Button("Reject") {
                    onReject()
                    dismiss()
                }
                Spacer()
                Button("Approve & Sign") {
                    onApprove()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 420)
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

        Task {
            do {
                status = .building

                var op = UserOperation(sender: wallet.address)

                let nonce = try await RPCClient.shared.getEntryPointNonce(sender: wallet.address)
                op.nonce = "0x" + String(nonce, radix: 16)

                if !wallet.isDeployed {
                    op.initCode = UserOperation.buildInitCode(
                        pubKeyX: wallet.pubKeyX,
                        pubKeyY: wallet.pubKeyY,
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
