import Testing
import Foundation
@testable import EnclaveCLI

@Suite struct StringHexTests {
    // MARK: - stripHexPrefix

    @Test func stripWithPrefix() {
        #expect("0xabcd".stripHexPrefix() == "abcd")
    }

    @Test func stripWithoutPrefix() {
        #expect("abcd".stripHexPrefix() == "abcd")
    }

    @Test func stripEmpty() {
        #expect("".stripHexPrefix() == "")
    }

    @Test func stripBareZeroX() {
        #expect("0x".stripHexPrefix() == "")
    }

    // MARK: - leftPadded

    @Test func leftPadShortHex() {
        #expect("0xff".leftPadded(toLength: 8) == "000000ff")
    }

    @Test func leftPadExactLength() {
        #expect("0xabcdef12".leftPadded(toLength: 8) == "abcdef12")
    }

    @Test func leftPadAlreadyLonger() {
        #expect("0xabcdef1234".leftPadded(toLength: 8) == "abcdef1234")
    }

    @Test func leftPadNoPrefix() {
        #expect("ff".leftPadded(toLength: 4) == "00ff")
    }

    // MARK: - hexToData

    @Test func hexToDataValid() {
        let data = "0xdeadbeef".hexToData()
        #expect(data == Data([0xde, 0xad, 0xbe, 0xef]))
    }

    @Test func hexToDataNoPrefix() {
        let data = "cafebabe".hexToData()
        #expect(data == Data([0xca, 0xfe, 0xba, 0xbe]))
    }

    @Test func hexToDataEmpty() {
        let data = "0x".hexToData()
        #expect(data == Data())
    }

    @Test func hexToDataOddLength() {
        let data = "0xabc".hexToData()
        #expect(data == Data([0xab]))
    }

    @Test func hexToDataInvalidChars() {
        let data = "0xzzzz".hexToData()
        #expect(data == nil)
    }
}
