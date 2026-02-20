import Testing
@testable import EnclaveCLI

@Suite struct NetworkConfigTests {
    @Test func arbitrumSepoliaChainId() {
        #expect(Network.arbitrumSepolia.chainId == 421614)
    }

    @Test func arbitrumOneChainId() {
        #expect(Network.arbitrumOne.chainId == 42161)
    }

    @Test func anvilChainId() {
        #expect(Network.anvil.chainId == 42161)
    }

    @Test func entryPointAddress() {
        #expect(Config.entryPointAddress == "0x0000000071727De22E5E9d8BAf0edAc6f37da032")
    }

    @Test func usdcAddressesDiffer() {
        #expect(Network.arbitrumSepolia.usdcAddress != Network.arbitrumOne.usdcAddress)
    }

    @Test func anvilIsLocal() {
        #expect(Network.anvil.isLocal)
        #expect(!Network.arbitrumOne.isLocal)
        #expect(!Network.arbitrumSepolia.isLocal)
    }

    @Test func allCasesContainsAll() {
        #expect(Network.allCases.count == 3)
    }
}
