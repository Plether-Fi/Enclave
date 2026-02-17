import Foundation
import CryptoSwift
import BigInt
import os

private let log = Logger(subsystem: "com.plether.EnclaveWallet", category: "UserOp")

struct UserOperation {
    var sender: String
    var nonce: String = "0x0"
    var initCode: Data = Data()
    var callData: Data = Data()
    var verificationGasLimit: UInt64 = 500_000
    var callGasLimit: UInt64 = 200_000
    var preVerificationGas: UInt64 = 100_000
    var maxFeePerGas: UInt64 = 1_000_000_000
    var maxPriorityFeePerGas: UInt64 = 1_000_000_000
    var paymasterAndData: Data = Data()
    var signature: Data = Data()

    var accountGasLimits: Data {
        packUint128Pair(verificationGasLimit, callGasLimit)
    }

    var gasFees: Data {
        packUint128Pair(maxPriorityFeePerGas, maxFeePerGas)
    }

    func toDict() -> [String: String] {
        [
            "sender": sender,
            "nonce": nonce,
            "initCode": "0x" + initCode.hex,
            "callData": "0x" + callData.hex,
            "accountGasLimits": "0x" + accountGasLimits.hex,
            "preVerificationGas": "0x" + String(preVerificationGas, radix: 16),
            "gasFees": "0x" + gasFees.hex,
            "paymasterAndData": "0x" + paymasterAndData.hex,
            "signature": "0x" + signature.hex,
        ]
    }

    // MARK: - UserOp Hash (for signing)

    func computeHash(entryPoint: String, chainId: UInt64) -> Data {
        let typehash = Array("PackedUserOperation(address sender,uint256 nonce,bytes initCode,bytes callData,bytes32 accountGasLimits,uint256 preVerificationGas,bytes32 gasFees,bytes paymasterAndData)".utf8).sha3(.keccak256)

        var encoded = Data()
        encoded.append(contentsOf: typehash)
        encoded.append(abiEncodeAddress(sender))
        encoded.append(abiEncodeUint256(nonce))
        encoded.append(abiEncodeBytes32(Data(initCode).sha3(.keccak256)))
        encoded.append(abiEncodeBytes32(Data(callData).sha3(.keccak256)))
        encoded.append(abiEncodeBytes32(Array(accountGasLimits)))
        encoded.append(abiEncodeUint256("0x" + String(preVerificationGas, radix: 16)))
        encoded.append(abiEncodeBytes32(Array(gasFees)))
        encoded.append(abiEncodeBytes32(Data(paymasterAndData).sha3(.keccak256)))

        let innerHash = Data(Array(encoded).sha3(.keccak256))

        var outer = Data()
        outer.append(innerHash)
        outer.append(abiEncodeAddress(entryPoint))
        outer.append(abiEncodeUint256("0x" + String(chainId, radix: 16)))

        return Data(Array(outer).sha3(.keccak256))
    }

    // MARK: - initCode Builder

    static func buildInitCode(pubKeyX: String, pubKeyY: String, salt: UInt64) -> Data {
        let factoryBytes = Config.factoryAddress.stripHexPrefix().hexToData() ?? Data()
        let selector = "4c1ed7f5".hexToData() ?? Data()
        let x = Data(hex: pubKeyX.leftPadded(toLength: 64))
        let y = Data(hex: pubKeyY.leftPadded(toLength: 64))
        let s = Data(hex: String(salt, radix: 16).leftPadded(toLength: 64))

        return factoryBytes + selector + x + y + s
    }

    // MARK: - callData Builders

    static func buildETHTransfer(to: String, weiAmount: BigUInt) -> Data {
        let selector = "b61d27f6".hexToData() ?? Data()
        let dest = abiEncodeAddress(to)
        let value = abiEncodeUint256BigInt(weiAmount)
        let dataOffset = abiEncodeUint256("0x60")
        let dataLen = abiEncodeUint256("0x0")

        return Data(selector) + dest + value + dataOffset + dataLen
    }

    static func buildExecuteCallData(to: String, value: BigUInt, data: Data) -> Data {
        let executeSelector = "b61d27f6".hexToData() ?? Data()
        let dest = abiEncodeAddress(to)
        let ethValue = abiEncodeUint256BigInt(value)
        let dataOffset = abiEncodeUint256("0x60")
        let dataLen = abiEncodeUint256("0x" + String(data.count, radix: 16))
        let paddedData = data + Data(repeating: 0, count: (32 - data.count % 32) % 32)

        return Data(executeSelector) + dest + ethValue + dataOffset + dataLen + paddedData
    }

    static func buildBatchCallData(calls: [(to: String, value: BigUInt, data: Data)]) -> Data {
        let batchSelector = "34fcd5be".hexToData() ?? Data()

        var callsEncoded = Data()
        var offsets: [Int] = []
        var dynamicParts = Data()

        for call in calls {
            offsets.append(dynamicParts.count)

            var callEncoded = Data()
            callEncoded.append(abiEncodeAddress(call.to))
            callEncoded.append(abiEncodeUint256BigInt(call.value))
            callEncoded.append(abiEncodeUint256("0x60"))
            callEncoded.append(abiEncodeUint256("0x" + String(call.data.count, radix: 16)))
            callEncoded.append(call.data)
            callEncoded.append(Data(repeating: 0, count: (32 - call.data.count % 32) % 32))

            dynamicParts.append(callEncoded)
        }

        let offsetBase = calls.count * 32
        callsEncoded.append(abiEncodeUint256("0x20"))
        callsEncoded.append(abiEncodeUint256("0x" + String(calls.count, radix: 16)))
        for offset in offsets {
            callsEncoded.append(abiEncodeUint256("0x" + String(offsetBase + offset, radix: 16)))
        }
        callsEncoded.append(dynamicParts)

        return Data(batchSelector) + callsEncoded
    }

    static func buildERC20Transfer(token: String, to: String, amount: BigUInt) -> Data {
        let transferSelector = "a9059cbb".hexToData() ?? Data()
        let recipient = abiEncodeAddress(to)
        let value = abiEncodeUint256BigInt(amount)
        let innerCalldata = Data(transferSelector) + recipient + value

        let executeSelector = "b61d27f6".hexToData() ?? Data()
        let dest = abiEncodeAddress(token)
        let ethValue = abiEncodeUint256("0x0")
        let dataOffset = abiEncodeUint256("0x60")
        let dataLen = abiEncodeUint256("0x" + String(innerCalldata.count, radix: 16))

        let paddedCalldata = innerCalldata + Data(repeating: 0, count: (32 - innerCalldata.count % 32) % 32)

        return Data(executeSelector) + dest + ethValue + dataOffset + dataLen + paddedCalldata
    }
}

// MARK: - ABI Encoding Helpers

private func packUint128Pair(_ high: UInt64, _ low: UInt64) -> Data {
    var data = Data(count: 32)
    let highBig = BigUInt(high)
    let lowBig = BigUInt(low)
    let highBytes = highBig.serialize()
    let lowBytes = lowBig.serialize()
    let highStart = 16 - highBytes.count
    let lowStart = 32 - lowBytes.count
    for (i, b) in highBytes.enumerated() { data[highStart + i] = b }
    for (i, b) in lowBytes.enumerated() { data[lowStart + i] = b }
    return data
}

private func abiEncodeAddress(_ address: String) -> Data {
    let stripped = address.stripHexPrefix()
    let padded = stripped.leftPadded(toLength: 64)
    return Data(hex: padded)
}

private func abiEncodeUint256(_ hex: String) -> Data {
    let padded = hex.leftPadded(toLength: 64)
    return Data(hex: padded)
}

private func abiEncodeUint256BigInt(_ value: BigUInt) -> Data {
    let bytes = value.serialize()
    var data = Data(repeating: 0, count: 32)
    let start = 32 - bytes.count
    for (i, b) in bytes.enumerated() { data[start + i] = b }
    return data
}

private func abiEncodeBytes32(_ bytes: [UInt8]) -> Data {
    var data = Data(count: 32)
    let start = max(0, 32 - bytes.count)
    for (i, b) in bytes.prefix(32).enumerated() { data[start + i] = b }
    return data
}

// MARK: - Data hex helpers

private extension Data {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init(hex: String) {
        let h = hex.stripHexPrefix()
        let len = h.count / 2
        var data = Data(capacity: len)
        var index = h.startIndex
        for _ in 0..<len {
            let nextIndex = h.index(index, offsetBy: 2)
            if let byte = UInt8(h[index..<nextIndex], radix: 16) {
                data.append(byte)
            }
            index = nextIndex
        }
        self = data
    }
}

private extension [UInt8] {
    func sha3(_ variant: CryptoSwift.SHA3.Variant) -> [UInt8] {
        Digest.sha3(self, variant: variant)
    }
}

private extension Data {
    func sha3(_ variant: CryptoSwift.SHA3.Variant) -> [UInt8] {
        Array(self).sha3(variant)
    }
}
