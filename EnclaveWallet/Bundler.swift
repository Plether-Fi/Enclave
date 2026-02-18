import Foundation
import os

nonisolated(unsafe) private let log = Logger(subsystem: "com.plether.EnclaveWallet", category: "Bundler")

nonisolated struct UserOperationReceipt: Decodable, Sendable {
    let userOpHash: String
    let success: Bool
    let actualGasCost: String
    let actualGasUsed: String
    let receipt: TransactionReceipt?
}

nonisolated struct TransactionReceipt: Decodable, Sendable {
    let transactionHash: String
    let blockNumber: String
    let status: String

    var succeeded: Bool { status == "0x1" }
}

nonisolated struct GasEstimate: Sendable {
    let preVerificationGas: String
    let verificationGasLimit: String
    let callGasLimit: String
}

actor BundlerClient {
    static let shared = BundlerClient()

    private let session = URLSession.shared
    private var requestId = 0

    private func nextId() -> Int {
        requestId += 1
        return requestId
    }

    private func call(method: String, params: [Any]) async throws -> Any {
        let id = nextId()
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
            "id": id
        ]

        var request = URLRequest(url: Config.activeNetwork.bundlerURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log.error("Bundler response not JSON: \(String(data: data, encoding: .utf8) ?? "nil", privacy: .public)")
            throw RPCError.invalidResponse
        }
        if let error = json["error"] as? [String: Any] {
            let msg = error["message"] as? String ?? "Unknown"
            log.error("Bundler error: \(msg, privacy: .public)")
            throw RPCError.serverError(
                code: error["code"] as? Int ?? -1,
                message: msg
            )
        }
        guard let result = json["result"] else {
            log.error("Bundler response missing 'result': \(json.keys.joined(separator: ","), privacy: .public)")
            throw RPCError.invalidResponse
        }
        return result
    }

    func sendUserOperation(_ op: [String: String], entryPoint: String) async throws -> String {
        let result = try await call(method: "eth_sendUserOperation", params: [op, entryPoint])
        guard let hash = result as? String else { throw RPCError.invalidResponse }
        log.notice("UserOp submitted: \(hash, privacy: .public)")
        return hash
    }

    func estimateGas(_ op: [String: String], entryPoint: String) async throws -> GasEstimate {
        let result = try await call(method: "eth_estimateUserOperationGas", params: [op, entryPoint])
        guard let dict = result as? [String: Any] else { throw RPCError.invalidResponse }

        return GasEstimate(
            preVerificationGas: dict["preVerificationGas"] as? String ?? "0x0",
            verificationGasLimit: dict["verificationGasLimit"] as? String ?? "0x0",
            callGasLimit: dict["callGasLimit"] as? String ?? "0x0"
        )
    }

    func getUserOperationReceipt(hash: String) async throws -> UserOperationReceipt? {
        let result = try await call(method: "eth_getUserOperationReceipt", params: [hash])
        if result is NSNull { return nil }

        let data = try JSONSerialization.data(withJSONObject: result)
        return try JSONDecoder().decode(UserOperationReceipt.self, from: data)
    }

    func getPaymasterData(_ op: [String: String], entryPoint: String) async throws -> String? {
        guard let paymasterURL = Config.paymasterURL else { return nil }

        let id = nextId()
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "pm_sponsorUserOperation",
            "params": [op, entryPoint],
            "id": id
        ]

        var request = URLRequest(url: paymasterURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let error = json["error"] as? [String: Any] {
            log.notice("Paymaster declined: \(error["message"] as? String ?? "unknown", privacy: .public)")
            return nil
        }
        guard let result = json["result"] as? [String: Any],
              let paymasterAndData = result["paymasterAndData"] as? String else {
            return nil
        }
        return paymasterAndData
    }

    func waitForReceipt(hash: String, timeout: TimeInterval = 60) async throws -> UserOperationReceipt {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let receipt = try await getUserOperationReceipt(hash: hash) {
                return receipt
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw RPCError.serverError(code: -1, message: "Timeout waiting for UserOperation receipt")
    }
}
