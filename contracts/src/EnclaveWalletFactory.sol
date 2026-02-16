// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import "./EnclaveWallet.sol";

contract EnclaveWalletFactory {
    IEntryPoint public immutable entryPoint;

    constructor(IEntryPoint _entryPoint) {
        entryPoint = _entryPoint;
    }

    function createAccount(uint256 pubKeyX, uint256 pubKeyY, uint256 salt)
        external
        returns (EnclaveWallet)
    {
        address predicted = getAddress(pubKeyX, pubKeyY, salt);
        if (predicted.code.length > 0) {
            return EnclaveWallet(payable(predicted));
        }
        return new EnclaveWallet{salt: bytes32(salt)}(entryPoint, pubKeyX, pubKeyY);
    }

    function getAddress(uint256 pubKeyX, uint256 pubKeyY, uint256 salt)
        public
        view
        returns (address)
    {
        bytes memory bytecode = abi.encodePacked(
            type(EnclaveWallet).creationCode,
            abi.encode(entryPoint, pubKeyX, pubKeyY)
        );
        bytes32 hash = keccak256(
            abi.encodePacked(bytes1(0xff), address(this), bytes32(salt), keccak256(bytecode))
        );
        return address(uint160(uint256(hash)));
    }
}
