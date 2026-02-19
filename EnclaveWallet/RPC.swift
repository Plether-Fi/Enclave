import Foundation
import BigInt
import os

private let log = Logger(subsystem: "com.plether.EnclaveWallet", category: "RPC")

enum RPCError: Error {
    case invalidResponse
    case serverError(code: Int, message: String)
}

actor RPCClient {
    static let shared = RPCClient()

    private let session = URLSession.shared
    private var requestId = 0

    private func nextId() -> Int {
        requestId += 1
        return requestId
    }

    private func call(method: String, params: [Any], url: URL? = nil) async throws -> String {
        let id = nextId()
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
            "id": id
        ]

        var request = URLRequest(url: url ?? Config.activeNetwork.rpcURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RPCError.invalidResponse
        }
        if let error = json["error"] as? [String: Any] {
            throw RPCError.serverError(
                code: error["code"] as? Int ?? -1,
                message: error["message"] as? String ?? "Unknown"
            )
        }
        guard let result = json["result"] as? String else {
            throw RPCError.invalidResponse
        }
        return result
    }

    func getBalance(address: String) async throws -> Wei {
        let hex = try await call(method: "eth_getBalance", params: [address, "latest"])
        return Wei(hex: hex)
    }

    func getERC20Balance(token: String, owner: String) async throws -> Wei {
        let data = "0x70a08231" + owner.leftPadded(toLength: 64)
        let callObj: [String: String] = ["to": token, "data": data]
        let hex = try await call(method: "eth_call", params: [callObj, "latest"])
        return Wei(hex: hex)
    }

    func getTransactionCount(address: String) async throws -> UInt64 {
        let hex = try await call(method: "eth_getTransactionCount", params: [address, "latest"])
        return UInt64(hex.stripHexPrefix(), radix: 16) ?? 0
    }

    func getEntryPointNonce(sender: String) async throws -> UInt64 {
        let data = "0x35567e1a" + sender.leftPadded(toLength: 64) + String(repeating: "0", count: 64)
        let result = try await ethCall(to: Config.entryPointAddress, data: data)
        return UInt64(result.stripHexPrefix().prefix(16), radix: 16) ?? 0
    }

    func getChainId() async throws -> UInt64 {
        let hex = try await call(method: "eth_chainId", params: [])
        return UInt64(hex.stripHexPrefix(), radix: 16) ?? 0
    }

    func ethCall(to: String, data: String) async throws -> String {
        let callObj: [String: String] = ["to": to, "data": data]
        return try await call(method: "eth_call", params: [callObj, "latest"])
    }

    func getGasPrice() async throws -> UInt64 {
        let hex = try await call(method: "eth_gasPrice", params: [])
        return UInt64(hex.stripHexPrefix(), radix: 16) ?? 1_000_000_000
    }

    func getMaxPriorityFeePerGas() async throws -> UInt64 {
        let hex = try await call(method: "eth_maxPriorityFeePerGas", params: [])
        let fee = UInt64(hex.stripHexPrefix(), radix: 16) ?? 0
        return max(fee, 1_000_000)
    }

    func getCode(address: String) async throws -> String {
        try await call(method: "eth_getCode", params: [address, "latest"])
    }

    func getBlockNumber() async throws -> UInt64 {
        let hex = try await call(method: "eth_blockNumber", params: [])
        return UInt64(hex.stripHexPrefix(), radix: 16) ?? 0
    }

    func estimateGas(to: String, from: String? = nil, data: String? = nil, value: String? = nil) async throws -> UInt64 {
        var callObj: [String: String] = ["to": to]
        if let from { callObj["from"] = from }
        if let data { callObj["data"] = data }
        if let value { callObj["value"] = value }
        let hex = try await call(method: "eth_estimateGas", params: [callObj, "latest"])
        return UInt64(hex.stripHexPrefix(), radix: 16) ?? 0
    }

    func getFactoryAddress(pubKeyX: String, pubKeyY: String, salt: UInt64) async throws -> String {
        let selector = "e81b22ea"
        let x = pubKeyX.leftPadded(toLength: 64)
        let y = pubKeyY.leftPadded(toLength: 64)
        let s = String(salt, radix: 16).leftPadded(toLength: 64)
        let data = "0x" + selector + x + y + s

        let result = try await ethCall(to: Config.factoryAddress, data: data)
        let hex = result.stripHexPrefix()
        guard hex.count >= 40 else { throw RPCError.invalidResponse }
        return "0x" + String(hex.suffix(40))
    }
}

nonisolated struct Wei: Sendable {
    let value: BigUInt

    init(hex: String) {
        self.value = BigUInt(hex.stripHexPrefix(), radix: 16) ?? 0
    }

    init(bigUInt: BigUInt) {
        self.value = bigUInt
    }

    var isZero: Bool { value == 0 }

    func formatted(decimals: Int, precision: Int = 4) -> String {
        guard value > 0 else { return "0" }

        let divisor = BigUInt(10).power(decimals)
        let whole = value / divisor
        let remainder = value % divisor

        if remainder == 0 { return String(whole) }

        let remainderStr = String(remainder)
        let padded = String(repeating: "0", count: max(0, decimals - remainderStr.count)) + remainderStr
        let fractional = String(padded.prefix(precision))
        let trimmed = fractional.replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
        if trimmed.isEmpty { return String(whole) }
        return "\(whole).\(fractional)"
    }

    var ethFormatted: String { formatted(decimals: 18) }
    var usdcFormatted: String { formatted(decimals: 6, precision: 2) }
}

nonisolated extension String {
    func stripHexPrefix() -> String {
        hasPrefix("0x") ? String(dropFirst(2)) : self
    }

    func leftPadded(toLength length: Int) -> String {
        let s = self.stripHexPrefix()
        if s.count >= length { return s }
        return String(repeating: "0", count: length - s.count) + s
    }

    func hexToData() -> Data? {
        let hex = self.stripHexPrefix()
        let len = hex.count / 2
        var data = Data(capacity: len)
        var index = hex.startIndex
        for _ in 0..<len {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        return data
    }
}
