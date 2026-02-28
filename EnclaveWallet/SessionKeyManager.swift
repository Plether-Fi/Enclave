import Foundation
import P256K
import CryptoSwift
import os

private let log = Logger(subsystem: "com.plether.EnclaveWallet", category: "SessionKey")
private let keychainService = "com.plether.EnclaveWallet.sessionKeys"
private let appIdsKey = "sessionKeyAppIds"

struct SessionKey: Sendable {
    let appId: String
    let address: String
}

class SessionKeyManager {
    static let shared = SessionKeyManager()

    private init() {}

    func getOrCreate(appId: String) throws -> SessionKey {
        if let existing = loadKey(appId: appId) {
            let address = try deriveAddress(from: existing)
            return SessionKey(appId: appId, address: address)
        }

        let privateKey = try P256K.Signing.PrivateKey()
        saveKey(Data(privateKey.dataRepresentation), appId: appId)
        let address = try deriveAddress(from: Data(privateKey.dataRepresentation))
        log.notice("Created session key for \(appId, privacy: .public): \(address, privacy: .public)")
        return SessionKey(appId: appId, address: address)
    }

    func sign(appId: String, hash: Data) throws -> Data {
        guard let keyData = loadKey(appId: appId) else {
            throw SessionKeyError.keyNotFound(appId)
        }

        let privateKey = try P256K.Recovery.PrivateKey(dataRepresentation: keyData)
        let digest = HashDigest(Array(hash))
        let signature = try privateKey.signature(for: digest)
        let compact = try signature.compactRepresentation
        let v = UInt8(compact.recoveryId) + 27

        var result = Data(capacity: 65)
        result.append(compact.signature)
        result.append(v)
        return result
    }

    func address(appId: String) throws -> String {
        guard let keyData = loadKey(appId: appId) else {
            throw SessionKeyError.keyNotFound(appId)
        }
        return try deriveAddress(from: keyData)
    }

    func remove(appId: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: appId,
        ]
        SecItemDelete(query as CFDictionary)

        var ids = storedAppIds()
        ids.removeAll { $0 == appId }
        UserDefaults.standard.set(ids, forKey: appIdsKey)
        log.notice("Removed session key for \(appId, privacy: .public)")
    }

    func allKeys() -> [SessionKey] {
        storedAppIds().compactMap { appId in
            guard let keyData = loadKey(appId: appId),
                  let address = try? deriveAddress(from: keyData) else { return nil }
            return SessionKey(appId: appId, address: address)
        }
    }

    // MARK: - Keychain

    private func loadKey(appId: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: appId,
            kSecReturnData as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    private func saveKey(_ data: Data, appId: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: appId,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update: [String: Any] = [kSecValueData as String: data]
            SecItemUpdate(query as CFDictionary, update as CFDictionary)
        }

        var ids = storedAppIds()
        if !ids.contains(appId) {
            ids.append(appId)
            UserDefaults.standard.set(ids, forKey: appIdsKey)
        }
    }

    private func storedAppIds() -> [String] {
        UserDefaults.standard.stringArray(forKey: appIdsKey) ?? []
    }

    // MARK: - Address Derivation

    private func deriveAddress(from keyData: Data) throws -> String {
        let privateKey = try P256K.Signing.PrivateKey(dataRepresentation: keyData)
        let uncompressed = privateKey.publicKey.uncompressedRepresentation
        let pubKeyBytes = Array(uncompressed.dropFirst())
        let hash = Digest.sha3(pubKeyBytes, variant: .keccak256)
        let addressBytes = hash.suffix(20)
        return "0x" + addressBytes.map { String(format: "%02x", $0) }.joined()
    }
}

enum SessionKeySigner {

    static func signHash(_ hash: Data, appId: String, wallet: Wallet) async throws -> String {
        let mgr = SessionKeyManager.shared
        let sessionKey = try mgr.getOrCreate(appId: appId)

        let registered = try await isSessionKeyRegistered(
            walletAddress: wallet.address, sessionKeyAddress: sessionKey.address
        )
        if !registered {
            try await registerSessionKey(wallet: wallet, sessionKeyAddress: sessionKey.address)
        }

        let sig = try mgr.sign(appId: appId, hash: hash)
        return "0x" + sig.map { String(format: "%02x", $0) }.joined()
    }

    private static func isSessionKeyRegistered(walletAddress: String, sessionKeyAddress: String) async throws -> Bool {
        let selector = "b7b8d604"
        let paddedAddr = sessionKeyAddress.stripHexPrefix().leftPadded(toLength: 64)
        let calldata = "0x" + selector + paddedAddr
        do {
            let result = try await RPCClient.shared.ethCall(to: walletAddress, data: calldata)
            let stripped = result.stripHexPrefix().replacingOccurrences(of: "0", with: "")
            return !stripped.isEmpty
        } catch {
            return false
        }
    }

    private static func registerSessionKey(wallet: Wallet, sessionKeyAddress: String) async throws {
        var op = UserOperation(sender: wallet.address)
        let nonce = try await RPCClient.shared.getEntryPointNonce(sender: wallet.address)
        op.nonce = "0x" + String(nonce, radix: 16)

        let code = try await RPCClient.shared.getCode(address: wallet.address)
        let deployed = code != "0x" && code != "0x0" && code.count > 4
        if !deployed, let x = wallet.pubKeyX, let y = wallet.pubKeyY {
            op.initCode = UserOperation.buildInitCode(
                pubKeyX: x, pubKeyY: y,
                salt: UInt64(wallet.index)
            )
        }

        op.callData = UserOperation.buildAddSessionKeyCallData(
            walletAddress: wallet.address, sessionKeyAddress: sessionKeyAddress
        )

        let (gasPrice, priorityFee) = try await (
            RPCClient.shared.getGasPrice(),
            RPCClient.shared.getMaxPriorityFeePerGas()
        )
        op.maxFeePerGas = gasPrice * 15 / 10
        op.maxPriorityFeePerGas = priorityFee * 15 / 10
        op.signature = Data(repeating: 0, count: 64)

        var estimateOp = op
        estimateOp.preVerificationGas = 0
        estimateOp.verificationGasLimit = 0
        estimateOp.callGasLimit = 0

        let gasEstimate = try await BundlerClient.shared.estimateGas(
            estimateOp.toDict(), entryPoint: Config.entryPointAddress
        )
        op.preVerificationGas = UInt64(gasEstimate.preVerificationGas.stripHexPrefix(), radix: 16) ?? 0
        op.verificationGasLimit = UInt64(gasEstimate.verificationGasLimit.stripHexPrefix(), radix: 16) ?? 0
        op.callGasLimit = UInt64(gasEstimate.callGasLimit.stripHexPrefix(), radix: 16) ?? 0

        let chainId = Config.activeNetwork.chainId
        let opHash = op.computeHash(entryPoint: Config.entryPointAddress, chainId: chainId)
        op.signature = try EnclaveEngine.shared.signEVMHashRaw(payloadHash: opHash)

        let userOpHash = try await BundlerClient.shared.sendUserOperation(
            op.toDict(), entryPoint: Config.entryPointAddress
        )
        let receipt = try await BundlerClient.shared.waitForReceipt(hash: userOpHash)
        guard receipt.success else { throw SessionKeyError.registrationFailed }

        log.notice("Session key \(sessionKeyAddress, privacy: .public) registered on-chain")
    }
}

enum SessionKeyError: LocalizedError {
    case keyNotFound(String)
    case registrationFailed

    var errorDescription: String? {
        switch self {
        case .keyNotFound(let appId): "No session key for \(appId)"
        case .registrationFailed: "Failed to register session key on-chain"
        }
    }
}
