// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "../src/EnclaveWalletFactory.sol";

contract DeployFactory is Script {
    // Canonical ERC-4337 EntryPoint v0.7
    address constant ENTRYPOINT = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        EnclaveWalletFactory factory = new EnclaveWalletFactory(IEntryPoint(ENTRYPOINT));
        console.log("Factory deployed at:", address(factory));

        vm.stopBroadcast();
    }
}
