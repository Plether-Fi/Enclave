import Foundation
import CryptoKit
import CryptoSwift
import Security
import BigInt
import os

private let log = Logger(subsystem: "com.plether.EnclaveWallet", category: "Engine")
private let keychainService = "com.plether.EnclaveWallet"

struct Wallet {
    let index: Int
    let privateKey: SecureEnclave.P256.Signing.PrivateKey
    let address: String
    let pubKeyX: String
    let pubKeyY: String

    var displayAddress: String {
        String(address.prefix(6)) + "..." + String(address.suffix(4))
    }

    var isDeployed: Bool = false
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

    private var privateKey: SecureEnclave.P256.Signing.PrivateKey? {
        currentWallet?.privateKey
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
        let wallet = Wallet(index: index, privateKey: key, address: address, pubKeyX: x, pubKeyY: y)
        wallets.append(wallet)
        selectedIndex = index
        log.notice("Wallet \(index, privacy: .public) created: \(wallet.displayAddress, privacy: .public)")
    }

    func selectWallet(at index: Int) {
        guard wallets.contains(where: { $0.index == index }) else { return }
        selectedIndex = index
    }

    func getCoordinates() -> (x: String, y: String)? {
        guard let wallet = currentWallet else { return nil }
        return (wallet.pubKeyX, wallet.pubKeyY)
    }

    func signEVMHash(payloadHash: Data) throws -> String {
        guard let key = self.privateKey else { throw NSError(domain: "NoKey", code: 0) }

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

        let finalSignature = rData + sData
        return "0x" + finalSignature.map { String(format: "%02x", $0) }.joined()
    }

    func signEVMHashRaw(payloadHash: Data) throws -> Data {
        guard let key = self.privateKey else { throw NSError(domain: "NoKey", code: 0) }

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

    func refreshDeploymentStatus() async {
        for i in wallets.indices {
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

    private func loadWallets() {
        for index in 0..<100 {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: "key.\(index)",
                kSecReturnData as String: true,
            ]

            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)

            guard status == errSecSuccess, let data = result as? Data else {
                if status == errSecItemNotFound { continue }
                break
            }

            do {
                let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data)
                let (x, y) = extractCoordinates(from: key.publicKey)
                let address = computeCounterfactualAddress(pubKeyX: x, pubKeyY: y, salt: UInt64(index))
                let wallet = Wallet(index: index, privateKey: key, address: address, pubKeyX: x, pubKeyY: y)
                wallets.append(wallet)
            } catch {
                log.error("Failed to restore key \(index, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        if !wallets.contains(where: { $0.index == selectedIndex }), let first = wallets.first {
            selectedIndex = first.index
        }

        log.notice("Loaded \(self.wallets.count, privacy: .public) wallet(s)")
    }

    // MARK: - Address Derivation

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
