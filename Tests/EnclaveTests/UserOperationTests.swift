import Testing
import Foundation
import BigInt
@testable import EnclaveCLI

@Suite struct UserOperationTests {
    @Test func toDictIncludesAllFields() {
        var op = UserOperation(sender: "0xaaaa")
        op.nonce = "0x1"
        op.callGasLimit = 100
        op.verificationGasLimit = 200
        op.preVerificationGas = 50
        op.maxFeePerGas = 1000
        op.maxPriorityFeePerGas = 500
        op.signature = Data([0x01, 0x02])

        let dict = op.toDict()
        #expect(dict["sender"] == "0xaaaa")
        #expect(dict["nonce"] == "0x1")
        #expect(dict["callGasLimit"] == "0x64")
        #expect(dict["verificationGasLimit"] == "0xc8")
        #expect(dict["preVerificationGas"] == "0x32")
        #expect(dict["maxFeePerGas"] == "0x3e8")
        #expect(dict["maxPriorityFeePerGas"] == "0x1f4")
        #expect(dict["signature"] == "0x0102")
    }

    @Test func toDictWithInitCode() {
        var op = UserOperation(sender: "0xaaaa")
        let factory = Data(repeating: 0xab, count: 20)
        let factoryData = Data([0x01, 0x02, 0x03])
        op.initCode = factory + factoryData

        let dict = op.toDict()
        #expect(dict["factory"] == "0x" + String(repeating: "ab", count: 20))
        #expect(dict["factoryData"] == "0x010203")
    }

    @Test func toDictWithoutInitCode() {
        let op = UserOperation(sender: "0xaaaa")
        let dict = op.toDict()
        #expect(dict["factory"] == nil)
        #expect(dict["factoryData"] == nil)
    }

    @Test func buildETHTransferCallData() {
        let callData = UserOperation.buildETHTransfer(
            to: "0x000000000000000000000000000000000000dead",
            weiAmount: BigUInt(1000)
        )
        #expect(callData.count > 4)
        let selector = callData.prefix(4).map { String(format: "%02x", $0) }.joined()
        #expect(selector == "b61d27f6")
    }

    @Test func buildERC20TransferCallData() {
        let callData = UserOperation.buildERC20Transfer(
            token: "0x000000000000000000000000000000000000aaaa",
            to: "0x000000000000000000000000000000000000bbbb",
            amount: BigUInt(500_000)
        )
        let selector = callData.prefix(4).map { String(format: "%02x", $0) }.joined()
        #expect(selector == "b61d27f6")
        #expect(callData.count > 100)
    }

    @Test func buildBatchCallData() {
        let calls: [(to: String, value: BigUInt, data: Data)] = [
            ("0x000000000000000000000000000000000000aaaa", BigUInt(100), Data()),
            ("0x000000000000000000000000000000000000bbbb", BigUInt(200), Data()),
        ]
        let callData = UserOperation.buildBatchCallData(calls: calls)
        let selector = callData.prefix(4).map { String(format: "%02x", $0) }.joined()
        #expect(selector == "34fcd5be")
    }

    @Test func buildInitCode() {
        let initCode = UserOperation.buildInitCode(
            pubKeyX: "0x56c99709fa9d5c65ec12b332a70e25e248593b8de6b188fe054a111a026c6d01",
            pubKeyY: "0x745af3d8cfa403712cb3750dacb7c4ca5d37922500ce61b5fd842e862b9f3a17",
            salt: 5
        )
        let factoryHex = initCode.prefix(20).map { String(format: "%02x", $0) }.joined()
        #expect(factoryHex == Config.factoryAddress.stripHexPrefix().lowercased())

        let selectorHex = initCode[20..<24].map { String(format: "%02x", $0) }.joined()
        #expect(selectorHex == "4c1ed7f5")
    }

    // MARK: - Golden Vector: computeHash must match Solidity EntryPoint

    @Test func computeHashGoldenVector() {
        var op = UserOperation(sender: "0xB24687C2c3D8BdAaF6A2A44eEDdB905018B5932E")
        op.nonce = "0x0"
        op.initCode = UserOperation.buildInitCode(
            pubKeyX: "0x56c99709fa9d5c65ec12b332a70e25e248593b8de6b188fe054a111a026c6d01",
            pubKeyY: "0x745af3d8cfa403712cb3750dacb7c4ca5d37922500ce61b5fd842e862b9f3a17",
            salt: 5
        )
        op.callData = "b61d27f6000000000000000000000000B24687C2c3D8BdAaF6A2A44eEDdB905018B5932E00000000000000000000000000000000000000000000000000005af3107a400000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000000".hexToData()!
        op.verificationGasLimit = 2_000_000
        op.callGasLimit = 200_000
        op.preVerificationGas = 100_000
        op.maxPriorityFeePerGas = 1_000_000
        op.maxFeePerGas = 24_350_400

        let hash = op.computeHash(
            entryPoint: "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
            chainId: 421614
        )
        let hashHex = "0x" + hash.map { String(format: "%02x", $0) }.joined()
        #expect(hashHex == "0xb2f925451b7f6574f278d51f865709b7ab0db921816aa20f24cf555eda8b8051")
    }
}
