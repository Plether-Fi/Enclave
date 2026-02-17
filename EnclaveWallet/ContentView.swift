import SwiftUI
import BigInt
import os

private let log = Logger(subsystem: "com.plether.EnclaveWallet", category: "UI")

struct ContentView: View {
    @State private var wallets: [Wallet] = EnclaveEngine.shared.wallets
    @State private var selectedAddress: String = EnclaveEngine.shared.currentWallet?.displayAddress ?? "No Wallet"
    @State private var ethBalance: String = "..."
    @State private var usdcBalance: String = "..."
    @State private var showSend = false
    @State private var showReceive = false
    @State private var selectedApp = "kitchen_sink"

    private let apps: [(name: String, resource: String)] = [
        ("Kitchen Sink", "kitchen_sink"),
    ]

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                toolbar
                balanceBar
                Divider()
                WalledGardenWebView(page: selectedApp)
            }
            .frame(minWidth: 300)
            ActivityWebView()
                .frame(minWidth: 220, idealWidth: 280, maxWidth: 360)
        }
        .sheet(isPresented: $showSend) {
            SendView(onComplete: { refreshBalances() })
        }
        .sheet(isPresented: $showReceive) {
            ReceiveView()
        }
        .task { refreshBalances() }
    }

    private func refreshWallets() {
        wallets = EnclaveEngine.shared.wallets
        selectedAddress = EnclaveEngine.shared.currentWallet?.displayAddress ?? "No Wallet"
        refreshBalances()
    }

    private func refreshBalances() {
        guard let wallet = EnclaveEngine.shared.currentWallet else { return }
        Task {
            do {
                let eth = try await RPCClient.shared.getBalance(address: wallet.address)
                let usdc = try await RPCClient.shared.getERC20Balance(
                    token: Config.activeNetwork.usdcAddress,
                    owner: wallet.address
                )
                await MainActor.run {
                    ethBalance = eth.ethFormatted
                    usdcBalance = usdc.usdcFormatted
                }
            } catch {
                log.error("Balance fetch failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(wallets, id: \.index) { wallet in
                    Button(wallet.displayAddress) {
                        EnclaveEngine.shared.selectWallet(at: wallet.index)
                        refreshWallets()
                    }
                }
                if !wallets.isEmpty { Divider() }
                Button("New Wallet") {
                    do {
                        try EnclaveEngine.shared.generateKey()
                        refreshWallets()
                    } catch {
                        log.error("Key generation failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            } label: {
                Text(selectedAddress)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.1))
                    .clipShape(Capsule())
            }

            Button { showReceive = true } label: {
                Label("Receive", systemImage: "arrow.down.circle")
            }

            Button { showSend = true } label: {
                Label("Send", systemImage: "arrow.up.circle")
            }

            Spacer()

            Menu {
                ForEach(apps, id: \.resource) { app in
                    Button(app.name) { selectedApp = app.resource }
                }
            } label: {
                let displayName = apps.first(where: { $0.resource == selectedApp })?.name ?? selectedApp
                Text(displayName)
                    .font(.system(.caption))
                    .foregroundColor(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.1))
                    .clipShape(Capsule())
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.black)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var balanceBar: some View {
        HStack(spacing: 24) {
            HStack(spacing: 4) {
                Text(ethBalance).font(.system(.body, design: .monospaced)).bold()
                Text("ETH").foregroundColor(.secondary)
            }
            HStack(spacing: 4) {
                Text(usdcBalance).font(.system(.body, design: .monospaced)).bold()
                Text("USDC").foregroundColor(.secondary)
            }
            Spacer()
            Menu {
                ForEach(Network.allCases, id: \.rawValue) { network in
                    Button(network.displayName) {
                        Config.activeNetwork = network
                        refreshBalances()
                    }
                }
            } label: {
                Text(Config.activeNetwork.displayName)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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

                let nonce = try await RPCClient.shared.getTransactionCount(address: wallet.address)
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
                op.maxFeePerGas = gasPrice
                op.maxPriorityFeePerGas = priorityFee

                let gasEstimate = try await BundlerClient.shared.estimateGas(
                    op.toDict(), entryPoint: Config.entryPointAddress
                )
                op.preVerificationGas = UInt64(gasEstimate.preVerificationGas.stripHexPrefix(), radix: 16) ?? op.preVerificationGas
                op.verificationGasLimit = UInt64(gasEstimate.verificationGasLimit.stripHexPrefix(), radix: 16) ?? op.verificationGasLimit
                op.callGasLimit = UInt64(gasEstimate.callGasLimit.stripHexPrefix(), radix: 16) ?? op.callGasLimit

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
        guard var op = pendingOp else { return }

        Task {
            do {
                status = .signing

                let chainId = Config.activeNetwork.chainId
                let opHash = op.computeHash(entryPoint: Config.entryPointAddress, chainId: chainId)
                let signature = try EnclaveEngine.shared.signEVMHashRaw(payloadHash: opHash)
                op.signature = signature

                status = .submitting

                let userOpHash = try await BundlerClient.shared.sendUserOperation(
                    op.toDict(), entryPoint: Config.entryPointAddress
                )

                status = .waiting

                let receipt = try await BundlerClient.shared.waitForReceipt(hash: userOpHash)
                txHash = receipt.receipt?.transactionHash ?? userOpHash

                if receipt.success {
                    status = .success
                    pendingOp = nil
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
