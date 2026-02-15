import Foundation
import CryptoKit
import Security
import BigInt

class EnclaveEngine: @unchecked Sendable {
    static let shared = EnclaveEngine()
    var privateKey: SecureEnclave.P256.Signing.PrivateKey?

    func generateKey() throws {
        let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .biometryCurrentSet],
            nil
        )!

        self.privateKey = try SecureEnclave.P256.Signing.PrivateKey(accessControl: accessControl)
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
}
