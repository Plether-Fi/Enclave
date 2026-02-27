import WebKit
import os
import UniformTypeIdentifiers

private let log = Logger(subsystem: "com.plether.EnclaveWallet", category: "IPFS")

private let gateways = [
    "https://ipfs.io/ipfs/",
    "https://cloudflare-ipfs.com/ipfs/",
    "https://dweb.link/ipfs/",
]

class IPFSSchemeHandler: NSObject, WKURLSchemeHandler {
    private var activeTasks: Set<ObjectIdentifier> = []
    private let lock = NSLock()

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let taskID = ObjectIdentifier(urlSchemeTask as AnyObject)
        lock.withLock { activeTasks.insert(taskID) }

        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(IPFSError.invalidURL)
            return
        }

        let host = url.host() ?? ""
        let path = url.path()
        let gatewayPath = host + path

        log.notice("Fetching ipfs://\(gatewayPath, privacy: .public)")

        Task {
            do {
                let (data, contentType) = try await fetchFromGateways(path: gatewayPath, taskID: taskID)
                guard isActive(taskID) else { return }

                let inferredType = contentType ?? self.inferContentType(for: gatewayPath)
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": inferredType, "Content-Length": "\(data.count)"]
                )!

                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            } catch {
                guard isActive(taskID) else { return }
                log.error("IPFS fetch failed: \(error.localizedDescription, privacy: .public)")
                urlSchemeTask.didFailWithError(error)
            }

            lock.withLock { _ = activeTasks.remove(taskID) }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        let taskID = ObjectIdentifier(urlSchemeTask as AnyObject)
        lock.withLock { _ = activeTasks.remove(taskID) }
    }

    private func isActive(_ taskID: ObjectIdentifier) -> Bool {
        lock.withLock { activeTasks.contains(taskID) }
    }

    private func fetchFromGateways(path: String, taskID: ObjectIdentifier) async throws -> (Data, String?) {
        var lastError: Error = IPFSError.allGatewaysFailed

        for gateway in gateways {
            guard isActive(taskID) else { throw CancellationError() }
            guard let url = URL(string: gateway + path) else { continue }

            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                let httpResponse = response as? HTTPURLResponse
                guard let statusCode = httpResponse?.statusCode, (200..<300).contains(statusCode) else {
                    lastError = IPFSError.httpError(httpResponse?.statusCode ?? 0)
                    continue
                }
                let contentType = httpResponse?.value(forHTTPHeaderField: "Content-Type")
                return (data, contentType)
            } catch {
                lastError = error
                continue
            }
        }

        throw lastError
    }

    private func inferContentType(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        if ext.isEmpty { return "text/html" }

        if let utType = UTType(filenameExtension: ext), let mime = utType.preferredMIMEType {
            return mime
        }

        return "application/octet-stream"
    }
}

nonisolated enum IPFSError: LocalizedError {
    case invalidURL
    case allGatewaysFailed
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid IPFS URL"
        case .allGatewaysFailed: "All IPFS gateways failed"
        case .httpError(let code): "HTTP \(code)"
        }
    }
}
