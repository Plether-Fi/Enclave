// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";

contract HashDebug is Test {
    IEntryPoint entryPoint = IEntryPoint(0x0000000071727De22E5E9d8BAf0edAc6f37da032);
    address constant DAIMO_P256 = 0xc2b78104907F722DABAc4C69f826a522B2754De4;

    function test_computeHashAndVerifySig() public {
        PackedUserOperation memory op;
        op.sender = 0xB24687C2c3D8BdAaF6A2A44eEDdB905018B5932E;
        op.nonce = 0;
        op.initCode = abi.encodePacked(
            address(0x8F21285D61A401aca4DB69e042f991Ac3bAEe602),
            hex"4c1ed7f556c99709fa9d5c65ec12b332a70e25e248593b8de6b188fe054a111a026c6d01745af3d8cfa403712cb3750dacb7c4ca5d37922500ce61b5fd842e862b9f3a170000000000000000000000000000000000000000000000000000000000000005"
        );
        op.callData = hex"b61d27f6000000000000000000000000B24687C2c3D8BdAaF6A2A44eEDdB905018B5932E00000000000000000000000000000000000000000000000000005af3107a400000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000000";
        op.accountGasLimits = bytes32(uint256(uint128(0x1e8480)) << 128 | uint128(0x30d40));
        op.preVerificationGas = 0x186a0;
        op.gasFees = bytes32(uint256(uint128(0xf4240)) << 128 | uint128(0x1738ec0));
        op.paymasterAndData = "";
        op.signature = "";

        bytes32 userOpHash = entryPoint.getUserOpHash(op);
        emit log_named_bytes32("EntryPoint userOpHash", userOpHash);

        bytes32 initCodeHash = keccak256(op.initCode);
        bytes32 callDataHash = keccak256(op.callData);
        bytes32 paymasterHash = keccak256(op.paymasterAndData);

        // Format A: WITH typehash (newer library code)
        bytes32 typehash = keccak256("PackedUserOperation(address sender,uint256 nonce,bytes initCode,bytes callData,bytes32 accountGasLimits,uint256 preVerificationGas,bytes32 gasFees,bytes paymasterAndData)");
        bytes32 structHashWithType = keccak256(abi.encode(
            typehash, op.sender, op.nonce, initCodeHash, callDataHash,
            op.accountGasLimits, op.preVerificationGas, op.gasFees, paymasterHash
        ));

        // Format B: WITHOUT typehash (original v0.7 deployed code)
        bytes32 structHashNoType = keccak256(abi.encode(
            op.sender, op.nonce, initCodeHash, callDataHash,
            op.accountGasLimits, op.preVerificationGas, op.gasFees, paymasterHash
        ));

        // Outer hash format 1: simple abi.encode (original v0.7)
        bytes32 simpleWithType = keccak256(abi.encode(structHashWithType, address(entryPoint), block.chainid));
        bytes32 simpleNoType = keccak256(abi.encode(structHashNoType, address(entryPoint), block.chainid));

        // Outer hash format 2: EIP-712
        bytes32 domainSep = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("ERC4337"), keccak256("1"), block.chainid, address(entryPoint)
        ));
        bytes32 eip712WithType = keccak256(abi.encodePacked(hex"1901", domainSep, structHashWithType));
        bytes32 eip712NoType = keccak256(abi.encodePacked(hex"1901", domainSep, structHashNoType));

        emit log_named_bytes32("A: simple+typehash ", simpleWithType);
        emit log_named_bytes32("B: simple-typehash ", simpleNoType);
        emit log_named_bytes32("C: eip712+typehash ", eip712WithType);
        emit log_named_bytes32("D: eip712-typehash ", eip712NoType);

        // Verify signature against the correct hash
        bytes32 sha256Hash = sha256(abi.encodePacked(userOpHash));
        uint256 r = 0xbab15dcae22794867f60d0948af1f9297388d3dc48b4b6727687c11ea520c54d;
        uint256 s = 0x5e061ec36fbaefd86c09d4c5739cb2bec677d4a2b1aa215908c9b609374d079f;
        uint256 pubX = 0x56c99709fa9d5c65ec12b332a70e25e248593b8de6b188fe054a111a026c6d01;
        uint256 pubY = 0x745af3d8cfa403712cb3750dacb7c4ca5d37922500ce61b5fd842e862b9f3a17;

        bytes memory payload = abi.encode(sha256Hash, r, s, pubX, pubY);
        (bool success, bytes memory ret) = DAIMO_P256.staticcall(payload);
        uint256 result = (success && ret.length == 32) ? abi.decode(ret, (uint256)) : 0;
        emit log_named_uint("P256 verify result", result);
    }
}
