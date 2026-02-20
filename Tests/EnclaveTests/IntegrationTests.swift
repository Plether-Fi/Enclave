import Testing
import Foundation
@testable import EnclaveCLI

@Suite(.enabled(if: ProcessInfo.processInfo.environment["ANVIL_TESTS"] != nil), .serialized)
struct IntegrationTests {
    @Test func rpcGetBlockNumber() async throws {
        Config.activeNetwork = .anvil
        let blockNumber = try await RPCClient.shared.getBlockNumber()
        #expect(blockNumber > 0)
    }

    @Test func rpcGetChainId() async throws {
        Config.activeNetwork = .anvil
        let chainId = try await RPCClient.shared.getChainId()
        #expect(chainId > 0)
    }

    @Test func rpcGetBalance() async throws {
        Config.activeNetwork = .anvil
        let balance = try await RPCClient.shared.getBalance(
            address: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
        )
        #expect(!balance.isZero)
    }
}
