import Testing
import Foundation
import BigInt
@testable import EnclaveCLI

@Suite struct CalldataDecoderTests {
    @Test func decodeETHTransfer() {
        let to = "0x000000000000000000000000000000000000dead"
        let amount = BigUInt(10).power(18)
        let callData = UserOperation.buildETHTransfer(to: to, weiAmount: amount)

        let actions = CalldataDecoder.decode(callData: callData)
        #expect(actions.count == 1)
        guard case .ethTransfer(let decodedTo, let decodedAmount) = actions[0] else {
            Issue.record("Expected .ethTransfer")
            return
        }
        #expect(decodedTo == to)
        #expect(decodedAmount == amount)
    }

    @Test func decodeERC20Transfer() {
        let token = "0x000000000000000000000000000000000000aaaa"
        let to = "0x000000000000000000000000000000000000bbbb"
        let amount = BigUInt(500_000)
        let callData = UserOperation.buildERC20Transfer(token: token, to: to, amount: amount)

        let actions = CalldataDecoder.decode(callData: callData)
        #expect(actions.count == 1)
        guard case .erc20Transfer(let decodedToken, let decodedTo, let decodedAmount) = actions[0] else {
            Issue.record("Expected .erc20Transfer")
            return
        }
        #expect(decodedToken == token)
        #expect(decodedTo == to)
        #expect(decodedAmount == amount)
    }

    @Test func decodeBatchCallData() {
        let amt1 = BigUInt(2) * BigUInt(10).power(18)
        let amt2 = BigUInt(3) * BigUInt(10).power(18)
        let calls: [(to: String, value: BigUInt, data: Data)] = [
            ("0x000000000000000000000000000000000000aaaa", amt1, Data()),
            ("0x000000000000000000000000000000000000bbbb", amt2, Data()),
        ]
        let callData = UserOperation.buildBatchCallData(calls: calls)

        let actions = CalldataDecoder.decode(callData: callData)
        #expect(actions.count == 2)

        guard case .ethTransfer(let to1, let decoded1) = actions[0] else {
            Issue.record("Expected .ethTransfer for call 0")
            return
        }
        #expect(to1 == "0x000000000000000000000000000000000000aaaa")
        #expect(decoded1 == amt1)

        guard case .ethTransfer(let to2, let decoded2) = actions[1] else {
            Issue.record("Expected .ethTransfer for call 1")
            return
        }
        #expect(to2 == "0x000000000000000000000000000000000000bbbb")
        #expect(decoded2 == amt2)
    }

    @Test func decodeUnknownSelector() {
        let callData = Data([0x12, 0x34, 0x56, 0x78, 0x00])

        let actions = CalldataDecoder.decode(callData: callData)
        #expect(actions.count == 1)
        guard case .unknown(let selector, _) = actions[0] else {
            Issue.record("Expected .unknown")
            return
        }
        #expect(selector == "0x12345678")
    }

    @Test func decodeTooShort() {
        let callData = Data([0x01, 0x02])
        let actions = CalldataDecoder.decode(callData: callData)
        #expect(actions.count == 1)
        guard case .unknown = actions[0] else {
            Issue.record("Expected .unknown for short calldata")
            return
        }
    }

    @Test func decodeContractCall() {
        let innerData = Data([0xaa, 0xbb, 0xcc, 0xdd, 0xee])
        let to = "0x000000000000000000000000000000000000dead"
        let callData = UserOperation.buildExecuteCallData(to: to, value: BigUInt(0), data: innerData)

        let actions = CalldataDecoder.decode(callData: callData)
        #expect(actions.count == 1)
        guard case .contractCall(let decodedTo, let value, let selector, _) = actions[0] else {
            Issue.record("Expected .contractCall")
            return
        }
        #expect(decodedTo == to)
        #expect(value == BigUInt(0))
        #expect(selector == "0xaabbccdd")
    }
}
