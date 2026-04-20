// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/BiodiversityRegistry.sol";

contract Deploy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        BiodiversityRegistry registry = new BiodiversityRegistry();
        vm.stopBroadcast();
        console.log("BiodiversityRegistry deployed:", address(registry));
    }
}
