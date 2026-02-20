import Foundation
import BigInt

@main
struct CLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            printUsage()
            return
        }

        do {
            switch command {
            case "balance": try await balance()
            case "send": try await send(args: Array(args.dropFirst()))
            case "deploy": try await deploy()
            case "status": try await status()
            case "wallets": await wallets()
            case "new": try await newWallet()
            case "select": try await select(args: Array(args.dropFirst()))
            case "network": try await network(args: Array(args.dropFirst()))
            default:
                print("Unknown command: \(command)")
                printUsage()
            }
        } catch {
            print("Error: \(error)")
        }
    }

    static func printUsage() {
        print("""
        Usage: EnclaveCLI <command> [args]

        Commands:
          balance                          ETH + USDC balance of active wallet
          send <to> <amount> [eth|usdc]    Send ETH or USDC via UserOp
          deploy                           Deploy wallet via UserOp with initCode
          status                           Address, deployed?, nonce, network
          wallets                          List all wallets
          new                              Generate new software P256 key
          select <index>                   Switch active wallet
          network <name>                   Switch network (anvil, arbitrumSepolia, arbitrumOne)
        """)
    }

    // MARK: - Commands

    static func balance() async throws {
        let engine = CLIEngine.shared
        guard let wallet = await engine.currentWallet else { throw CLIError.noWallet }

        print("Wallet: \(wallet.address)")
        print("Network: \(Config.activeNetwork.displayName)")

        let eth = try await RPCClient.shared.getBalance(address: wallet.address)
        print("ETH:  \(eth.ethFormatted)")

        let usdc = try await RPCClient.shared.getERC20Balance(
            token: Config.activeNetwork.usdcAddress,
            owner: wallet.address
        )
        print("USDC: \(usdc.usdcFormatted)")
    }

    static func send(args: [String]) async throws {
        guard args.count >= 2 else {
            print("Usage: send <to> <amount> [eth|usdc]")
            return
        }

        let to = args[0]
        let amountStr = args[1]
        let tokenStr = args.count > 2 ? args[2].lowercased() : "eth"

        guard to.hasPrefix("0x"), to.count == 42 else { throw CLIError.invalidAddress }

        let engine = CLIEngine.shared
        guard let wallet = await engine.currentWallet else { throw CLIError.noWallet }

        print("Building UserOp...")
        var op = UserOperation(sender: wallet.address)

        let nonce = try await RPCClient.shared.getEntryPointNonce(sender: wallet.address)
        op.nonce = "0x" + String(nonce, radix: 16)

        let deployed = try await engine.isDeployed(address: wallet.address)
        if !deployed {
            op.initCode = UserOperation.buildInitCode(
                pubKeyX: wallet.pubKeyX, pubKeyY: wallet.pubKeyY, salt: UInt64(wallet.index)
            )
            op.verificationGasLimit = 5_000_000
        }

        switch tokenStr {
        case "eth":
            let wei = parseETHToWei(amountStr)
            guard wei > 0 else { throw CLIError.invalidAmount }
            op.callData = UserOperation.buildETHTransfer(to: to, weiAmount: wei)
            print("Sending \(amountStr) ETH to \(to)")
        case "usdc":
            let base = parseUSDCToBase(amountStr)
            guard base > 0 else { throw CLIError.invalidAmount }
            op.callData = UserOperation.buildERC20Transfer(
                token: Config.activeNetwork.usdcAddress, to: to, amount: base
            )
            print("Sending \(amountStr) USDC to \(to)")
        default:
            print("Unknown token: \(tokenStr). Use 'eth' or 'usdc'.")
            return
        }

        try await estimateSignSubmit(&op, engine: engine, wallet: wallet, deployed: deployed)
    }

    static func deploy() async throws {
        let engine = CLIEngine.shared
        guard let wallet = await engine.currentWallet else { throw CLIError.noWallet }

        let deployed = try await engine.isDeployed(address: wallet.address)
        if deployed {
            print("Wallet \(wallet.address) is already deployed.")
            return
        }

        print("Deploying wallet \(wallet.address)...")
        var op = UserOperation(sender: wallet.address)

        let nonce = try await RPCClient.shared.getEntryPointNonce(sender: wallet.address)
        op.nonce = "0x" + String(nonce, radix: 16)

        op.initCode = UserOperation.buildInitCode(
            pubKeyX: wallet.pubKeyX, pubKeyY: wallet.pubKeyY, salt: UInt64(wallet.index)
        )
        op.verificationGasLimit = 5_000_000
        op.callData = Data()

        try await estimateSignSubmit(&op, engine: engine, wallet: wallet, deployed: false)
    }

    static func status() async throws {
        let engine = CLIEngine.shared
        guard let wallet = await engine.currentWallet else {
            print("No wallet. Run 'new' to create one.")
            return
        }

        let deployed = try await engine.isDeployed(address: wallet.address)
        let nonce = try await RPCClient.shared.getEntryPointNonce(sender: wallet.address)

        print("Address:  \(wallet.address)")
        print("Index:    \(wallet.index)")
        print("Deployed: \(deployed ? "yes" : "no")")
        print("Nonce:    \(nonce)")
        print("Network:  \(Config.activeNetwork.displayName)")
        print("Chain ID: \(Config.activeNetwork.chainId)")
    }

    static func wallets() async {
        let engine = CLIEngine.shared
        let all = await engine.wallets
        let selected = await engine.config.selectedIndex

        if all.isEmpty {
            print("No wallets. Run 'new' to create one.")
            return
        }

        for w in all {
            let marker = w.index == selected ? " *" : ""
            print("[\(w.index)] \(w.address)\(marker)")
        }
    }

    static func newWallet() async throws {
        let wallet = try await CLIEngine.shared.generateKey()
        print("Created wallet [\(wallet.index)]: \(wallet.address)")
    }

    static func select(args: [String]) async throws {
        guard let indexStr = args.first, let index = Int(indexStr) else {
            print("Usage: select <index>")
            return
        }
        let ok = await CLIEngine.shared.selectWallet(at: index)
        if ok {
            let wallet = await CLIEngine.shared.currentWallet!
            print("Selected wallet [\(wallet.index)]: \(wallet.address)")
        } else {
            print("No wallet at index \(index)")
        }
    }

    static func network(args: [String]) async throws {
        guard let name = args.first else {
            print("Current: \(Config.activeNetwork.displayName)")
            print("Available: \(Network.allCases.map(\.rawValue).joined(separator: ", "))")
            return
        }
        guard let net = Network(rawValue: name) else {
            print("Unknown network: \(name)")
            print("Available: \(Network.allCases.map(\.rawValue).joined(separator: ", "))")
            return
        }
        await CLIEngine.shared.setNetwork(net)
        print("Switched to \(net.displayName)")
    }

    // MARK: - Shared Send Flow

    private static func estimateSignSubmit(
        _ op: inout UserOperation, engine: CLIEngine, wallet: CLIWallet, deployed: Bool
    ) async throws {
        let (gasPrice, priorityFee) = try await (
            RPCClient.shared.getGasPrice(),
            RPCClient.shared.getMaxPriorityFeePerGas()
        )
        op.maxFeePerGas = gasPrice * 12 / 10
        op.maxPriorityFeePerGas = priorityFee
        op.signature = Data(repeating: 0, count: 64)

        print("Estimating gas...")
        let gasEstimate = try await BundlerClient.shared.estimateGas(
            op.toDict(), entryPoint: Config.entryPointAddress
        )
        op.preVerificationGas = max(op.preVerificationGas, UInt64(gasEstimate.preVerificationGas.stripHexPrefix(), radix: 16) ?? 0)
        op.verificationGasLimit = max(op.verificationGasLimit, UInt64(gasEstimate.verificationGasLimit.stripHexPrefix(), radix: 16) ?? 0)
        op.callGasLimit = max(op.callGasLimit, UInt64(gasEstimate.callGasLimit.stripHexPrefix(), radix: 16) ?? 0)

        let totalGas = op.preVerificationGas + op.verificationGasLimit + op.callGasLimit
        let gasCostWei = BigUInt(totalGas) * BigUInt(op.maxFeePerGas)
        print("Estimated gas: \(Wei(bigUInt: gasCostWei).ethFormatted) ETH")

        if !op.callData.isEmpty {
            let actions = CalldataDecoder.decode(callData: op.callData)
            for action in actions { print("  \(action.description)") }
        }

        print("Signing...")
        let chainId = Config.activeNetwork.chainId
        let opHash = op.computeHash(entryPoint: Config.entryPointAddress, chainId: chainId)
        op.signature = try await engine.signHash(opHash)

        print("Submitting to bundler...")
        let userOpHash = try await BundlerClient.shared.sendUserOperation(
            op.toDict(), entryPoint: Config.entryPointAddress
        )
        print("UserOp hash: \(userOpHash)")

        print("Waiting for receipt...")
        let receipt = try await BundlerClient.shared.waitForReceipt(hash: userOpHash)
        let txHash = receipt.receipt?.transactionHash ?? userOpHash

        if receipt.success {
            print("Confirmed: \(txHash)")
        } else {
            print("Reverted: \(txHash)")
        }
    }

    // MARK: - Amount Parsing

    private static func parseETHToWei(_ str: String) -> BigUInt {
        guard let dotIndex = str.firstIndex(of: ".") else {
            return (BigUInt(str) ?? 0) * BigUInt(10).power(18)
        }
        let whole = String(str[str.startIndex..<dotIndex])
        var fraction = String(str[str.index(after: dotIndex)...])
        if fraction.count > 18 { fraction = String(fraction.prefix(18)) }
        fraction = fraction + String(repeating: "0", count: 18 - fraction.count)
        return (BigUInt(whole) ?? 0) * BigUInt(10).power(18) + (BigUInt(fraction) ?? 0)
    }

    private static func parseUSDCToBase(_ str: String) -> BigUInt {
        guard let dotIndex = str.firstIndex(of: ".") else {
            return (BigUInt(str) ?? 0) * BigUInt(10).power(6)
        }
        let whole = String(str[str.startIndex..<dotIndex])
        var fraction = String(str[str.index(after: dotIndex)...])
        if fraction.count > 6 { fraction = String(fraction.prefix(6)) }
        fraction = fraction + String(repeating: "0", count: 6 - fraction.count)
        return (BigUInt(whole) ?? 0) * BigUInt(10).power(6) + (BigUInt(fraction) ?? 0)
    }
}
