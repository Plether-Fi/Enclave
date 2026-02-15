// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@account-abstraction/contracts/core/BaseAccount.sol";
import "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";

/// @title macOS Secure Enclave Wallet (V1 Proof of Concept)
contract EnclaveWalletV1 is BaseAccount {
    // The globally trusted ERC-4337 EntryPoint contract
    IEntryPoint private immutable _entryPoint;

    // The Mac's P-256 Public Key (X and Y coordinates)
    uint256 public immutable pubKeyX;
    uint256 public immutable pubKeyY;

    // The RIP-7212 Precompile Address for cheap P-256 verification (Active on Base/OP/Arbitrum)
    address constant P256_VERIFIER = 0x0000000000000000000000000000000000000100;

    constructor(IEntryPoint entryPointAddress, uint256 _x, uint256 _y) {
        _entryPoint = entryPointAddress;
        pubKeyX = _x;
        pubKeyY = _y;
    }

    /**
     * @dev Required by BaseAccount: Identifies the trusted EntryPoint.
     */
    function entryPoint() public view virtual override returns (IEntryPoint) {
        return _entryPoint;
    }

    /**
     * @dev Core ERC-4337 Validation Engine.
     * The EntryPoint calls this. If the Mac's Touch ID signature is valid, we return 0.
     */
    function _validateSignature(PackedUserOperation calldata userOp, bytes32 userOpHash)
        internal view virtual override returns (uint256 validationData)
    {
        // 1. Extract the r and s values from the Mac's raw signature.
        // We assume the Swift app passed exactly 64 bytes via abi.encode(r, s)
        require(userOp.signature.length == 64, "Invalid signature length");
        (uint256 r, uint256 s) = abi.decode(userOp.signature, (uint256, uint256));

        // 2. Format the payload for the L2 RIP-7212 Precompile.
        // Expected layout: hash (32), r (32), s (32), x (32), y (32)
        bytes memory payload = abi.encode(userOpHash, r, s, pubKeyX, pubKeyY);

        // 3. Execute the staticcall to the precompile
        (bool success, bytes memory ret) = P256_VERIFIER.staticcall(payload);

        // 4. Verify the result (The precompile returns exactly 1 if valid)
        bool isValid = success && ret.length == 32 && abi.decode(ret, (uint256)) == 1;

        // 5. Return 0 for Success, 1 for SIG_VALIDATION_FAILED (ERC-4337 standard)
        return isValid ? 0 : 1; 
    }

    /**
     * @dev The execution function (e.g., sending USDC or calling Uniswap).
     * Can ONLY be triggered by the EntryPoint after it successfully validates the signature above.
     */
    function execute(address dest, uint256 value, bytes calldata func) external {
        require(msg.sender == address(entryPoint()), "Only EntryPoint can execute");
        
        (bool success, bytes memory result) = dest.call{value: value}(func);
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result)) // Bubble up the revert reason
            }
        }
    }

    // Allow the wallet to receive native ETH natively
    receive() external payable {}
}
