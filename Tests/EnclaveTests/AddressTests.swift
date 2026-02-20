import Testing
import Foundation
import CryptoKit
@testable import EnclaveCLI

@Suite struct AddressTests {
    @Test func computeCounterfactualAddressGoldenVector() {
        let address = CLIEngine.computeCounterfactualAddress(
            pubKeyX: "0x56c99709fa9d5c65ec12b332a70e25e248593b8de6b188fe054a111a026c6d01",
            pubKeyY: "0x745af3d8cfa403712cb3750dacb7c4ca5d37922500ce61b5fd842e862b9f3a17",
            salt: 5
        )
        #expect(address == "0xb24687c2c3d8bdaaf6a2a44eeddb905018b5932e")
    }

    @Test func differentSaltProducesDifferentAddress() {
        let addr1 = CLIEngine.computeCounterfactualAddress(
            pubKeyX: "0x56c99709fa9d5c65ec12b332a70e25e248593b8de6b188fe054a111a026c6d01",
            pubKeyY: "0x745af3d8cfa403712cb3750dacb7c4ca5d37922500ce61b5fd842e862b9f3a17",
            salt: 5
        )
        let addr2 = CLIEngine.computeCounterfactualAddress(
            pubKeyX: "0x56c99709fa9d5c65ec12b332a70e25e248593b8de6b188fe054a111a026c6d01",
            pubKeyY: "0x745af3d8cfa403712cb3750dacb7c4ca5d37922500ce61b5fd842e862b9f3a17",
            salt: 6
        )
        #expect(addr1 != addr2)
    }

    @Test func extractCoordinatesRoundTrip() throws {
        let key = P256.Signing.PrivateKey()
        let (x, y) = CLIEngine.extractCoordinates(from: key.publicKey)
        #expect(x.hasPrefix("0x"))
        #expect(y.hasPrefix("0x"))
        #expect(x.count == 66) // 0x + 64 hex chars
        #expect(y.count == 66)
    }

    @Test func addressIsValidHex() {
        let address = CLIEngine.computeCounterfactualAddress(
            pubKeyX: "0x56c99709fa9d5c65ec12b332a70e25e248593b8de6b188fe054a111a026c6d01",
            pubKeyY: "0x745af3d8cfa403712cb3750dacb7c4ca5d37922500ce61b5fd842e862b9f3a17",
            salt: 0
        )
        #expect(address.hasPrefix("0x"))
        #expect(address.count == 42)
        let hexChars = CharacterSet(charactersIn: "0123456789abcdef")
        let stripped = address.stripHexPrefix()
        #expect(stripped.unicodeScalars.allSatisfy { hexChars.contains($0) })
    }
}
