import Testing
import BigInt
@testable import EnclaveCLI

@Suite struct AmountParsingTests {
    // MARK: - parseETHToWei

    @Test func ethWholeNumber() {
        #expect(CLI.parseETHToWei("1") == BigUInt(10).power(18))
    }

    @Test func ethFractional() {
        #expect(CLI.parseETHToWei("0.1") == BigUInt(10).power(17))
    }

    @Test func ethSmallFraction() {
        #expect(CLI.parseETHToWei("0.0001") == BigUInt(10).power(14))
    }

    @Test func ethZero() {
        #expect(CLI.parseETHToWei("0") == BigUInt(0))
    }

    @Test func ethMaxPrecision() {
        #expect(CLI.parseETHToWei("0.000000000000000001") == BigUInt(1))
    }

    @Test func ethExcessPrecisionTruncated() {
        let result = CLI.parseETHToWei("0.0000000000000000019")
        #expect(result == BigUInt(1))
    }

    @Test func ethLargeAmount() {
        #expect(CLI.parseETHToWei("1000") == BigUInt(1000) * BigUInt(10).power(18))
    }

    @Test func ethInvalidReturnsZero() {
        #expect(CLI.parseETHToWei("abc") == BigUInt(0))
    }

    // MARK: - parseUSDCToBase

    @Test func usdcWholeNumber() {
        #expect(CLI.parseUSDCToBase("100") == BigUInt(100_000_000))
    }

    @Test func usdcFractional() {
        #expect(CLI.parseUSDCToBase("1.50") == BigUInt(1_500_000))
    }

    @Test func usdcMaxPrecision() {
        #expect(CLI.parseUSDCToBase("0.000001") == BigUInt(1))
    }

    @Test func usdcExcessPrecisionTruncated() {
        let result = CLI.parseUSDCToBase("1.1234567")
        #expect(result == BigUInt(1_123_456))
    }

    @Test func usdcZero() {
        #expect(CLI.parseUSDCToBase("0") == BigUInt(0))
    }
}
