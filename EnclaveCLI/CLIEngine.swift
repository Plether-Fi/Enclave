import Foundation
import CryptoKit
import CryptoSwift
import BigInt

private let p256Order = BigUInt("FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551", radix: 16)!
private let halfOrder = p256Order / 2

struct CLIWallet: Sendable {
    let index: Int
    let address: String
    let pubKeyX: String
    let pubKeyY: String
}

struct CLIConfig: Codable, Sendable {
    var selectedIndex: Int
    var network: String
}

actor CLIEngine {
    static let shared = CLIEngine()

    private let baseDir: URL
    private let keysDir: URL
    private let configFile: URL

    private var keys: [Int: P256.Signing.PrivateKey] = [:]
    private(set) var wallets: [CLIWallet] = []
    private(set) var config: CLIConfig

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        baseDir = home.appendingPathComponent(".enclave")
        keysDir = baseDir.appendingPathComponent("keys")
        configFile = baseDir.appendingPathComponent("config.json")

        try? FileManager.default.createDirectory(at: keysDir, withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: configFile),
           let cfg = try? JSONDecoder().decode(CLIConfig.self, from: data) {
            config = cfg
        } else {
            config = CLIConfig(selectedIndex: 0, network: "anvil")
        }

        if let network = Network(rawValue: config.network) {
            Config.activeNetwork = network
        }

        let (loadedKeys, loadedWallets) = Self.loadKeysFromDisk(keysDir: keysDir)
        self.keys = loadedKeys
        self.wallets = loadedWallets
    }

    var currentWallet: CLIWallet? {
        wallets.first { $0.index == config.selectedIndex } ?? wallets.first
    }

    func generateKey() throws -> CLIWallet {
        let key = P256.Signing.PrivateKey()
        let index = (wallets.map(\.index).max() ?? -1) + 1

        let hexBytes = key.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        let keyFile = keysDir.appendingPathComponent("\(index).pem")
        try hexBytes.write(to: keyFile, atomically: true, encoding: .utf8)

        let (x, y) = Self.extractCoordinates(from: key.publicKey)
        let address = Self.computeCounterfactualAddress(pubKeyX: x, pubKeyY: y, salt: UInt64(index))
        let wallet = CLIWallet(index: index, address: address, pubKeyX: x, pubKeyY: y)

        keys[index] = key
        wallets.append(wallet)
        config.selectedIndex = index
        saveConfig()

        return wallet
    }

    func selectWallet(at index: Int) -> Bool {
        guard wallets.contains(where: { $0.index == index }) else { return false }
        config.selectedIndex = index
        saveConfig()
        return true
    }

    func setNetwork(_ network: Network) {
        config.network = network.rawValue
        Config.activeNetwork = network
        saveConfig()
    }

    func signHash(_ hash: Data) throws -> Data {
        guard let wallet = currentWallet, let key = keys[wallet.index] else {
            throw CLIError.noKey
        }

        let signature = try key.signature(for: hash)
        let rawSig = signature.rawRepresentation
        let rData = rawSig[0..<32]
        var sData = Data(rawSig[32..<64])

        var sBigInt = BigUInt(sData)
        if sBigInt > halfOrder {
            sBigInt = p256Order - sBigInt
            sData = sBigInt.serialize()
            if sData.count < 32 { sData = Data(repeating: 0, count: 32 - sData.count) + sData }
        }

        return Data(rData) + sData
    }

    func isDeployed(address: String) async throws -> Bool {
        let code = try await RPCClient.shared.getCode(address: address)
        return code != "0x" && code != "0x0" && code.count > 4
    }

    // MARK: - Private

    nonisolated private static func loadKeysFromDisk(keysDir: URL) -> ([Int: P256.Signing.PrivateKey], [CLIWallet]) {
        let fm = FileManager.default
        var keys: [Int: P256.Signing.PrivateKey] = [:]
        var wallets: [CLIWallet] = []
        var index = 0
        while true {
            let keyFile = keysDir.appendingPathComponent("\(index).pem")
            guard fm.fileExists(atPath: keyFile.path) else {
                if index > 100 { break }
                index += 1
                continue
            }

            guard let hex = try? String(contentsOf: keyFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                  let rawData = hex.hexToData(),
                  let key = try? P256.Signing.PrivateKey(rawRepresentation: rawData) else {
                index += 1
                continue
            }

            let (x, y) = extractCoordinates(from: key.publicKey)
            let address = computeCounterfactualAddress(pubKeyX: x, pubKeyY: y, salt: UInt64(index))
            keys[index] = key
            wallets.append(CLIWallet(index: index, address: address, pubKeyX: x, pubKeyY: y))
            index += 1
        }
        return (keys, wallets)
    }

    private func saveConfig() {
        if let data = try? JSONEncoder().encode(config) {
            try? data.write(to: configFile)
        }
    }

    nonisolated private static func extractCoordinates(from publicKey: P256.Signing.PublicKey) -> (x: String, y: String) {
        let raw = publicKey.rawRepresentation
        let xHex = raw.prefix(32).map { String(format: "%02x", $0) }.joined()
        let yHex = raw.suffix(32).map { String(format: "%02x", $0) }.joined()
        return ("0x" + xHex, "0x" + yHex)
    }

    nonisolated private static func computeCounterfactualAddress(pubKeyX: String, pubKeyY: String, salt: UInt64) -> String {
        let factoryHex = Config.factoryAddress.stripHexPrefix()
        guard let factoryBytes = factoryHex.hexToData(), factoryBytes.count == 20 else {
            return "0x" + String(repeating: "0", count: 40)
        }

        guard let codeData = Config.walletCreationCode.hexToData() else {
            return "0x" + String(repeating: "0", count: 40)
        }

        let entryPointPadded = Config.entryPointAddress.leftPadded(toLength: 64)
        let xPadded = pubKeyX.leftPadded(toLength: 64)
        let yPadded = pubKeyY.leftPadded(toLength: 64)

        guard let epData = entryPointPadded.hexToData(),
              let xData = xPadded.hexToData(),
              let yData = yPadded.hexToData() else {
            return "0x" + String(repeating: "0", count: 40)
        }

        let initCode = codeData + epData + xData + yData
        let initCodeHash = Array(initCode).sha3(.keccak256)

        var saltBytes = Data(repeating: 0, count: 32)
        let saltSerialized = BigUInt(salt).serialize()
        let saltStart = 32 - saltSerialized.count
        for (i, b) in saltSerialized.enumerated() { saltBytes[saltStart + i] = b }

        var packed = Data()
        packed.append(0xff)
        packed.append(factoryBytes)
        packed.append(saltBytes)
        packed.append(contentsOf: initCodeHash)

        let hash = Array(packed).sha3(.keccak256)
        let addressBytes = hash.suffix(20)
        return "0x" + addressBytes.map { String(format: "%02x", $0) }.joined()
    }
}

enum CLIError: Error, CustomStringConvertible {
    case noKey
    case noWallet
    case invalidAddress
    case invalidAmount

    var description: String {
        switch self {
        case .noKey: "No key loaded — run 'new' first"
        case .noWallet: "No wallet selected"
        case .invalidAddress: "Invalid address (must be 0x + 40 hex chars)"
        case .invalidAmount: "Invalid amount"
        }
    }
}
