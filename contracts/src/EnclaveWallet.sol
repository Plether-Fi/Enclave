// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@account-abstraction/contracts/core/BaseAccount.sol";
import "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";

contract EnclaveWallet is BaseAccount {
    IEntryPoint private immutable _entryPoint;
    uint256 public immutable pubKeyX;
    uint256 public immutable pubKeyY;

    address constant P256_VERIFIER = 0x0000000000000000000000000000000000000100;

    constructor(IEntryPoint entryPointAddress, uint256 _x, uint256 _y) {
        _entryPoint = entryPointAddress;
        pubKeyX = _x;
        pubKeyY = _y;
    }

    function entryPoint() public view virtual override returns (IEntryPoint) {
        return _entryPoint;
    }

    function _validateSignature(PackedUserOperation calldata userOp, bytes32 userOpHash)
        internal view virtual override returns (uint256 validationData)
    {
        require(userOp.signature.length == 64, "Invalid signature length");
        (uint256 r, uint256 s) = abi.decode(userOp.signature, (uint256, uint256));

        bytes memory payload = abi.encode(userOpHash, r, s, pubKeyX, pubKeyY);
        (bool success, bytes memory ret) = P256_VERIFIER.staticcall(payload);
        bool isValid = success && ret.length == 32 && abi.decode(ret, (uint256)) == 1;

        return isValid ? 0 : 1;
    }

    receive() external payable {}
}
