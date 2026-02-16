// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/EnclaveWalletFactory.sol";
import "../src/EnclaveWallet.sol";
import "@account-abstraction/contracts/interfaces/IEntryPoint.sol";

contract EnclaveWalletTest is Test {
    EnclaveWalletFactory factory;
    IEntryPoint entryPoint;

    uint256 constant PUB_X = 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef;
    uint256 constant PUB_Y = 0xfedcba0987654321fedcba0987654321fedcba0987654321fedcba0987654321;

    function setUp() public {
        entryPoint = IEntryPoint(makeAddr("entryPoint"));
        factory = new EnclaveWalletFactory(entryPoint);
    }

    function test_getAddress_deterministic() public view {
        address addr1 = factory.getAddress(PUB_X, PUB_Y, 0);
        address addr2 = factory.getAddress(PUB_X, PUB_Y, 0);
        assertEq(addr1, addr2);
    }

    function test_getAddress_differs_by_salt() public view {
        address addr0 = factory.getAddress(PUB_X, PUB_Y, 0);
        address addr1 = factory.getAddress(PUB_X, PUB_Y, 1);
        assertTrue(addr0 != addr1);
    }

    function test_getAddress_differs_by_key() public view {
        address addr1 = factory.getAddress(PUB_X, PUB_Y, 0);
        address addr2 = factory.getAddress(PUB_Y, PUB_X, 0);
        assertTrue(addr1 != addr2);
    }

    function test_createAccount_deploys() public {
        address predicted = factory.getAddress(PUB_X, PUB_Y, 0);
        assertEq(predicted.code.length, 0);

        EnclaveWallet wallet = factory.createAccount(PUB_X, PUB_Y, 0);
        assertEq(address(wallet), predicted);
        assertTrue(predicted.code.length > 0);
    }

    function test_createAccount_idempotent() public {
        EnclaveWallet wallet1 = factory.createAccount(PUB_X, PUB_Y, 0);
        EnclaveWallet wallet2 = factory.createAccount(PUB_X, PUB_Y, 0);
        assertEq(address(wallet1), address(wallet2));
    }

    function test_wallet_stores_pubkey() public {
        EnclaveWallet wallet = factory.createAccount(PUB_X, PUB_Y, 0);
        assertEq(wallet.pubKeyX(), PUB_X);
        assertEq(wallet.pubKeyY(), PUB_Y);
    }

    function test_wallet_receives_eth() public {
        EnclaveWallet wallet = factory.createAccount(PUB_X, PUB_Y, 0);
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(wallet).call{value: 0.5 ether}("");
        assertTrue(ok);
        assertEq(address(wallet).balance, 0.5 ether);
    }

    function test_execute_only_entrypoint() public {
        EnclaveWallet wallet = factory.createAccount(PUB_X, PUB_Y, 0);
        vm.expectRevert();
        wallet.execute(address(0), 0, "");
    }
}
