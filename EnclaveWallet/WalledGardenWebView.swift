import SwiftUI
import WebKit
import os

private let log = Logger(subsystem: "com.plether.EnclaveWallet", category: "WebView")

struct WalledGardenWebView: NSViewRepresentable {
    var urlString: String
    @Binding var currentURL: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.webView = webView
        loadURL(urlString, into: webView)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if context.coordinator.lastLoadedURL != urlString {
            context.coordinator.lastLoadedURL = urlString
            loadURL(urlString, into: nsView)
        }
    }

    private func loadURL(_ string: String, into webView: WKWebView) {
        var urlStr = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !urlStr.contains("://") { urlStr = "https://" + urlStr }

        guard let url = URL(string: urlStr) else { return }
        webView.load(URLRequest(url: url))
    }

    func makeCoordinator() -> Coordinator { Coordinator(currentURL: $currentURL) }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var lastLoadedURL = ""
        weak var webView: WKWebView?
        @Binding var currentURL: String

        init(currentURL: Binding<String>) {
            _currentURL = currentURL
        }

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
