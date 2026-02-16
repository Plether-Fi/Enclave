import SwiftUI
import WebKit
import os

private let log = Logger(subsystem: "com.plether.EnclaveWallet", category: "WebView")

struct WalledGardenWebView: NSViewRepresentable {
    var page: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: "enclaveAPI")
        config.userContentController = userContentController

        let webView = WKWebView(frame: .zero, configuration: config)
        loadPage(page, into: webView)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if context.coordinator.currentPage != page {
            context.coordinator.currentPage = page
            loadPage(page, into: nsView)
        }
    }

    private func loadPage(_ page: String, into webView: WKWebView) {
        if let url = Bundle.main.url(forResource: page, withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(page: page) }

    class Coordinator: NSObject, WKScriptMessageHandler {
        var currentPage: String

        init(page: String) {
            self.currentPage = page
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let action = body["action"] as? String else { return }

            if action == "request_signature" {
                guard let hashHex = body["hash"] as? String,
                      let hashData = hashHex.stripHexPrefix().hexToData() else {
                    log.error("Invalid hash payload")
                    DispatchQueue.main.async { message.webView?.evaluateJavaScript("window.enclaveError('Invalid hash')", completionHandler: nil) }
                    return
                }

                do {
                    let signature = try EnclaveEngine.shared.signEVMHash(payloadHash: hashData)
                    let js = "window.enclaveCallback('\(signature)');"
                    DispatchQueue.main.async { message.webView?.evaluateJavaScript(js, completionHandler: nil) }
                } catch {
                    log.notice("User canceled Touch ID")
                    let js = "window.enclaveError('User canceled authentication');"
                    DispatchQueue.main.async {
                        message.webView?.evaluateJavaScript(js) { _, err in
                            if let err { log.error("JS error callback failed: \(err.localizedDescription, privacy: .public)") }
                        }
                    }
                }
            }
        }
    }
}

struct ActivityWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView

        if let url = Bundle.main.url(forResource: "activity", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
    func makeCoordinator() -> ActivityCoordinator { ActivityCoordinator() }

    class ActivityCoordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loadTransactionHistory()
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
