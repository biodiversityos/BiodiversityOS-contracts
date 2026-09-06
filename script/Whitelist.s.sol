// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/BiodiversityRegistry.sol";

/// @notice Grants or revokes field reporters in one transaction.
/// @dev    REGISTRY=0x.. REPORTERS=0xa,0xb GRANT=true forge script script/Whitelist.s.sol \
///           --rpc-url celo_sepolia --broadcast
contract Whitelist is Script {
    function run() external {
        uint256 key = vm.envUint("PRIVATE_KEY");
        address registryAddr = vm.envAddress("REGISTRY");
        address[] memory reporters = vm.envAddress("REPORTERS", ",");
        bool grant = vm.envOr("GRANT", true);

        require(reporters.length > 0, "REPORTERS is empty");

        vm.startBroadcast(key);
        BiodiversityRegistry(registryAddr).setWhitelistBatch(reporters, grant);
        vm.stopBroadcast();

        console.log(grant ? "Granted:" : "Revoked:", reporters.length);
        for (uint256 i = 0; i < reporters.length; i++) {
            console.log(" ", reporters[i]);
        }
    }
}
