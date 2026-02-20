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

nonisolated struct PaymasterResponse: Sendable {
    let paymaster: String
    let paymasterData: String
    let paymasterVerificationGasLimit: String
    let paymasterPostOpGasLimit: String
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
        let reqBody = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = reqBody
        log.notice("Bundler request \(method, privacy: .public): \(String(data: reqBody, encoding: .utf8) ?? "nil", privacy: .public)")

        let (data, _) = try await session.data(for: request)
        let responseStr = String(data: data, encoding: .utf8) ?? "nil"
        log.notice("Bundler response: \(responseStr, privacy: .public)")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log.error("Bundler response not JSON: \(responseStr, privacy: .public)")
            throw RPCError.invalidResponse
        }
        if let error = json["error"] as? [String: Any] {
            let msg = error["message"] as? String ?? "Unknown"
            log.error("Bundler error (\(method, privacy: .public)): \(msg, privacy: .public)")

            if msg.contains("replacement underpriced"),
               let data = error["data"] as? [String: Any],
               let maxFeeHex = data["currentMaxFee"] as? String,
               let priorityHex = data["currentMaxPriorityFee"] as? String {
                throw RPCError.replacementUnderpriced(
                    currentMaxFee: UInt64(maxFeeHex.stripHexPrefix(), radix: 16) ?? 0,
                    currentMaxPriorityFee: UInt64(priorityHex.stripHexPrefix(), radix: 16) ?? 0
                )
            }

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
        log.notice("Signature being sent: \(op["signature"] ?? "nil", privacy: .public)")
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

    func getPaymasterData(_ op: [String: String], entryPoint: String) async throws -> PaymasterResponse {
        let dummySignature = "0x" + String(repeating: "00", count: 64)
        let result = try await call(
            method: "alchemy_requestGasAndPaymasterAndData",
            params: [Config.gasPolicyId, NSNull(), entryPoint, dummySignature, op]
        )
        guard let dict = result as? [String: Any] else { throw RPCError.invalidResponse }

        let v07 = dict["entrypointV07Response"] as? [String: Any] ?? dict

        guard let paymaster = v07["paymaster"] as? String,
              let paymasterData = v07["paymasterData"] as? String else {
            throw RPCError.serverError(code: -1, message: "Paymaster missing required fields")
        }

        return PaymasterResponse(
            paymaster: paymaster,
            paymasterData: paymasterData,
            paymasterVerificationGasLimit: v07["paymasterVerificationGasLimit"] as? String ?? "0x0",
            paymasterPostOpGasLimit: v07["paymasterPostOpGasLimit"] as? String ?? "0x0",
            preVerificationGas: v07["preVerificationGas"] as? String ?? "0x0",
            verificationGasLimit: v07["verificationGasLimit"] as? String ?? "0x0",
            callGasLimit: v07["callGasLimit"] as? String ?? "0x0"
        )
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
