import Foundation
import BigInt

enum DecodedAction: Sendable {
    case ethTransfer(to: String, amount: BigUInt)
    case erc20Transfer(token: String, to: String, amount: BigUInt)
    case erc20Approve(token: String, spender: String, amount: BigUInt)
    case contractCall(to: String, value: BigUInt, selector: String, data: Data)
    case unknown(selector: String, data: Data)

    var description: String {
        switch self {
        case .ethTransfer(let to, let amount):
            let formatted = Wei(bigUInt: amount).ethFormatted
            return "Send \(formatted) ETH to \(to.shortAddress)"
        case .erc20Transfer(let token, let to, let amount):
            let (symbol, decimals) = tokenInfo(token)
            let formatted = Wei(bigUInt: amount).formatted(decimals: decimals, precision: 4)
            return "Send \(formatted) \(symbol) to \(to.shortAddress)"
        case .erc20Approve(let token, let spender, let amount):
            let (symbol, _) = tokenInfo(token)
            if amount == BigUInt(2).power(256) - 1 {
                return "Approve unlimited \(symbol) to \(spender.shortAddress)"
            }
            let (_, decimals) = tokenInfo(token)
            let formatted = Wei(bigUInt: amount).formatted(decimals: decimals, precision: 4)
            return "Approve \(formatted) \(symbol) to \(spender.shortAddress)"
        case .contractCall(let to, let value, let selector, _):
            if value > 0 {
                return "Call \(selector) on \(to.shortAddress) with \(Wei(bigUInt: value).ethFormatted) ETH"
            }
            return "Call \(selector) on \(to.shortAddress)"
        case .unknown(let selector, _):
            return "Unknown call (\(selector))"
        }
    }
}

enum CalldataDecoder {
    private static let transferSelector = "a9059cbb"
    private static let approveSelector = "095ea7b3"
    private static let transferFromSelector = "23b872dd"
    private static let executeSelector = "b61d27f6"
    private static let executeBatchSelector = "34fcd5be"

    static func decode(callData: Data) -> [DecodedAction] {
        guard callData.count >= 4 else { return [.unknown(selector: "0x", data: callData)] }

        let selector = callData.prefix(4).map { String(format: "%02x", $0) }.joined()
        let params = Data(callData.dropFirst(4))

        switch selector {
        case executeSelector:
            return decodeExecute(params)
        case executeBatchSelector:
            return decodeExecuteBatch(params)
        default:
            return [.unknown(selector: "0x" + selector, data: callData)]
        }
    }

    private static func decodeExecute(_ params: Data) -> [DecodedAction] {
        guard params.count >= 96 else { return [.unknown(selector: "0xb61d27f6", data: params)] }

        let to = extractAddress(from: params, offset: 0)
        let value = extractUint256(from: params, offset: 32)
        let innerData = extractDynamicBytes(from: params, offsetSlot: 64)

        if innerData.isEmpty && value > 0 {
            return [.ethTransfer(to: to, amount: value)]
        }

        if innerData.count >= 4 {
            let innerSelector = innerData.prefix(4).map { String(format: "%02x", $0) }.joined()
            let innerParams = Data(innerData.dropFirst(4))

            switch innerSelector {
            case transferSelector:
                if let action = decodeTransfer(token: to, params: innerParams) { return [action] }
            case approveSelector:
                if let action = decodeApprove(token: to, params: innerParams) { return [action] }
            case transferFromSelector:
                if let action = decodeTransferFrom(token: to, params: innerParams) { return [action] }
            default:
                break
            }
        }

        return [.contractCall(to: to, value: value, selector: selectorOf(innerData), data: innerData)]
    }

    private static func decodeExecuteBatch(_ params: Data) -> [DecodedAction] {
        guard params.count >= 32 else { return [.unknown(selector: "0x34fcd5be", data: params)] }

        let offsetRaw = extractUint256(from: params, offset: 0)
        let offset = Int(offsetRaw)
        guard offset + 32 <= params.count else { return [.unknown(selector: "0x34fcd5be", data: params)] }

        let count = Int(extractUint256(from: params, offset: offset))
        var actions: [DecodedAction] = []

        for i in 0..<count {
            let callOffsetSlot = offset + 32 + i * 32
            guard callOffsetSlot + 32 <= params.count else { break }
            let callOffset = offset + 32 + Int(extractUint256(from: params, offset: callOffsetSlot))
            guard callOffset + 96 <= params.count else { break }

            let to = extractAddress(from: params, offset: callOffset)
            let value = extractUint256(from: params, offset: callOffset + 32)
            let innerData = extractDynamicBytes(from: params, offsetSlot: callOffset + 64, base: callOffset)

            if innerData.isEmpty && value > 0 {
                actions.append(.ethTransfer(to: to, amount: value))
                continue
            }

            if innerData.count >= 4 {
                let innerSelector = innerData.prefix(4).map { String(format: "%02x", $0) }.joined()
                let innerParams = Data(innerData.dropFirst(4))
                switch innerSelector {
                case transferSelector:
                    if let a = decodeTransfer(token: to, params: innerParams) { actions.append(a); continue }
                case approveSelector:
                    if let a = decodeApprove(token: to, params: innerParams) { actions.append(a); continue }
                default:
                    break
                }
            }

            actions.append(.contractCall(to: to, value: value, selector: selectorOf(innerData), data: innerData))
        }

        return actions.isEmpty ? [.unknown(selector: "0x34fcd5be", data: params)] : actions
    }

    private static func decodeTransfer(token: String, params: Data) -> DecodedAction? {
        guard params.count >= 64 else { return nil }
        let to = extractAddress(from: params, offset: 0)
        let amount = extractUint256(from: params, offset: 32)
        return .erc20Transfer(token: token, to: to, amount: amount)
    }

    private static func decodeApprove(token: String, params: Data) -> DecodedAction? {
        guard params.count >= 64 else { return nil }
        let spender = extractAddress(from: params, offset: 0)
        let amount = extractUint256(from: params, offset: 32)
        return .erc20Approve(token: token, spender: spender, amount: amount)
    }

    private static func decodeTransferFrom(token: String, params: Data) -> DecodedAction? {
        guard params.count >= 96 else { return nil }
        let to = extractAddress(from: params, offset: 32)
        let amount = extractUint256(from: params, offset: 64)
        return .erc20Transfer(token: token, to: to, amount: amount)
    }

    // MARK: - ABI Helpers

    private static func extractAddress(from data: Data, offset: Int) -> String {
        guard offset + 32 <= data.count else { return "0x" + String(repeating: "0", count: 40) }
        let slice = data[data.startIndex + offset + 12 ..< data.startIndex + offset + 32]
        return "0x" + slice.map { String(format: "%02x", $0) }.joined()
    }

    private static func extractUint256(from data: Data, offset: Int) -> BigUInt {
        guard offset + 32 <= data.count else { return 0 }
        let slice = data[data.startIndex + offset ..< data.startIndex + offset + 32]
        return BigUInt(Data(slice))
    }

    private static func extractDynamicBytes(from data: Data, offsetSlot: Int, base: Int = 0) -> Data {
        guard offsetSlot + 32 <= data.count else { return Data() }
        let dataOffset = base + Int(extractUint256(from: data, offset: offsetSlot))
        guard dataOffset + 32 <= data.count else { return Data() }
        let length = Int(extractUint256(from: data, offset: dataOffset))
        let start = dataOffset + 32
        guard start + length <= data.count else { return Data() }
        return Data(data[data.startIndex + start ..< data.startIndex + start + length])
    }

    private static func selectorOf(_ data: Data) -> String {
        guard data.count >= 4 else { return "0x" }
        return "0x" + data.prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}

private func tokenInfo(_ address: String) -> (symbol: String, decimals: Int) {
    let lower = address.lowercased()
    let usdcLower = Config.activeNetwork.usdcAddress.lowercased()
    if lower == usdcLower { return ("USDC", 6) }
    return ("TOKEN", 18)
}

private extension String {
    var shortAddress: String {
        guard count >= 10 else { return self }
        return String(prefix(6)) + "..." + String(suffix(4))
    }
}
