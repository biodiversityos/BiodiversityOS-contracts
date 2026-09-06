// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/BiodiversityRegistry.sol";

/// @notice Deploys a fresh registry. The deployer becomes owner and is
///         whitelisted by the constructor, so it can seed data immediately.
contract Deploy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        BiodiversityRegistry registry = new BiodiversityRegistry();
        vm.stopBroadcast();

        console.log("BiodiversityRegistry deployed:", address(registry));
        console.log("Owner:", registry.owner());
    }
}
