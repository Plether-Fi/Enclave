import Testing
import BigInt
@testable import EnclaveCLI

@Suite struct WeiTests {
    @Test func zeroHex() {
        let w = Wei(hex: "0x0")
        #expect(w.isZero)
        #expect(w.ethFormatted == "0")
    }

    @Test func oneEther() {
        let w = Wei(hex: "0xde0b6b3a7640000")
        #expect(w.ethFormatted == "1")
    }

    @Test func fractionalEther() {
        let w = Wei(bigUInt: BigUInt(10).power(17))
        #expect(w.ethFormatted == "0.1000")
    }

    @Test func largeBigUInt() {
        let w = Wei(bigUInt: BigUInt("123456789000000000000000", radix: 10)!)
        #expect(w.ethFormatted == "123456.7890")
    }

    @Test func usdcFormatted() {
        let w = Wei(bigUInt: BigUInt(1_500_000))
        #expect(w.usdcFormatted == "1.50")
    }

    @Test func usdcZero() {
        let w = Wei(bigUInt: BigUInt(0))
        #expect(w.usdcFormatted == "0")
    }

    @Test func customDecimals() {
        let w = Wei(bigUInt: BigUInt(10).power(18) + BigUInt(10).power(14))
        #expect(w.formatted(decimals: 18, precision: 6) == "1.000100")
    }

    @Test func hexWithoutPrefix() {
        let w = Wei(hex: "de0b6b3a7640000")
        #expect(w.ethFormatted == "1")
    }

    @Test func emptyHex() {
        let w = Wei(hex: "0x")
        #expect(w.isZero)
    }
}
