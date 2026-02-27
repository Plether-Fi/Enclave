import BigInt
import Foundation
import os

nonisolated(unsafe) private let log = Logger(subsystem: "com.plether.EnclaveWallet", category: "TxHistory")

nonisolated struct Transaction: Identifiable, Sendable {
    let id: String
    let hash: String
    let from: String
    let to: String
    let value: String
    let tokenSymbol: String
    let timestamp: Date
    let isIncoming: Bool
    let status: String
    let isContractCreation: Bool

    init(id: String, hash: String, from: String, to: String, value: String,
         tokenSymbol: String, timestamp: Date, isIncoming: Bool, status: String,
         isContractCreation: Bool = false) {
        self.id = id; self.hash = hash; self.from = from; self.to = to
        self.value = value; self.tokenSymbol = tokenSymbol; self.timestamp = timestamp
        self.isIncoming = isIncoming; self.status = status
        self.isContractCreation = isContractCreation
    }

    var displayAddress: String {
        let addr = isIncoming ? from : to
        return String(addr.prefix(6)) + "..." + String(addr.suffix(4))
    }
}

actor TransactionHistoryService {
    static let shared = TransactionHistoryService()

    private static let localStoreKey = "localTransactions"

    func recordSend(from: String, to: String, value: String, tokenSymbol: String, txHash: String) {
        var stored = loadLocalTransactions(for: from)
        let entry: [String: String] = [
            "hash": txHash, "from": from, "to": to,
            "value": value, "tokenSymbol": tokenSymbol,
            "timestamp": "\(Int(Date().timeIntervalSince1970))",
        ]
        stored.append(entry)
        if stored.count > 50 { stored = Array(stored.suffix(50)) }
        saveLocalTransactions(stored, for: from)
    }

    func fetchHistory(address: String) async -> [Transaction] {
        let network = Config.activeNetwork
        guard !network.isLocal else { return loadLocalOnly(address: address) }

        async let normalTxs = fetchNormalTransactions(address: address, network: network)
        async let internalTxs = fetchInternalTransactions(address: address, network: network)
        async let tokenTxs = fetchTokenTransactions(address: address, network: network)
        async let creationTx = fetchContractCreation(address: address, network: network)

        let remote = await normalTxs + internalTxs + tokenTxs + creationTx
        let remoteHashes = Set(remote.map { $0.hash })

        let local = loadLocalOnly(address: address).filter { !remoteHashes.contains($0.hash) }

        var all = remote + local
        all.sort { $0.timestamp > $1.timestamp }
        return Array(all.prefix(20))
    }

    private func loadLocalOnly(address: String) -> [Transaction] {
        let lowerAddress = address.lowercased()
        return loadLocalTransactions(for: address).compactMap { entry in
            guard let hash = entry["hash"],
                  let from = entry["from"],
                  let to = entry["to"],
                  let value = entry["value"],
                  let symbol = entry["tokenSymbol"],
                  let ts = entry["timestamp"],
                  let timestamp = TimeInterval(ts) else { return nil }
            return Transaction(
                id: "\(hash)-local",
                hash: hash, from: from, to: to,
                value: value, tokenSymbol: symbol,
                timestamp: Date(timeIntervalSince1970: timestamp),
                isIncoming: to.lowercased() == lowerAddress,
                status: "confirmed"
            )
        }
    }

    private func loadLocalTransactions(for address: String) -> [[String: String]] {
        let key = "\(Self.localStoreKey)-\(address.lowercased())"
        return UserDefaults.standard.array(forKey: key) as? [[String: String]] ?? []
    }

    private func saveLocalTransactions(_ txs: [[String: String]], for address: String) {
        let key = "\(Self.localStoreKey)-\(address.lowercased())"
        UserDefaults.standard.set(txs, forKey: key)
    }

    private func fetchNormalTransactions(address: String, network: Network) async -> [Transaction] {
        var urlString = "\(network.blockExplorerAPI)&module=account&action=txlist&address=\(address)&startblock=0&endblock=99999999&sort=desc&page=1&offset=20"
        if !Secrets.arbiscanAPIKey.isEmpty {
            urlString += "&apikey=\(Secrets.arbiscanAPIKey)"
        }

        guard let url = URL(string: urlString) else { return [] }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [[String: Any]] else { return [] }

            let lowerAddress = address.lowercased()
            return result.compactMap { tx -> Transaction? in
                guard let hash = tx["hash"] as? String,
                      let from = tx["from"] as? String,
                      let to = tx["to"] as? String,
                      let value = tx["value"] as? String,
                      let timestampStr = tx["timeStamp"] as? String,
                      let timestamp = TimeInterval(timestampStr),
                      let isError = tx["isError"] as? String else { return nil }

                guard let bigValue = BigUInt(value, radix: 10), bigValue > 0 else { return nil }

                return Transaction(
                    id: "\(hash)-tx",
                    hash: hash,
                    from: from,
                    to: to,
                    value: Wei(bigUInt: bigValue).ethFormatted,
                    tokenSymbol: "ETH",
                    timestamp: Date(timeIntervalSince1970: timestamp),
                    isIncoming: to.lowercased() == lowerAddress,
                    status: isError == "0" ? "confirmed" : "failed"
                )
            }
        } catch {
            log.error("Failed to fetch normal txs: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func fetchInternalTransactions(address: String, network: Network) async -> [Transaction] {
        var urlString = "\(network.blockExplorerAPI)&module=account&action=txlistinternal&address=\(address)&startblock=0&endblock=99999999&sort=desc&page=1&offset=20"
        if !Secrets.arbiscanAPIKey.isEmpty {
            urlString += "&apikey=\(Secrets.arbiscanAPIKey)"
        }

        guard let url = URL(string: urlString) else { return [] }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [[String: Any]] else { return [] }

            let lowerAddress = address.lowercased()
            return result.compactMap { tx -> Transaction? in
                guard let hash = tx["hash"] as? String,
                      let from = tx["from"] as? String,
                      let to = tx["to"] as? String,
                      let value = tx["value"] as? String,
                      let timestampStr = tx["timeStamp"] as? String,
                      let timestamp = TimeInterval(timestampStr),
                      let isError = tx["isError"] as? String else { return nil }

                let txType = tx["type"] as? String ?? ""
                let isCreate = txType == "create" || txType == "create2"

                guard let bigValue = BigUInt(value, radix: 10) else { return nil }
                guard bigValue > 0 || isCreate else { return nil }

                return Transaction(
                    id: "\(hash)-int-\(from)-\(to)-\(value)",
                    hash: hash,
                    from: from,
                    to: to,
                    value: isCreate ? "" : Wei(bigUInt: bigValue).ethFormatted,
                    tokenSymbol: isCreate ? "" : "ETH",
                    timestamp: Date(timeIntervalSince1970: timestamp),
                    isIncoming: to.lowercased() == lowerAddress,
                    status: isError == "0" ? "confirmed" : "failed",
                    isContractCreation: isCreate
                )
            }
        } catch {
            log.error("Failed to fetch internal txs: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func fetchTokenTransactions(address: String, network: Network) async -> [Transaction] {
        var urlString = "\(network.blockExplorerAPI)&module=account&action=tokentx&address=\(address)&startblock=0&endblock=99999999&sort=desc&page=1&offset=20"
        if !Secrets.arbiscanAPIKey.isEmpty {
            urlString += "&apikey=\(Secrets.arbiscanAPIKey)"
        }

        guard let url = URL(string: urlString) else { return [] }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [[String: Any]] else { return [] }

            let lowerAddress = address.lowercased()
            return result.compactMap { tx -> Transaction? in
                guard let hash = tx["hash"] as? String,
                      let from = tx["from"] as? String,
                      let to = tx["to"] as? String,
                      let value = tx["value"] as? String,
                      let timestampStr = tx["timeStamp"] as? String,
                      let timestamp = TimeInterval(timestampStr),
                      let symbol = tx["tokenSymbol"] as? String,
                      let decimalStr = tx["tokenDecimal"] as? String,
                      let decimals = Int(decimalStr) else { return nil }

                guard let bigValue = BigUInt(value, radix: 10), bigValue > 0 else { return nil }

                return Transaction(
                    id: "\(hash)-tok-\(from)-\(to)-\(value)",
                    hash: hash,
                    from: from,
                    to: to,
                    value: Wei(bigUInt: bigValue).formatted(decimals: decimals, precision: decimals >= 18 ? 4 : 2),
                    tokenSymbol: symbol,
                    timestamp: Date(timeIntervalSince1970: timestamp),
                    isIncoming: to.lowercased() == lowerAddress,
                    status: "confirmed"
                )
            }
        } catch {
            log.error("Failed to fetch token txs: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func fetchContractCreation(address: String, network: Network) async -> [Transaction] {
        var urlString = "\(network.blockExplorerAPI)&module=contract&action=getcontractcreation&contractaddresses=\(address)"
        if !Secrets.arbiscanAPIKey.isEmpty {
            urlString += "&apikey=\(Secrets.arbiscanAPIKey)"
        }

        guard let url = URL(string: urlString) else { return [] }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [[String: Any]] else { return [] }

            return result.compactMap { entry -> Transaction? in
                guard let hash = entry["txHash"] as? String,
                      let creator = entry["contractCreator"] as? String,
                      let timestampStr = entry["timestamp"] as? String,
                      let timestamp = TimeInterval(timestampStr) else { return nil }

                return Transaction(
                    id: "\(hash)-create",
                    hash: hash,
                    from: creator,
                    to: address,
                    value: "",
                    tokenSymbol: "",
                    timestamp: Date(timeIntervalSince1970: timestamp),
                    isIncoming: true,
                    status: "confirmed",
                    isContractCreation: true
                )
            }
        } catch {
            log.error("Failed to fetch contract creation: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}
