import Foundation
import WebKit
import BigInt
import os

private let log = Logger(subsystem: "com.plether.EnclaveWallet", category: "Bridge")

struct BridgeRequest: @unchecked Sendable {
    let id: Int
    let method: String
    let params: [Any]

    init?(from body: [String: Any]) {
        guard let id = body["id"] as? Int,
              let method = body["method"] as? String else { return nil }
        self.id = id
        self.method = method
        self.params = body["params"] as? [Any] ?? []
    }
}

class ProviderBridge {
    private weak var webView: WKWebView?
    private let appId: String

    init(webView: WKWebView?, appId: String) {
        self.webView = webView
        self.appId = appId
    }

    func updateWebView(_ webView: WKWebView?) {
        self.webView = webView
    }

    func handle(_ request: BridgeRequest) async {
        let permission = await AppPermissionStore.shared.check(appId: appId, method: request.method)
        switch permission {
        case .denied(let reason):
            reject(id: request.id, code: 4100, message: reason)
            return
        case .needsPrompt:
            await AppPermissionStore.shared.grant(
                appId: appId,
                methods: [request.method],
                expiresIn: 3600
            )
        case .allowed:
            break
        }

        switch request.method {
        case "eth_requestAccounts", "eth_accounts":
            handleAccounts(request)
        case "eth_chainId":
            handleChainId(request)
        case "net_version":
            handleNetVersion(request)
        case "personal_sign":
            await handlePersonalSign(request)
        case "eth_signTypedData_v4":
            await handleSignTypedData(request)
        case "eth_sendTransaction":
            await handleSendTransaction(request)
        case "eth_getBalance", "eth_call", "eth_blockNumber",
             "eth_estimateGas", "eth_gasPrice", "eth_getCode",
             "eth_getTransactionCount", "eth_getTransactionReceipt":
            await handleRPCProxy(request)
        default:
            reject(id: request.id, code: 4200, message: "Unsupported method: \(request.method)")
        }
    }

    // MARK: - Read-only handlers

    private func handleAccounts(_ request: BridgeRequest) {
        guard let address = EnclaveEngine.shared.currentWallet?.address else {
            resolve(id: request.id, result: "[]")
            return
        }
        resolve(id: request.id, result: "[\"\(address)\"]")
    }

    private func handleChainId(_ request: BridgeRequest) {
        let chainId = Config.activeNetwork.chainId
        resolve(id: request.id, result: "\"0x\(String(chainId, radix: 16))\"")
    }

    private func handleNetVersion(_ request: BridgeRequest) {
        let chainId = Config.activeNetwork.chainId
        resolve(id: request.id, result: "\"\(chainId)\"")
    }

    // MARK: - Signing handlers

    private func handlePersonalSign(_ request: BridgeRequest) async {
        guard request.params.count >= 1,
              let messageHex = request.params[0] as? String,
              let messageData = messageHex.stripHexPrefix().hexToData() else {
            reject(id: request.id, code: -32602, message: "Invalid params")
            return
        }

        let prefix = "\u{19}Ethereum Signed Message:\n\(messageData.count)"
        var prefixed = Data(prefix.utf8)
        prefixed.append(messageData)
        let hash = Data(Array(prefixed).sha3(.keccak256))

        do {
            let signature = try EnclaveEngine.shared.signEVMHash(payloadHash: hash)
            resolve(id: request.id, result: "\"\(signature)\"")
        } catch {
            reject(id: request.id, code: 4001, message: "User rejected signing")
        }
    }

    private func handleSignTypedData(_ request: BridgeRequest) async {
        guard request.params.count >= 2,
              let typedDataJson = request.params[1] as? String,
              let jsonData = typedDataJson.data(using: .utf8) else {
            reject(id: request.id, code: -32602, message: "Invalid params")
            return
        }

        let hash = Data(Array(jsonData).sha3(.keccak256))

        do {
            let signature = try EnclaveEngine.shared.signEVMHash(payloadHash: hash)
            resolve(id: request.id, result: "\"\(signature)\"")
        } catch {
            reject(id: request.id, code: 4001, message: "User rejected signing")
        }
    }

    private func handleSendTransaction(_ request: BridgeRequest) async {
        guard let wallet = EnclaveEngine.shared.currentWallet,
              request.params.count >= 1,
              let txDict = request.params[0] as? [String: Any] else {
            reject(id: request.id, code: -32602, message: "Invalid params")
            return
        }

        let to = txDict["to"] as? String ?? ""
        let valueHex = txDict["value"] as? String ?? "0x0"
        let dataHex = txDict["data"] as? String ?? "0x"
        let weiValue = BigUInt(valueHex.stripHexPrefix(), radix: 16) ?? 0

        do {
            var op = UserOperation(sender: wallet.address)

            let nonce = try await RPCClient.shared.getEntryPointNonce(sender: wallet.address)
            op.nonce = "0x" + String(nonce, radix: 16)

            if !wallet.isDeployed {
                op.initCode = UserOperation.buildInitCode(
                    pubKeyX: wallet.pubKeyX,
                    pubKeyY: wallet.pubKeyY,
                    salt: UInt64(wallet.index)
                )
                op.verificationGasLimit = 5_000_000
            }

            let innerCalldata = dataHex.stripHexPrefix().hexToData() ?? Data()
            op.callData = UserOperation.buildExecuteCallData(to: to, value: weiValue, data: innerCalldata)

            let (gasPrice, priorityFee) = try await (
                RPCClient.shared.getGasPrice(),
                RPCClient.shared.getMaxPriorityFeePerGas()
            )
            op.maxFeePerGas = gasPrice * 12 / 10
            op.maxPriorityFeePerGas = priorityFee
            op.signature = Data(repeating: 0, count: 64)

            let gasEstimate = try await BundlerClient.shared.estimateGas(
                op.toDict(), entryPoint: Config.entryPointAddress
            )
            op.preVerificationGas = UInt64(gasEstimate.preVerificationGas.stripHexPrefix(), radix: 16) ?? op.preVerificationGas
            op.verificationGasLimit = UInt64(gasEstimate.verificationGasLimit.stripHexPrefix(), radix: 16) ?? op.verificationGasLimit
            op.callGasLimit = UInt64(gasEstimate.callGasLimit.stripHexPrefix(), radix: 16) ?? op.callGasLimit

            let chainId = Config.activeNetwork.chainId
            let opHash = op.computeHash(entryPoint: Config.entryPointAddress, chainId: chainId)
            let signature = try EnclaveEngine.shared.signEVMHashRaw(payloadHash: opHash)
            op.signature = signature

            let userOpHash = try await BundlerClient.shared.sendUserOperation(
                op.toDict(), entryPoint: Config.entryPointAddress
            )

            let receipt = try await BundlerClient.shared.waitForReceipt(hash: userOpHash)
            let txHash = receipt.receipt?.transactionHash ?? userOpHash
            resolve(id: request.id, result: "\"\(txHash)\"")
        } catch {
            reject(id: request.id, code: -32000, message: error.localizedDescription)
        }
    }

    // MARK: - RPC Proxy

    private func handleRPCProxy(_ request: BridgeRequest) async {
        do {
            let result: String
            switch request.method {
            case "eth_getBalance":
                guard let addr = request.params.first as? String else { throw RPCError.invalidResponse }
                let balance = try await RPCClient.shared.getBalance(address: addr)
                result = "\"0x\(String(balance.value, radix: 16))\""
            case "eth_blockNumber":
                let block = try await RPCClient.shared.getBlockNumber()
                result = "\"0x\(String(block, radix: 16))\""
            case "eth_call":
                guard let callObj = request.params.first as? [String: Any],
                      let to = callObj["to"] as? String,
                      let data = callObj["data"] as? String else { throw RPCError.invalidResponse }
                let callResult = try await RPCClient.shared.ethCall(to: to, data: data)
                result = "\"\(callResult)\""
            case "eth_estimateGas":
                guard let callObj = request.params.first as? [String: Any],
                      let to = callObj["to"] as? String else { throw RPCError.invalidResponse }
                let gas = try await RPCClient.shared.estimateGas(
                    to: to,
                    from: callObj["from"] as? String,
                    data: callObj["data"] as? String,
                    value: callObj["value"] as? String
                )
                result = "\"0x\(String(gas, radix: 16))\""
            case "eth_gasPrice":
                let price = try await RPCClient.shared.getGasPrice()
                result = "\"0x\(String(price, radix: 16))\""
            case "eth_getCode":
                guard let addr = request.params.first as? String else { throw RPCError.invalidResponse }
                let code = try await RPCClient.shared.getCode(address: addr)
                result = "\"\(code)\""
            case "eth_getTransactionCount":
                guard let addr = request.params.first as? String else { throw RPCError.invalidResponse }
                let count = try await RPCClient.shared.getTransactionCount(address: addr)
                result = "\"0x\(String(count, radix: 16))\""
            default:
                throw RPCError.invalidResponse
            }
            resolve(id: request.id, result: result)
        } catch {
            reject(id: request.id, code: -32000, message: error.localizedDescription)
        }
    }

    // MARK: - Response helpers

    private func resolve(id: Int, result: String) {
        let js = "window.enclave._resolve(\(id), \(result));"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    private func reject(id: Int, code: Int, message: String) {
        let escaped = message.replacingOccurrences(of: "\"", with: "\\\"")
        let js = "window.enclave._reject(\(id), {code: \(code), message: \"\(escaped)\"});"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    static let injectedScript: String = """
    window.enclave = {
        _pending: {},
        _nextId: 1,
        request({method, params}) {
            return new Promise((resolve, reject) => {
                const id = this._nextId++;
                this._pending[id] = {resolve, reject};
                window.webkit.messageHandlers.enclaveAPI.postMessage({
                    id: id, method: method, params: params || []
                });
            });
        },
        _resolve(id, result) {
            const p = this._pending[id];
            if (p) { delete this._pending[id]; p.resolve(result); }
        },
        _reject(id, error) {
            const p = this._pending[id];
            if (p) { delete this._pending[id]; p.reject(error); }
        },
        on(event, handler) { this._events = this._events || {}; (this._events[event] = this._events[event] || []).push(handler); },
        removeListener(event, handler) {
            if (!this._events || !this._events[event]) return;
            this._events[event] = this._events[event].filter(h => h !== handler);
        },
        _emit(event, data) {
            if (this._events && this._events[event]) {
                this._events[event].forEach(h => h(data));
            }
        },
        isEnclave: true
    };
    """
}

import CryptoSwift

private extension [UInt8] {
    func sha3(_ variant: CryptoSwift.SHA3.Variant) -> [UInt8] {
        Digest.sha3(self, variant: variant)
    }
}
