import SwiftUI
import WebKit
import os

private let log = Logger(subsystem: "com.plether.EnclaveWallet", category: "WebView")

struct WalledGardenWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: "enclaveAPI")
        config.userContentController = userContentController

        let webView = WKWebView(frame: .zero, configuration: config)

        if let url = Bundle.main.url(forResource: "kitchen_sink", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, WKScriptMessageHandler {
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let action = body["action"] as? String else { return }

            if action == "request_signature" {
                guard let hashHex = body["hash"] as? String,
                      let hashData = Data(hexString: hashHex.replacingOccurrences(of: "0x", with: "")) else {
                    log.error("Invalid hash payload")
                    return
                }

                do {
                    let signature = try EnclaveEngine.shared.signEVMHash(payloadHash: hashData)
                    let js = "window.enclaveCallback('\(signature)');"
                    DispatchQueue.main.async { message.webView?.evaluateJavaScript(js, completionHandler: nil) }
                } catch {
                    log.info("User canceled Touch ID")
                }
            }
        }
    }
}

private extension Data {
    init?(hexString: String) {
        let len = hexString.count / 2
        var data = Data(capacity: len)
        var index = hexString.startIndex
        for _ in 0..<len {
            let nextIndex = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}
