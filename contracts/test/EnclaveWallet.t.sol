// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/EnclaveWalletFactory.sol";
import "../src/EnclaveWallet.sol";
import "@account-abstraction/contracts/interfaces/IEntryPoint.sol";

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "not approved");
        require(balanceOf[from] >= amount, "insufficient");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract EnclaveWalletTest is Test {
    EnclaveWalletFactory factory;
    address entryPointAddr;
    MockERC20 token;

    uint256 constant PUB_X = 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef;
    uint256 constant PUB_Y = 0xfedcba0987654321fedcba0987654321fedcba0987654321fedcba0987654321;

    function setUp() public {
        entryPointAddr = makeAddr("entryPoint");
        factory = new EnclaveWalletFactory(IEntryPoint(entryPointAddr));
        token = new MockERC20();
    }

    // ---- Factory Tests ----

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

    // ---- EIP-1271 Tests ----

    function test_isValidSignature_returns_magic_for_invalid() public {
        EnclaveWallet wallet = factory.createAccount(PUB_X, PUB_Y, 0);
        bytes32 hash = keccak256("test message");
        bytes memory sig = abi.encode(uint256(1), uint256(2));
        // P256 precompile at address(0x100) doesn't exist in test, so it fails
        bytes4 result = wallet.isValidSignature(hash, sig);
        assertEq(result, bytes4(0xffffffff));
    }

    function test_isValidSignature_reverts_bad_length() public {
        EnclaveWallet wallet = factory.createAccount(PUB_X, PUB_Y, 0);
        bytes32 hash = keccak256("test");
        vm.expectRevert("Invalid signature length");
        wallet.isValidSignature(hash, hex"0102030405");
    }

    // ---- Spending Limit Tests ----

    function test_setDailyLimit_only_self() public {
        EnclaveWallet wallet = factory.createAccount(PUB_X, PUB_Y, 0);
        vm.expectRevert("Only self");
        wallet.setDailyLimit(address(0), 1 ether);
    }

    function test_setDailyLimit_via_execute() public {
        EnclaveWallet wallet = factory.createAccount(PUB_X, PUB_Y, 0);
        vm.deal(address(wallet), 10 ether);

        bytes memory calldata_ = abi.encodeWithSelector(
            EnclaveWallet.setDailyLimit.selector,
            address(0),
            1 ether
        );

        vm.prank(entryPointAddr);
        wallet.execute(address(wallet), 0, calldata_);

        assertEq(wallet.dailyLimit(address(0)), 1 ether);
    }

    function test_spending_limit_eth_enforced() public {
        EnclaveWallet wallet = factory.createAccount(PUB_X, PUB_Y, 0);
        vm.deal(address(wallet), 10 ether);

        // Set 1 ETH daily limit
        vm.prank(entryPointAddr);
        wallet.execute(
            address(wallet), 0,
            abi.encodeWithSelector(EnclaveWallet.setDailyLimit.selector, address(0), 1 ether)
        );

        // First send: 0.5 ETH - should succeed
        vm.prank(entryPointAddr);
        wallet.execute(makeAddr("recipient"), 0.5 ether, "");

        // Second send: 0.6 ETH - should exceed limit
        vm.prank(entryPointAddr);
        vm.expectRevert("Daily limit exceeded");
        wallet.execute(makeAddr("recipient"), 0.6 ether, "");
    }

    function test_spending_limit_erc20_enforced() public {
        EnclaveWallet wallet = factory.createAccount(PUB_X, PUB_Y, 0);
        token.mint(address(wallet), 1000e6);

        // Set 100 token daily limit
        vm.prank(entryPointAddr);
        wallet.execute(
            address(wallet), 0,
            abi.encodeWithSelector(EnclaveWallet.setDailyLimit.selector, address(token), 100e6)
        );

        // transfer 50 tokens - should succeed
        bytes memory transferCall = abi.encodeWithSelector(
            MockERC20.transfer.selector,
            makeAddr("recipient"),
            50e6
        );
        vm.prank(entryPointAddr);
        wallet.execute(address(token), 0, transferCall);

        // transfer 60 more tokens - should exceed limit
        bytes memory transferCall2 = abi.encodeWithSelector(
            MockERC20.transfer.selector,
            makeAddr("recipient"),
            60e6
        );
        vm.prank(entryPointAddr);
        vm.expectRevert("Daily limit exceeded");
        wallet.execute(address(token), 0, transferCall2);
    }

    function test_spending_limit_resets_daily() public {
        EnclaveWallet wallet = factory.createAccount(PUB_X, PUB_Y, 0);
        vm.deal(address(wallet), 10 ether);

        vm.prank(entryPointAddr);
        wallet.execute(
            address(wallet), 0,
            abi.encodeWithSelector(EnclaveWallet.setDailyLimit.selector, address(0), 1 ether)
        );

        vm.prank(entryPointAddr);
        wallet.execute(makeAddr("recipient"), 1 ether, "");

        // Advance 1 day
        vm.warp(block.timestamp + 1 days);

        // Should work again after day boundary
        vm.prank(entryPointAddr);
        wallet.execute(makeAddr("recipient"), 1 ether, "");
    }

    function test_no_limit_means_unlimited() public {
        EnclaveWallet wallet = factory.createAccount(PUB_X, PUB_Y, 0);
        vm.deal(address(wallet), 100 ether);

        // No limit set - should allow any amount
        vm.prank(entryPointAddr);
        wallet.execute(makeAddr("recipient"), 50 ether, "");
    }

    function test_approve_spending_limit() public {
        EnclaveWallet wallet = factory.createAccount(PUB_X, PUB_Y, 0);

        vm.prank(entryPointAddr);
        wallet.execute(
            address(wallet), 0,
            abi.encodeWithSelector(EnclaveWallet.setDailyLimit.selector, address(token), 100e6)
        );

        // Approve 200 tokens - should exceed daily limit
        bytes memory approveCall = abi.encodeWithSelector(
            MockERC20.approve.selector,
            makeAddr("spender"),
            200e6
        );
        vm.prank(entryPointAddr);
        vm.expectRevert("Daily limit exceeded");
        wallet.execute(address(token), 0, approveCall);
    }
}
