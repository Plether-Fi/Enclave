import Foundation
import os

private let log = Logger(subsystem: "com.plether.EnclaveWallet", category: "Permissions")

struct AppPermission: Codable, Sendable {
    let appId: String
    var allowedMethods: Set<String>
    var maxSpendPerTx: UInt64?
    var allowedContracts: Set<String>
    var sessionExpiry: Date?
    var grantedAt: Date

    var isExpired: Bool {
        if let expiry = sessionExpiry { return Date() > expiry }
        return false
    }
}

enum PermissionCheck: Sendable {
    case allowed
    case denied(reason: String)
    case needsPrompt
}

actor AppPermissionStore {
    static let shared = AppPermissionStore()

    private var permissions: [String: AppPermission] = [:]
    private let storePath: URL

    private static let readOnlyMethods: Set<String> = [
        "eth_accounts", "eth_requestAccounts", "eth_chainId",
        "eth_getBalance", "eth_call", "eth_blockNumber", "eth_estimateGas",
        "net_version", "web3_clientVersion"
    ]

    private static let signingMethods: Set<String> = [
        "personal_sign", "eth_signTypedData_v4", "eth_sendTransaction"
    ]

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("EnclaveWallet")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storePath = dir.appendingPathComponent("permissions.json")
        loadFromDisk()
    }

    func check(appId: String, method: String) -> PermissionCheck {
        if Self.readOnlyMethods.contains(method) {
            return .allowed
        }

        guard let perm = permissions[appId] else {
            return .needsPrompt
        }

        if perm.isExpired {
            return .needsPrompt
        }

        if perm.allowedMethods.contains(method) {
            return .allowed
        }

        if Self.signingMethods.contains(method) {
            return .needsPrompt
        }

        return .denied(reason: "Method \(method) not permitted for \(appId)")
    }

    func grant(appId: String, methods: Set<String>, maxSpend: UInt64? = nil,
               contracts: Set<String> = [], expiresIn: TimeInterval? = nil) {
        let expiry = expiresIn.map { Date().addingTimeInterval($0) }
        let perm = AppPermission(
            appId: appId,
            allowedMethods: methods,
            maxSpendPerTx: maxSpend,
            allowedContracts: contracts,
            sessionExpiry: expiry,
            grantedAt: Date()
        )
        permissions[appId] = perm
        saveToDisk()
        log.notice("Granted permissions to \(appId, privacy: .public): \(methods.joined(separator: ", "), privacy: .public)")
    }

    func revoke(appId: String) {
        permissions.removeValue(forKey: appId)
        saveToDisk()
        log.notice("Revoked permissions for \(appId, privacy: .public)")
    }

    func allPermissions() -> [AppPermission] {
        Array(permissions.values)
    }

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: storePath.path) else { return }
        do {
            let data = try Data(contentsOf: storePath)
            permissions = try JSONDecoder().decode([String: AppPermission].self, from: data)
        } catch {
            log.error("Failed to load permissions: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func saveToDisk() {
        do {
            let data = try JSONEncoder().encode(permissions)
            try data.write(to: storePath, options: .atomic)
        } catch {
            log.error("Failed to save permissions: \(error.localizedDescription, privacy: .public)")
        }
    }
}
