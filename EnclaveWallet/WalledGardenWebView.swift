import SwiftUI
import WebKit
import CryptoKit
import BigInt
import os

private let log = Logger(subsystem: "com.plether.EnclaveWallet", category: "WebView")

struct WalledGardenWebView: NSViewRepresentable {
    var urlString: String
    @Binding var currentURL: String
    @Binding var coordinatorRef: Coordinator?

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ container: NSView, context: Context) {
        let coordinator = context.coordinator
        if coordinatorRef !== coordinator { coordinatorRef = coordinator }
        if coordinator.activeURL == urlString { return }
        coordinator.activeURL = urlString

        let webView: WKWebView
        if let cached = coordinator.webViews[urlString] {
            webView = cached
        } else {
            webView = coordinator.createWebView(for: urlString)
            coordinator.webViews[urlString] = webView
        }

        container.subviews.forEach { $0.removeFromSuperview() }
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        coordinator.webView = webView
        currentURL = webView.url?.absoluteString ?? urlString
    }

    func makeCoordinator() -> Coordinator { Coordinator(currentURL: $currentURL) }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var activeURL = ""
        var webViews: [String: WKWebView] = [:]
        weak var webView: WKWebView?
        @Binding var currentURL: String

        init(currentURL: Binding<String>) {
            _currentURL = currentURL
            super.init()
            NotificationCenter.default.addObserver(
                self, selector: #selector(handleAccountChange),
                name: .walletStateDidChange, object: nil
            )
        }

        @objc private func handleAccountChange() {
            guard let address = EnclaveEngine.shared.currentWallet?.address else { return }
            log.notice("Account changed to \(address, privacy: .public), notifying \(self.webViews.count) webviews")
            let js = "if(typeof _enclaveAccountsChanged==='function')_enclaveAccountsChanged(['\(address)'])"
            for (key, wv) in webViews {
                log.notice("Sending accountsChanged to \(key, privacy: .public)")
                wv.evaluateJavaScript(js) { _, error in
                    if let error { log.error("JS eval error: \(error.localizedDescription, privacy: .public)") }
                }
            }
        }

        func createWebView(for urlString: String) -> WKWebView {
            let config = WKWebViewConfiguration()
            config.preferences.javaScriptCanOpenWindowsAutomatically = true
            config.defaultWebpagePreferences.allowsContentJavaScript = true
            config.userContentController.add(self, name: "enclave")
            config.setURLSchemeHandler(IPFSSchemeHandler(), forURLScheme: "ipfs")

            let wv = WKWebView(frame: .zero, configuration: config)
            wv.navigationDelegate = self
            wv.uiDelegate = self

            if urlString == "kitchen_sink" {
                if let url = Bundle.main.url(forResource: "kitchen_sink", withExtension: "html") {
                    wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
                }
            } else {
                var urlStr = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
                if !urlStr.contains("://") { urlStr = "https://" + urlStr }
                if let url = URL(string: urlStr) {
                    wv.load(URLRequest(url: url))
                }
            }
            return wv
        }

        // MARK: - WKScriptMessageHandler

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? String,
                  let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["id"] as? Int,
                  let method = json["method"] as? String else { return }

            let params = json["params"] as? [Any] ?? []
            log.notice("Bridge request #\(id, privacy: .public): \(method, privacy: .public)")

            Task { @MainActor in
                do {
                    let result = try await self.handleRequest(method: method, params: params)
                    self.respond(id: id, result: result)
                } catch {
                    self.respond(id: id, error: error.localizedDescription)
                }
            }
        }

        private func handleRequest(method: String, params: [Any]) async throws -> Any {
            guard let wallet = EnclaveEngine.shared.currentWallet else {
                throw BridgeError.noWallet
            }

            switch method {
            case "eth_accounts", "eth_requestAccounts":
                return [wallet.address]

            case "eth_chainId":
                return "0x" + String(Config.activeNetwork.chainId, radix: 16)

            case "eth_getBalance":
                let address = (params.first as? String) ?? wallet.address
                let balance = try await RPCClient.shared.getBalance(address: address)
                return "0x" + String(balance.value, radix: 16)

            case "eth_blockNumber":
                let block = try await RPCClient.shared.getBlockNumber()
                return "0x" + String(block, radix: 16)

            case "personal_sign":
                guard let hexMsg = params.first as? String else { throw BridgeError.invalidParams }
                let msgData = hexMsg.stripHexPrefix().hexToData() ?? Data()
                let prefix = "\u{19}Ethereum Signed Message:\n\(msgData.count)"
                var prefixed = Data(prefix.utf8)
                prefixed.append(msgData)
                let hash = Data(SHA256.hash(data: prefixed))
                return try EnclaveEngine.shared.signEVMHash(payloadHash: hash)

            case "eth_sendTransaction":
                guard let txObj = params.first as? [String: Any] else { throw BridgeError.invalidParams }
                return try await sendUserOperation(wallet: wallet, tx: txObj)

            case "wallet_switchEthereumChain":
                guard let chainObj = params.first as? [String: String],
                      let chainIdHex = chainObj["chainId"],
                      let chainId = UInt64(chainIdHex.stripHexPrefix(), radix: 16) else {
                    throw BridgeError.invalidParams
                }
                guard let network = Network.allCases.first(where: { $0.chainId == chainId }) else {
                    throw BridgeError.unsupportedChain(chainIdHex)
                }
                Config.activeNetwork = network
                NotificationCenter.default.post(name: .networkDidChange, object: nil)
                let js = "if(typeof _enclaveChainChanged==='function')_enclaveChainChanged('\(chainIdHex)')"
                for (_, wv) in webViews { wv.evaluateJavaScript(js, completionHandler: nil) }
                return NSNull()

            default:
                throw BridgeError.unsupportedMethod(method)
            }
        }

        private func sendUserOperation(wallet: Wallet, tx: [String: Any]) async throws -> String {
            let to = tx["to"] as? String ?? ""
            let valueHex = tx["value"] as? String ?? "0x0"
            let data = tx["data"] as? String ?? "0x"
            let weiValue = BigUInt(valueHex.stripHexPrefix(), radix: 16) ?? 0

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

            if data != "0x" && !data.isEmpty {
                let calldata = data.stripHexPrefix().hexToData() ?? Data()
                op.callData = UserOperation.buildExecuteCallData(to: to, value: weiValue, data: calldata)
            } else {
                op.callData = UserOperation.buildETHTransfer(to: to, weiAmount: weiValue)
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

            let chainId = Config.activeNetwork.chainId
            let opHash = op.computeHash(entryPoint: Config.entryPointAddress, chainId: chainId)
            op.signature = try EnclaveEngine.shared.signEVMHashRaw(payloadHash: opHash)

            var userOpHash: String
            do {
                userOpHash = try await BundlerClient.shared.sendUserOperation(
                    op.toDict(), entryPoint: Config.entryPointAddress
                )
            } catch RPCError.replacementUnderpriced(let curMaxFee, let curPriorityFee) {
                op.maxFeePerGas = curMaxFee * 13 / 10
                op.maxPriorityFeePerGas = curPriorityFee * 13 / 10
                let retryHash = op.computeHash(entryPoint: Config.entryPointAddress, chainId: chainId)
                op.signature = try EnclaveEngine.shared.signEVMHashRaw(payloadHash: retryHash)
                userOpHash = try await BundlerClient.shared.sendUserOperation(
                    op.toDict(), entryPoint: Config.entryPointAddress
                )
            }

            let receipt = try await BundlerClient.shared.waitForReceipt(hash: userOpHash)
            guard receipt.success else { throw BridgeError.txReverted }
            return receipt.receipt?.transactionHash ?? userOpHash
        }

        private func respond(id: Int, result: Any) {
            let jsonStr: String
            if result is NSNull {
                jsonStr = "null"
            } else if let str = result as? String {
                let escaped = str.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                jsonStr = "\"\(escaped)\""
            } else if let arr = result as? [String] {
                let items = arr.map { "\"\($0)\"" }.joined(separator: ",")
                jsonStr = "[\(items)]"
            } else if let data = try? JSONSerialization.data(withJSONObject: result),
                      let str = String(data: data, encoding: .utf8) {
                jsonStr = str
            } else {
                respond(id: id, error: "Failed to serialize result")
                return
            }
            let js = "_enclaveResponse(\(id), \(jsonStr), null)"
            webView?.evaluateJavaScript(js, completionHandler: nil)
        }

        private func respond(id: Int, error: String) {
            let escaped = error.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let js = "_enclaveResponse(\(id), null, \"\(escaped)\")"
            webView?.evaluateJavaScript(js, completionHandler: nil)
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url {
                if url.scheme == "wc" {
                    let uriString = url.absoluteString
                    log.notice("Intercepted WC URI: \(uriString, privacy: .public)")
                    WalletConnectService.shared.pair(uriString: uriString)
                    decisionHandler(.cancel)
                    return
                }
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let url = webView.url?.absoluteString {
                DispatchQueue.main.async { self.currentURL = url }
            }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                      for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                if url.scheme == "wc" {
                    log.notice("Intercepted WC URI from window.open: \(url.absoluteString, privacy: .public)")
                    WalletConnectService.shared.pair(uriString: url.absoluteString)
                    return nil
                }
                webView.load(URLRequest(url: url))
            }
            return nil
        }
    }
}

private enum BridgeError: LocalizedError {
    case noWallet
    case invalidParams
    case unsupportedMethod(String)
    case txReverted
    case unsupportedChain(String)

    var errorDescription: String? {
        switch self {
        case .noWallet: "No wallet selected"
        case .invalidParams: "Invalid parameters"
        case .unsupportedMethod(let m): "Unsupported method: \(m)"
        case .txReverted: "Transaction reverted"
        case .unsupportedChain(let id): "Unrecognized chain ID: \(id)"
        }
    }
}

struct ActivityWebView: NSViewRepresentable {
    var onSend: () -> Void
    var onReceive: () -> Void
    var onPasteWC: () -> Void
    var onSelectWallet: (Int) -> Void
    var onNewWallet: () -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "wallet")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView

        if let url = Bundle.main.url(forResource: "panel", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        let c = context.coordinator
        c.onSend = onSend
        c.onReceive = onReceive
        c.onPasteWC = onPasteWC
        c.onSelectWallet = onSelectWallet
        c.onNewWallet = onNewWallet
    }

    func makeCoordinator() -> ActivityCoordinator { ActivityCoordinator() }

    class ActivityCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?

        var onSend: (() -> Void)?
        var onReceive: (() -> Void)?
        var onPasteWC: (() -> Void)?
        var onSelectWallet: ((Int) -> Void)?
        var onNewWallet: (() -> Void)?

        override init() {
            super.init()
            NotificationCenter.default.addObserver(
                self, selector: #selector(handleWalletStateChange),
                name: .walletStateDidChange, object: nil
            )
        }

        @objc private func handleWalletStateChange() {
            updateWalletState()
            loadTransactionHistory()
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? String,
                  let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let action = json["action"] as? String else { return }

            switch action {
            case "send": onSend?()
            case "receive": onReceive?()
            case "pasteWC": onPasteWC?()
            case "newWallet": onNewWallet?()
            case "selectWallet":
                if let index = json["data"] as? Int { onSelectWallet?(index) }
            case "renameWallet":
                if let payload = json["data"] as? [String: Any],
                   let index = payload["index"] as? Int,
                   let name = payload["name"] as? String {
                    EnclaveEngine.shared.renameWallet(at: index, to: name)
                }
            default: break
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            updateWalletState()
            loadTransactionHistory()
        }

        func updateWalletState() {
            let wallets = EnclaveEngine.shared.wallets.map { w -> [String: Any] in
                ["index": w.index, "display": w.displayAddress, "address": w.address, "name": w.name]
            }
            let state: [String: Any] = [
                "displayAddress": EnclaveEngine.shared.currentWallet?.displayAddress ?? "No Wallet",
                "address": EnclaveEngine.shared.currentWallet?.address ?? "",
                "name": EnclaveEngine.shared.currentWallet?.name ?? "No Wallet",
                "ethBalance": UserDefaults.standard.string(forKey: "cachedEthBalance") ?? "...",
                "usdcBalance": UserDefaults.standard.string(forKey: "cachedUsdcBalance") ?? "...",
                "networkName": Config.activeNetwork.displayName,
                "sessionsCount": WalletConnectService.shared.sessions.count,
                "selectedIndex": EnclaveEngine.shared.selectedIndex,
                "wallets": wallets,
            ]
            guard let jsonData = try? JSONSerialization.data(withJSONObject: state),
                  let jsonString = String(data: jsonData, encoding: .utf8) else { return }
            let escaped = jsonString.replacingOccurrences(of: "'", with: "\\'")
            webView?.evaluateJavaScript("window.updateWallet('\(escaped)');", completionHandler: nil)
        }

        func loadTransactionHistory() {
            guard let address = EnclaveEngine.shared.currentWallet?.address else { return }
            Task {
                let txs = await TransactionHistoryService.shared.fetchHistory(address: address)
                let jsonItems = txs.prefix(20).map { tx -> [String: Any] in
                    let formatter = RelativeDateTimeFormatter()
                    formatter.unitsStyle = .short
                    let timeStr = formatter.localizedString(for: tx.timestamp, relativeTo: Date())
                    return [
                        "incoming": tx.isIncoming,
                        "address": tx.displayAddress,
                        "value": tx.value,
                        "symbol": tx.tokenSymbol,
                        "time": timeStr,
                    ]
                }
                guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonItems),
                      let jsonString = String(data: jsonData, encoding: .utf8) else { return }
                let escaped = jsonString.replacingOccurrences(of: "'", with: "\\'")
                let js = "window.updateHistory('\(escaped)');"
                await MainActor.run {
                    webView?.evaluateJavaScript(js, completionHandler: nil)
                }
            }
        }
    }
}

extension Notification.Name {
    static let walletStateDidChange = Notification.Name("walletStateDidChange")
    static let networkDidChange = Notification.Name("networkDidChange")
}
