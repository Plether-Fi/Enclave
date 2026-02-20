import Testing
import Foundation
import BigInt
@testable import EnclaveCLI

private let anvilFunder = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

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
        let balance = try await RPCClient.shared.getBalance(address: anvilFunder)
        #expect(!balance.isZero)
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["BUNDLER_TESTS"] != nil), .serialized)
struct BundlerIntegrationTests {

    @Test func deployAndSendETH() async throws {
        Config.activeNetwork = .anvil
        let engine = CLIEngine.shared
        let wallet = try await engine.generateKey()

        let fundWei = "0x" + String(BigUInt(10).power(18), radix: 16)
        _ = try await RPCClient.shared.sendTransaction(
            from: anvilFunder, to: wallet.address, value: fundWei
        )

        let (gasPrice, priorityFee) = try await (
            RPCClient.shared.getGasPrice(),
            RPCClient.shared.getMaxPriorityFeePerGas()
        )

        let alreadyDeployed = try await engine.isDeployed(address: wallet.address)
        print("Wallet \(wallet.address) index=\(wallet.index) deployed=\(alreadyDeployed)")

        if !alreadyDeployed {
            var deployOp = UserOperation(sender: wallet.address)
            deployOp.nonce = "0x0"
            deployOp.initCode = UserOperation.buildInitCode(
                pubKeyX: wallet.pubKeyX, pubKeyY: wallet.pubKeyY, salt: UInt64(wallet.index)
            )
            deployOp.maxFeePerGas = gasPrice * 12 / 10
            deployOp.maxPriorityFeePerGas = priorityFee
            deployOp.signature = Data(repeating: 0, count: 64)

            var deployEstimateOp = deployOp
            deployEstimateOp.preVerificationGas = 0
            deployEstimateOp.verificationGasLimit = 0
            deployEstimateOp.callGasLimit = 0

            let deployEstimate = try await BundlerClient.shared.estimateGas(
                deployEstimateOp.toDict(), entryPoint: Config.entryPointAddress
            )
            deployOp.preVerificationGas = UInt64(deployEstimate.preVerificationGas.stripHexPrefix(), radix: 16) ?? 0
            let estDeployVerify = UInt64(deployEstimate.verificationGasLimit.stripHexPrefix(), radix: 16) ?? 0
            deployOp.verificationGasLimit = estDeployVerify * 3
            deployOp.callGasLimit = UInt64(deployEstimate.callGasLimit.stripHexPrefix(), radix: 16) ?? 0

            let deployHash = deployOp.computeHash(
                entryPoint: Config.entryPointAddress, chainId: Config.activeNetwork.chainId
            )
            deployOp.signature = try await engine.signHash(deployHash)

            let deployOpHash = try await BundlerClient.shared.sendUserOperation(
                deployOp.toDict(), entryPoint: Config.entryPointAddress
            )
            let deployReceipt = try await BundlerClient.shared.waitForReceipt(hash: deployOpHash)
            #expect(deployReceipt.success)
        }

        let deployed = try await engine.isDeployed(address: wallet.address)
        #expect(deployed)

        // Send ETH from the deployed wallet — this is the regression test.
        // The old bug inflated verificationGasLimit to 500K for deployed wallets,
        // causing bundlers to reject with "Verification gas limit efficiency too low".
        var sendOp = UserOperation(sender: wallet.address)
        let nonce = try await RPCClient.shared.getEntryPointNonce(sender: wallet.address)
        sendOp.nonce = "0x" + String(nonce, radix: 16)
        sendOp.callData = UserOperation.buildETHTransfer(
            to: anvilFunder, weiAmount: BigUInt(10).power(15)
        )
        sendOp.maxFeePerGas = gasPrice * 12 / 10
        sendOp.maxPriorityFeePerGas = priorityFee
        sendOp.signature = Data(repeating: 0, count: 64)

        var estimateOp = sendOp
        estimateOp.preVerificationGas = 0
        estimateOp.verificationGasLimit = 0
        estimateOp.callGasLimit = 0

        let sendEstimate = try await BundlerClient.shared.estimateGas(
            estimateOp.toDict(), entryPoint: Config.entryPointAddress
        )
        sendOp.preVerificationGas = UInt64(sendEstimate.preVerificationGas.stripHexPrefix(), radix: 16) ?? 0
        let rawSendVerify = UInt64(sendEstimate.verificationGasLimit.stripHexPrefix(), radix: 16) ?? 0
        sendOp.callGasLimit = UInt64(sendEstimate.callGasLimit.stripHexPrefix(), radix: 16) ?? 0

        print("Send estimate: preVer=\(sendOp.preVerificationGas) verify=\(rawSendVerify) call=\(sendOp.callGasLimit)")
        #expect(rawSendVerify < 500_000, "verificationGasLimit estimate should not be inflated for deployed wallets")

        // P256 Solidity fallback (no native precompile on Anvil) needs much more gas
        // than the estimate with a dummy zero signature suggests
        sendOp.verificationGasLimit = max(rawSendVerify * 3, 500_000)

        let sendHash = sendOp.computeHash(
            entryPoint: Config.entryPointAddress, chainId: Config.activeNetwork.chainId
        )
        sendOp.signature = try await engine.signHash(sendHash)

        let sendOpHash = try await BundlerClient.shared.sendUserOperation(
            sendOp.toDict(), entryPoint: Config.entryPointAddress
        )
        let sendReceipt = try await BundlerClient.shared.waitForReceipt(hash: sendOpHash)
        #expect(sendReceipt.success)
    }
}
