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

    var displayAddress: String {
        String(address.prefix(6)) + "..." + String(address.suffix(4))
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

        let wallet = Wallet(index: index, privateKey: key, address: deriveAddress(from: key.publicKey))
        wallets.append(wallet)
        selectedIndex = index
        log.notice("Wallet \(index, privacy: .public) created: \(wallet.displayAddress, privacy: .public)")
    }

    func selectWallet(at index: Int) {
        guard wallets.contains(where: { $0.index == index }) else { return }
        selectedIndex = index
    }

    func getCoordinates() -> (x: String, y: String)? {
        guard let pubKey = privateKey?.publicKey.rawRepresentation else { return nil }

        let xHex = pubKey[1..<33].map { String(format: "%02x", $0) }.joined()
        let yHex = pubKey[33..<65].map { String(format: "%02x", $0) }.joined()

        return ("0x" + xHex, "0x" + yHex)
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
                let wallet = Wallet(index: index, privateKey: key, address: deriveAddress(from: key.publicKey))
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

    private func deriveAddress(from publicKey: P256.Signing.PublicKey) -> String {
        let raw = publicKey.rawRepresentation
        let xy = Array(raw[raw.startIndex + 1 ..< raw.endIndex])
        let hash = xy.sha3(.keccak256)
        let addressBytes = hash.suffix(20)
        return "0x" + addressBytes.map { String(format: "%02x", $0) }.joined()
    }
}
