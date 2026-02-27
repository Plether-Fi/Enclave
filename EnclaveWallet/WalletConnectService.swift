import Foundation
import Combine
import WalletConnectSign
import WalletConnectPairing
import WalletConnectNetworking
import CryptoSwift
import BigInt
import os

private let log = Logger(subsystem: "com.plether.EnclaveWallet", category: "WC")

struct EnclaveCryptoProvider: CryptoProvider {
    func recoverPubKey(signature: EthereumSignature, message: Data) throws -> Data {
        fatalError("recoverPubKey not needed for wallet-side WC")
    }

    func keccak256(_ data: Data) -> Data {
        Data(Digest.sha3(Array(data), variant: .keccak256))
    }
}

class WalletConnectService: ObservableObject {
    static let shared = WalletConnectService()

    @Published var sessions: [Session] = []
    @Published var pendingProposal: Session.Proposal?
    @Published var pendingRequest: Request?
    @Published var pendingRequestParams: [String: Any]?

    private var cancellables = Set<AnyCancellable>()

    private init() {}

    func configure() {
        Networking.configure(
            groupIdentifier: "",
            projectId: Secrets.walletConnectProjectId,
            socketFactory: NativeWebSocketFactory()
        )

        let metadata = AppMetadata(
            name: "Enclave Wallet",
            description: "Secure Enclave smart contract wallet",
            url: "https://enclave.plether.com",
            icons: [],
            redirect: try! AppMetadata.Redirect(native: "enclave://", universal: nil)
        )

        Pair.configure(metadata: metadata)
        Sign.configure(crypto: EnclaveCryptoProvider())

        subscribe()
        sessions = Sign.instance.getSessions()
        log.notice("WalletConnect configured, \(self.sessions.count, privacy: .public) existing session(s)")
    }

    private func subscribe() {
        Sign.instance.sessionProposalPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (proposal, _) in
                log.notice("Session proposal from \(proposal.proposer.name, privacy: .public)")
                self?.pendingProposal = proposal
            }
            .store(in: &cancellables)

        Sign.instance.sessionRequestPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (request, _) in
                log.notice("Session request: \(request.method, privacy: .public)")
                self?.handleRequest(request)
            }
            .store(in: &cancellables)

        Sign.instance.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.sessions = sessions
            }
            .store(in: &cancellables)

        Sign.instance.sessionDeletePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.sessions = Sign.instance.getSessions()
            }
            .store(in: &cancellables)
    }

    // MARK: - Pairing

    func pair(uriString: String) {
        Task {
            do {
                let uri = try WalletConnectURI(uriString: uriString)
                try await Pair.instance.pair(uri: uri)
                log.notice("Paired successfully")
            } catch {
                log.error("Pairing failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Proposal Approval / Rejection

    func approveProposal() {
        guard let proposal = pendingProposal,
              let wallet = EnclaveEngine.shared.currentWallet else { return }

        Task {
            do {
                log.notice("Approving proposal from \(proposal.proposer.name, privacy: .public)")
                let network = Config.activeNetwork
                let chain = Blockchain(network.caip2)!
                let account = Account(blockchain: chain, address: wallet.address)!

                let methods: Set<String> = [
                    "personal_sign", "eth_signTypedData_v4", "eth_sendTransaction",
                    "eth_accounts", "eth_chainId", "eth_getBalance", "eth_call",
                    "eth_blockNumber", "eth_estimateGas", "eth_gasPrice",
                    "eth_getCode", "eth_getTransactionCount", "eth_getTransactionReceipt",
                    "net_version"
                ]
                let events: Set<String> = ["chainChanged", "accountsChanged"]

                var accounts = [account]
                var chains = Set([chain])

                for (_, ns) in proposal.requiredNamespaces {
                    if let required = ns.chains {
                        for c in required {
                            chains.insert(c)
                            if let acct = Account(blockchain: c, address: wallet.address) {
                                accounts.append(acct)
                            }
                        }
                    }
                }

                let sessionNamespace = SessionNamespace(
                    chains: Array(chains),
                    accounts: accounts,
                    methods: methods,
                    events: events
                )

                _ = try await Sign.instance.approve(
                    proposalId: proposal.id,
                    namespaces: ["eip155": sessionNamespace],
                    sessionProperties: proposal.sessionProperties
                )

                await MainActor.run {
                    pendingProposal = nil
                    sessions = Sign.instance.getSessions()
                }
                log.notice("Session approved for \(proposal.proposer.name, privacy: .public)")
            } catch {
                log.error("Approve failed: \(error.localizedDescription, privacy: .public)")
                await MainActor.run { pendingProposal = nil }
            }
        }
    }

    func rejectProposal() {
        guard let proposal = pendingProposal else { return }
        Task {
            try? await Sign.instance.rejectSession(
                proposalId: proposal.id,
                reason: .userRejected
            )
            await MainActor.run { pendingProposal = nil }
        }
    }

    // MARK: - Request Handling

    private func handleRequest(_ request: Request) {
        switch request.method {
        case "personal_sign", "eth_signTypedData_v4":
            pendingRequest = request
        case "eth_sendTransaction":
            pendingRequest = request
        case "eth_chainId", "eth_accounts", "net_version",
             "eth_getBalance", "eth_call", "eth_blockNumber",
             "eth_estimateGas", "eth_gasPrice", "eth_getCode",
             "eth_getTransactionCount", "eth_getTransactionReceipt":
            handleReadOnlyRPC(request)
        default:
            respondError(request: request, code: 4200, message: "Unsupported method: \(request.method)")
        }
    }

    func approveSignRequest() {
        guard let request = pendingRequest else { return }

        Task {
            do {
                let params = try request.params.get([String].self)
                let signature: String

                switch request.method {
                case "personal_sign":
                    guard let messageHex = params.first,
                          let messageData = messageHex.stripHexPrefix().hexToData() else {
                        throw WCServiceError.invalidParams
                    }
                    let prefix = "\u{19}Ethereum Signed Message:\n\(messageData.count)"
                    var prefixed = Data(prefix.utf8)
                    prefixed.append(messageData)
                    let hash = Data(Digest.sha3(Array(prefixed), variant: .keccak256))
                    signature = try EnclaveEngine.shared.signEVMHash(payloadHash: hash)

                case "eth_signTypedData_v4":
                    guard params.count >= 2,
                          let jsonData = params[1].data(using: .utf8) else {
                        throw WCServiceError.invalidParams
                    }
                    let hash = Data(Digest.sha3(Array(jsonData), variant: .keccak256))
                    signature = try EnclaveEngine.shared.signEVMHash(payloadHash: hash)

                default:
                    throw WCServiceError.invalidParams
                }

                try await Sign.instance.respond(
                    topic: request.topic,
                    requestId: request.id,
                    response: .response(AnyCodable(signature))
                )

                await MainActor.run { pendingRequest = nil }
            } catch {
                log.error("Sign failed: \(error.localizedDescription, privacy: .public)")
                respondError(request: request, code: 4001, message: "User rejected signing")
                await MainActor.run { pendingRequest = nil }
            }
        }
    }

    func approveSendTransaction() {
        guard let request = pendingRequest,
              let wallet = EnclaveEngine.shared.currentWallet else { return }

        Task {
            do {
                let txDicts = try request.params.get([[String: String]].self)
                guard let txDict = txDicts.first else { throw WCServiceError.invalidParams }

                let to = txDict["to"] ?? ""
                let valueHex = txDict["value"] ?? "0x0"
                let dataHex = txDict["data"] ?? "0x"
                let weiValue = BigUInt(valueHex.stripHexPrefix(), radix: 16) ?? 0

                var op = UserOperation(sender: wallet.address)

                let nonce = try await RPCClient.shared.getEntryPointNonce(sender: wallet.address)
                op.nonce = "0x" + String(nonce, radix: 16)

                if !wallet.isDeployed {
                    op.initCode = UserOperation.buildInitCode(
                        pubKeyX: wallet.pubKeyX,
                        pubKeyY: wallet.pubKeyY,
                        salt: UInt64(wallet.index)
                    )
                    op.verificationGasLimit = 5_000_000
                }

                let innerCalldata = dataHex.stripHexPrefix().hexToData() ?? Data()
                op.callData = UserOperation.buildExecuteCallData(to: to, value: weiValue, data: innerCalldata)

                let (gasPrice, priorityFee) = try await (
                    RPCClient.shared.getGasPrice(),
                    RPCClient.shared.getMaxPriorityFeePerGas()
                )
                op.maxFeePerGas = gasPrice * 12 / 10
                op.maxPriorityFeePerGas = priorityFee
                op.signature = Data(repeating: 0, count: 64)

                let gasEstimate = try await BundlerClient.shared.estimateGas(
                    op.toDict(), entryPoint: Config.entryPointAddress
                )
                op.preVerificationGas = UInt64(gasEstimate.preVerificationGas.stripHexPrefix(), radix: 16) ?? op.preVerificationGas
                op.verificationGasLimit = UInt64(gasEstimate.verificationGasLimit.stripHexPrefix(), radix: 16) ?? op.verificationGasLimit
                op.callGasLimit = UInt64(gasEstimate.callGasLimit.stripHexPrefix(), radix: 16) ?? op.callGasLimit

                let chainId = Config.activeNetwork.chainId
                let opHash = op.computeHash(entryPoint: Config.entryPointAddress, chainId: chainId)
                let signature = try EnclaveEngine.shared.signEVMHashRaw(payloadHash: opHash)
                op.signature = signature

                let userOpHash = try await BundlerClient.shared.sendUserOperation(
                    op.toDict(), entryPoint: Config.entryPointAddress
                )

                let receipt = try await BundlerClient.shared.waitForReceipt(hash: userOpHash)
                let txHash = receipt.receipt?.transactionHash ?? userOpHash

                try await Sign.instance.respond(
                    topic: request.topic,
                    requestId: request.id,
                    response: .response(AnyCodable(txHash))
                )

                await MainActor.run { pendingRequest = nil }
                log.notice("Tx submitted: \(txHash, privacy: .public)")
            } catch {
                log.error("Send tx failed: \(error.localizedDescription, privacy: .public)")
                respondError(request: request, code: -32000, message: error.localizedDescription)
                await MainActor.run { pendingRequest = nil }
            }
        }
    }

    func rejectRequest() {
        guard let request = pendingRequest else { return }
        respondError(request: request, code: 4001, message: "User rejected")
        pendingRequest = nil
    }

    // MARK: - Read-only RPCs

    private func handleReadOnlyRPC(_ request: Request) {
        Task {
            do {
                let result: AnyCodable

                switch request.method {
                case "eth_chainId":
                    let chainId = Config.activeNetwork.chainId
                    result = AnyCodable("0x" + String(chainId, radix: 16))

                case "eth_accounts", "eth_requestAccounts":
                    let addr = EnclaveEngine.shared.currentWallet?.address ?? ""
                    result = AnyCodable([addr])

                case "net_version":
                    result = AnyCodable(String(Config.activeNetwork.chainId))

                case "eth_getBalance":
                    let params = try request.params.get([String].self)
                    guard let addr = params.first else { throw WCServiceError.invalidParams }
                    let balance = try await RPCClient.shared.getBalance(address: addr)
                    result = AnyCodable("0x" + String(balance.value, radix: 16))

                case "eth_blockNumber":
                    let block = try await RPCClient.shared.getBlockNumber()
                    result = AnyCodable("0x" + String(block, radix: 16))

                case "eth_call":
                    let params = try request.params.get([[String: String]].self)
                    guard let callObj = params.first,
                          let to = callObj["to"],
                          let data = callObj["data"] else { throw WCServiceError.invalidParams }
                    let callResult = try await RPCClient.shared.ethCall(to: to, data: data)
                    result = AnyCodable(callResult)

                case "eth_gasPrice":
                    let price = try await RPCClient.shared.getGasPrice()
                    result = AnyCodable("0x" + String(price, radix: 16))

                case "eth_getCode":
                    let params = try request.params.get([String].self)
                    guard let addr = params.first else { throw WCServiceError.invalidParams }
                    let code = try await RPCClient.shared.getCode(address: addr)
                    result = AnyCodable(code)

                case "eth_getTransactionCount":
                    let params = try request.params.get([String].self)
                    guard let addr = params.first else { throw WCServiceError.invalidParams }
                    let count = try await RPCClient.shared.getTransactionCount(address: addr)
                    result = AnyCodable("0x" + String(count, radix: 16))

                case "eth_estimateGas":
                    let params = try request.params.get([[String: String]].self)
                    guard let callObj = params.first,
                          let to = callObj["to"] else { throw WCServiceError.invalidParams }
                    let gas = try await RPCClient.shared.estimateGas(
                        to: to,
                        from: callObj["from"],
                        data: callObj["data"],
                        value: callObj["value"]
                    )
                    result = AnyCodable("0x" + String(gas, radix: 16))

                default:
                    throw WCServiceError.unsupported
                }

                try await Sign.instance.respond(
                    topic: request.topic,
                    requestId: request.id,
                    response: .response(result)
                )
            } catch {
                respondError(request: request, code: -32000, message: error.localizedDescription)
            }
        }
    }

    // MARK: - Session Management

    func emitAccountsChanged() {
        guard let wallet = EnclaveEngine.shared.currentWallet else { return }
        for session in sessions {
            for (namespace, _) in session.namespaces {
                guard let chain = session.namespaces[namespace]?.chains?.first else { continue }
                let account = Account(blockchain: chain, address: wallet.address)!
                let updatedAccounts = [account]
                let updatedNamespace = SessionNamespace(
                    chains: session.namespaces[namespace]?.chains.map(Array.init),
                    accounts: updatedAccounts,
                    methods: session.namespaces[namespace]?.methods ?? [],
                    events: session.namespaces[namespace]?.events ?? []
                )
                Task {
                    do {
                        try await Sign.instance.update(
                            topic: session.topic,
                            namespaces: [namespace: updatedNamespace]
                        )
                        try await Sign.instance.emit(
                            topic: session.topic,
                            event: Session.Event(name: "accountsChanged", data: AnyCodable([wallet.address])),
                            chainId: chain
                        )
                        log.notice("Emitted accountsChanged to \(session.peer.name, privacy: .public)")
                    } catch {
                        log.error("accountsChanged emit failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
    }

    func disconnect(topic: String) {
        Task {
            try? await Sign.instance.disconnect(topic: topic)
            await MainActor.run {
                sessions = Sign.instance.getSessions()
            }
        }
    }

    // MARK: - Helpers

    private func respondError(request: Request, code: Int, message: String) {
        Task {
            try? await Sign.instance.respond(
                topic: request.topic,
                requestId: request.id,
                response: .error(.init(code: code, message: message))
            )
        }
    }
}

enum WCServiceError: Error {
    case invalidParams
    case unsupported
}
