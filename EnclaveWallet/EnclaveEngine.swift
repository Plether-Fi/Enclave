import Foundation
import CryptoKit
import CryptoSwift
import Security
import BigInt
import P256K
import os

private let log = Logger(subsystem: "com.plether.EnclaveWallet", category: "Engine")
private let keychainService = "com.plether.EnclaveWallet"

enum WalletKind {
    case smartWallet(privateKey: SecureEnclave.P256.Signing.PrivateKey, pubKeyX: String, pubKeyY: String)
    case eoa
}

struct Wallet {
    let index: Int
    let kind: WalletKind
    let address: String
    var name: String
    var isDeployed: Bool = false

    var displayAddress: String {
        String(address.prefix(6)) + "..." + String(address.suffix(4))
    }

    var isSmartWallet: Bool {
        if case .smartWallet = kind { return true }
        return false
    }

    var isEOA: Bool {
        if case .eoa = kind { return true }
        return false
    }

    var pubKeyX: String? {
        guard case .smartWallet(_, let x, _) = kind else { return nil }
        return x
    }

    var pubKeyY: String? {
        guard case .smartWallet(_, _, let y) = kind else { return nil }
        return y
    }

    var p256Key: SecureEnclave.P256.Signing.PrivateKey? {
        guard case .smartWallet(let key, _, _) = kind else { return nil }
        return key
    }
}

class EnclaveEngine: @unchecked Sendable {
    static let shared = EnclaveEngine()

    private(set) var wallets: [Wallet] = []
    private(set) var selectedIndex: Int {
        didSet { UserDefaults.standard.set(selectedIndex, forKey: "selectedWalletIndex") }
    }

    var currentWallet: Wallet? {
        wallets.first { $0.index == selectedIndex }
    }

    private init() {
        selectedIndex = UserDefaults.standard.integer(forKey: "selectedWalletIndex")
        loadWallets()
    }

    func generateKey() throws {
        let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .or, .biometryCurrentSet, .devicePasscode],
            nil
        )!

        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: accessControl)
        let index = (wallets.map(\.index).max() ?? -1) + 1

        try saveKeyToKeychain(key, index: index)

        let (x, y) = extractCoordinates(from: key.publicKey)
        let address = computeCounterfactualAddress(pubKeyX: x, pubKeyY: y, salt: UInt64(index))
        let defaultName = "Wallet \(index + 1)"
        UserDefaults.standard.set(defaultName, forKey: "walletName.\(index)")
        UserDefaults.standard.set("smart", forKey: "walletType.\(index)")
        let wallet = Wallet(index: index, kind: .smartWallet(privateKey: key, pubKeyX: x, pubKeyY: y), address: address, name: defaultName)
        wallets.append(wallet)
        selectedIndex = index
        log.notice("Smart wallet \(index, privacy: .public) created: \(wallet.displayAddress, privacy: .public)")
    }

    func generateEOAKey() throws {
        let privateKey = try P256K.Signing.PrivateKey()
        let index = (wallets.map(\.index).max() ?? -1) + 1

        let keyData = Data(privateKey.dataRepresentation)
        saveEOAKeyToKeychain(keyData, index: index)

        let address = try deriveEOAAddress(from: keyData)
        let defaultName = "Wallet \(index + 1)"
        UserDefaults.standard.set(defaultName, forKey: "walletName.\(index)")
        UserDefaults.standard.set("eoa", forKey: "walletType.\(index)")
        let wallet = Wallet(index: index, kind: .eoa, address: address, name: defaultName)
        wallets.append(wallet)
        selectedIndex = index
        log.notice("EOA wallet \(index, privacy: .public) created: \(wallet.displayAddress, privacy: .public)")
    }

    func selectWallet(at index: Int) {
        guard wallets.contains(where: { $0.index == index }) else { return }
        selectedIndex = index
    }

    func renameWallet(at index: Int, to name: String) {
        guard let i = wallets.firstIndex(where: { $0.index == index }) else { return }
        wallets[i].name = name
        UserDefaults.standard.set(name, forKey: "walletName.\(index)")
        NotificationCenter.default.post(name: .walletStateDidChange, object: nil)
    }

    func getCoordinates() -> (x: String, y: String)? {
        guard let wallet = currentWallet,
              let x = wallet.pubKeyX, let y = wallet.pubKeyY else { return nil }
        return (x, y)
    }

    func signEVMHash(payloadHash: Data) throws -> String {
        let sig = try signEVMHashRaw(payloadHash: payloadHash)
        return "0x" + sig.map { String(format: "%02x", $0) }.joined()
    }

    func signEVMHashRaw(payloadHash: Data) throws -> Data {
        guard let wallet = currentWallet else { throw NSError(domain: "NoKey", code: 0) }
        switch wallet.kind {
        case .smartWallet(let key, _, _):
            return try signP256(key: key, payloadHash: payloadHash)
        case .eoa:
            return try signSecp256k1(walletIndex: wallet.index, payloadHash: payloadHash)
        }
    }

    private func signP256(key: SecureEnclave.P256.Signing.PrivateKey, payloadHash: Data) throws -> Data {
        let signature = try key.signature(for: payloadHash)

        let rawSig = signature.rawRepresentation
        let rData = rawSig[0..<32]
        var sData = Data(rawSig[32..<64])

        var sBigInt = BigUInt(sData)
        let p256Order = BigUInt("FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551", radix: 16)!
        let halfOrder = p256Order / 2

        if sBigInt > halfOrder {
            sBigInt = p256Order - sBigInt
            sData = sBigInt.serialize()
            if sData.count < 32 { sData = Data(repeating: 0, count: 32 - sData.count) + sData }
        }

        return Data(rData) + sData
    }

    func signSecp256k1(walletIndex: Int, payloadHash: Data) throws -> Data {
        guard let keyData = loadKeychainData(account: "eoa.\(walletIndex)") else {
            throw NSError(domain: "NoKey", code: 0)
        }
        let privateKey = try P256K.Recovery.PrivateKey(dataRepresentation: keyData)
        let digest = HashDigest(Array(payloadHash))
        let signature = try privateKey.signature(for: digest)
        let compact = try signature.compactRepresentation
        let v = UInt8(compact.recoveryId) + 27

        var result = Data(capacity: 65)
        result.append(compact.signature)
        result.append(v)
        return result
    }

    func refreshDeploymentStatus() async {
        for i in wallets.indices {
            guard wallets[i].isSmartWallet else { continue }
            let address = wallets[i].address
            do {
                let code = try await RPCClient.shared.getCode(address: address)
                wallets[i].isDeployed = code != "0x" && code != "0x0" && code.count > 4
            } catch {
                wallets[i].isDeployed = false
            }
        }
    }

    // MARK: - Keychain

    private func saveKeyToKeychain(_ key: SecureEnclave.P256.Signing.PrivateKey, index: Int) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "key.\(index)",
            kSecValueData as String: key.dataRepresentation,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private func saveEOAKeyToKeychain(_ data: Data, index: Int) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "eoa.\(index)",
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update: [String: Any] = [kSecValueData as String: data]
            SecItemUpdate(query as CFDictionary, update as CFDictionary)
        }
    }

    func loadKeychainData(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    private func loadWallets() {
        for index in 0..<100 {
            let walletType = UserDefaults.standard.string(forKey: "walletType.\(index)")
            let name = UserDefaults.standard.string(forKey: "walletName.\(index)") ?? "Wallet \(index + 1)"

            if walletType == "eoa" {
                guard let keyData = loadKeychainData(account: "eoa.\(index)") else { continue }
                do {
                    let address = try deriveEOAAddress(from: keyData)
                    wallets.append(Wallet(index: index, kind: .eoa, address: address, name: name))
                    log.notice("EOA wallet \(index, privacy: .public): \(address, privacy: .public)")
                } catch {
                    log.error("Failed to restore EOA key \(index, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            } else {
                guard let data = loadKeychainData(account: "key.\(index)") else { continue }
                do {
                    let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data)
                    let (x, y) = extractCoordinates(from: key.publicKey)
                    let address = computeCounterfactualAddress(pubKeyX: x, pubKeyY: y, salt: UInt64(index))
                    wallets.append(Wallet(index: index, kind: .smartWallet(privateKey: key, pubKeyX: x, pubKeyY: y), address: address, name: name))
                    log.notice("Smart wallet \(index, privacy: .public): \(address, privacy: .public)")
                } catch {
                    log.error("Failed to restore key \(index, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        if !wallets.contains(where: { $0.index == selectedIndex }), let first = wallets.first {
            selectedIndex = first.index
        }

        log.notice("Loaded \(self.wallets.count, privacy: .public) wallet(s)")
    }

    // MARK: - Address Derivation

    private func deriveEOAAddress(from keyData: Data) throws -> String {
        let privateKey = try P256K.Signing.PrivateKey(dataRepresentation: keyData)
        let uncompressed = privateKey.publicKey.uncompressedRepresentation
        let pubKeyBytes = Array(uncompressed.dropFirst())
        let hash = Digest.sha3(pubKeyBytes, variant: .keccak256)
        let addressBytes = hash.suffix(20)
        return "0x" + addressBytes.map { String(format: "%02x", $0) }.joined()
    }

    private func extractCoordinates(from publicKey: P256.Signing.PublicKey) -> (x: String, y: String) {
        let raw = publicKey.rawRepresentation
        let xHex = raw[1..<33].map { String(format: "%02x", $0) }.joined()
        let yHex = raw[33..<65].map { String(format: "%02x", $0) }.joined()
        return ("0x" + xHex, "0x" + yHex)
    }

    private func computeCounterfactualAddress(pubKeyX: String, pubKeyY: String, salt: UInt64) -> String {
        let factoryHex = Config.factoryAddress.stripHexPrefix()
        guard let factoryBytes = factoryHex.hexToData(), factoryBytes.count == 20 else {
            log.error("Invalid factory address")
            return "0x" + String(repeating: "0", count: 40)
        }

        let creationCode = Config.walletCreationCode
        guard let codeData = creationCode.hexToData() else {
            log.error("Invalid creation code")
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
        let saltBig = BigUInt(salt)
        let saltSerialized = saltBig.serialize()
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
