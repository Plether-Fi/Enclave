import SwiftUI
import os

nonisolated(unsafe) private let log = Logger(subsystem: "com.plether.EnclaveWallet", category: "TxHistory")

nonisolated struct Transaction: Identifiable, Sendable {
    let id: String
    let hash: String
    let from: String
    let to: String
    let value: String
    let timestamp: Date
    let isIncoming: Bool
    let status: String

    var displayAddress: String {
        let addr = isIncoming ? from : to
        return String(addr.prefix(6)) + "..." + String(addr.suffix(4))
    }
}

actor TransactionHistoryService {
    static let shared = TransactionHistoryService()

    func fetchHistory(address: String) async -> [Transaction] {
        let network = Config.activeNetwork
        let urlString = "\(network.blockExplorerAPI)?module=account&action=txlist&address=\(address)&startblock=0&endblock=99999999&sort=desc&page=1&offset=20"

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

                return Transaction(
                    id: hash,
                    hash: hash,
                    from: from,
                    to: to,
                    value: Wei(hex: "0x" + String(UInt64(value) ?? 0, radix: 16)).ethFormatted,
                    timestamp: Date(timeIntervalSince1970: timestamp),
                    isIncoming: to.lowercased() == lowerAddress,
                    status: isError == "0" ? "confirmed" : "failed"
                )
            }
        } catch {
            log.error("Failed to fetch tx history: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}

struct TransactionHistoryView: View {
    let address: String
    @State private var transactions: [Transaction] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading transactions...")
            } else if transactions.isEmpty {
                Text("No transactions yet")
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                List(transactions) { tx in
                    HStack {
                        Image(systemName: tx.isIncoming ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                            .foregroundColor(tx.isIncoming ? .green : .orange)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(tx.isIncoming ? "Received" : "Sent")
                                .font(.body)
                            Text(tx.displayAddress)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(tx.isIncoming ? "+" : "-")\(tx.value) ETH")
                                .font(.system(.body, design: .monospaced))
                            Text(tx.timestamp, style: .relative)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .task {
            transactions = await TransactionHistoryService.shared.fetchHistory(address: address)
            isLoading = false
        }
    }
}
