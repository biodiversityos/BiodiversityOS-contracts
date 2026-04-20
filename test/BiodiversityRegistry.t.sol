// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/BiodiversityRegistry.sol";

contract BiodiversityRegistryTest is Test {
    BiodiversityRegistry public registry;
    address owner = address(this);
    address reporter = address(0xBEEF);
    address stranger = address(0xDEAD);

    event RecordCreated(
        uint256 indexed recordId, address indexed reporter,
        int256 latitude, int256 longitude, string species, uint16 count,
        string behavior, uint256 observedAt, string mediaUrl, string comment
    );
    event RecordUpdated(
        uint256 indexed recordId, address indexed reporter,
        int256 latitude, int256 longitude, string species, uint16 count,
        string behavior, uint256 observedAt, string mediaUrl, string comment
    );
    event WhitelistUpdated(address indexed addr, bool status);

    function setUp() public {
        registry = new BiodiversityRegistry();
        registry.setWhitelist(reporter, true);
    }

    function test_InitialState() public view {
        assertEq(registry.owner(), owner);
        assertEq(registry.nextRecordId(), 1);
    }

    function test_SubmitRecord_EmitsAndIncrementsId() public {
        vm.prank(reporter);
        vm.expectEmit(true, true, false, true);
        emit RecordCreated(
            1, reporter, 20123456, -87123456, "WHALE_SHARK", 3,
            "FEEDING", 1700000000, "ipfs://cid", "comment"
        );
        uint256 id = registry.submitRecord(
            20123456, -87123456, "WHALE_SHARK", 3,
            "FEEDING", 1700000000, "ipfs://cid", "comment"
        );
        assertEq(id, 1);
        assertEq(registry.nextRecordId(), 2);
    }

    function test_SubmitRecord_IdsAutoIncrement() public {
        vm.startPrank(reporter);
        uint256 id1 = registry.submitRecord(0, 0, "UNKNOWN", 1, "UNKNOWN", 0, "", "");
        uint256 id2 = registry.submitRecord(0, 0, "UNKNOWN", 1, "UNKNOWN", 0, "", "");
        vm.stopPrank();
        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(registry.nextRecordId(), 3);
    }

    function test_UpdateRecord_ValidId_EmitsEvent() public {
        vm.prank(reporter);
        registry.submitRecord(0, 0, "UNKNOWN", 1, "UNKNOWN", 0, "", "");

        vm.prank(reporter);
        vm.expectEmit(true, true, false, true);
        emit RecordUpdated(
            1, reporter, 10000000, 20000000, "BULL_SHARK", 2,
            "HUNTING", 1700000001, "ipfs://new", "updated"
        );
        registry.updateRecord(
            1, 10000000, 20000000, "BULL_SHARK", 2,
            "HUNTING", 1700000001, "ipfs://new", "updated"
        );
    }

    function test_UpdateRecord_InvalidId_Reverts() public {
        vm.prank(reporter);
        vm.expectRevert("Invalid record ID");
        registry.updateRecord(0, 0, 0, "UNKNOWN", 1, "UNKNOWN", 0, "", "");

        vm.prank(reporter);
        vm.expectRevert("Invalid record ID");
        registry.updateRecord(99, 0, 0, "UNKNOWN", 1, "UNKNOWN", 0, "", "");
    }

    function test_UpdateRecord_IdEqualToNextRecordId_Reverts() public {
        // nextRecordId = 1, so recordId=1 is NOT yet valid (must be < 1)
        vm.prank(reporter);
        vm.expectRevert("Invalid record ID");
        registry.updateRecord(1, 0, 0, "UNKNOWN", 1, "UNKNOWN", 0, "", "");
    }

    function test_SubmitRecord_NotWhitelisted_Reverts() public {
        vm.prank(stranger);
        vm.expectRevert("Not whitelisted");
        registry.submitRecord(0, 0, "UNKNOWN", 1, "UNKNOWN", 0, "", "");
    }

    function test_UpdateRecord_NotWhitelisted_Reverts() public {
        vm.prank(reporter);
        registry.submitRecord(0, 0, "UNKNOWN", 1, "UNKNOWN", 0, "", "");

        vm.prank(stranger);
        vm.expectRevert("Not whitelisted");
        registry.updateRecord(1, 0, 0, "UNKNOWN", 1, "UNKNOWN", 0, "", "");
    }

    function test_SetWhitelist_AddAndRemove() public {
        assertFalse(registry.whitelist(stranger));
        registry.setWhitelist(stranger, true);
        assertTrue(registry.whitelist(stranger));

        vm.expectEmit(true, false, false, true);
        emit WhitelistUpdated(stranger, false);
        registry.setWhitelist(stranger, false);
        assertFalse(registry.whitelist(stranger));
    }

    function test_SetWhitelist_NotOwner_Reverts() public {
        vm.prank(stranger);
        vm.expectRevert("Not owner");
        registry.setWhitelist(stranger, true);
    }
}
