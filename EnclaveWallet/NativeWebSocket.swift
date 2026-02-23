import Foundation
import WalletConnectRelay

final class NativeWebSocket: NSObject, WebSocketConnecting, URLSessionWebSocketDelegate {
    var isConnected = false
    var onConnect: (() -> Void)?
    var onDisconnect: ((Error?) -> Void)?
    var onText: ((String) -> Void)?
    var request: URLRequest

    private var task: URLSessionWebSocketTask?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    init(url: URL) {
        self.request = URLRequest(url: url)
        super.init()
    }

    func connect() {
        task = session.webSocketTask(with: request)
        task?.resume()
        listen()
    }

    func disconnect() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        isConnected = false
    }

    func write(string: String, completion: (() -> Void)?) {
        task?.send(.string(string)) { _ in completion?() }
    }

    private func listen() {
        task?.receive { [weak self] result in
            switch result {
            case .success(.string(let text)):
                self?.onText?(text)
            default:
                break
            }
            self?.listen()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                     didOpenWithProtocol protocol: String?) {
        isConnected = true
        onConnect?()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                     didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        isConnected = false
        onDisconnect?(nil)
    }
}

struct NativeWebSocketFactory: WebSocketFactory {
    func create(with url: URL) -> WebSocketConnecting {
        NativeWebSocket(url: url)
    }
}
