// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/BiodiversityRegistry.sol";

contract BiodiversityRegistryTest is Test {
    BiodiversityRegistry public registry;
    address owner = address(this);
    address reporter = address(0xBEEF);
    address reporter2 = address(0xCAFE);
    address stranger = address(0xDEAD);

    event RecordCreated(uint256 indexed recordId, address indexed reporter, BiodiversityRegistry.SightingInput sighting);
    event RecordUpdated(uint256 indexed recordId, address indexed reporter, BiodiversityRegistry.SightingInput sighting);
    event RecordVoided(uint256 indexed recordId, address indexed voidedBy);
    event SeedReporterSet(address indexed reporter);
    event WhitelistUpdated(address indexed addr, bool status);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function setUp() public {
        registry = new BiodiversityRegistry();
        registry.setWhitelist(reporter, true);
    }

    /// @dev A minimal valid sighting; individual tests override what they care about.
    function _input() internal pure returns (BiodiversityRegistry.SightingInput memory) {
        return BiodiversityRegistry.SightingInput({
            latitude: 0, longitude: 0, species: "unknown", count: 1,
            behavior: "unknown", observedAt: 0, mediaUrl: "", comment: "",
            siteName: "", depthFt: 0, sizeClass: ""
        });
    }

    function _submit(address who) internal returns (uint256) {
        vm.prank(who);
        return registry.submitRecord(_input());
    }

    // ── Deployment ───────────────────────────────────────────────────────────

    function test_InitialState() public view {
        assertEq(registry.owner(), owner);
        assertEq(registry.nextRecordId(), 1);
    }

    function test_Constructor_WhitelistsDeployer() public view {
        assertTrue(registry.whitelist(owner));
    }

    // ── Whitelist ────────────────────────────────────────────────────────────

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

    function test_SetWhitelistBatch_GrantsAll() public {
        address[] memory addrs = new address[](3);
        addrs[0] = reporter2; addrs[1] = stranger; addrs[2] = address(0x1234);
        registry.setWhitelistBatch(addrs, true);
        assertTrue(registry.whitelist(reporter2));
        assertTrue(registry.whitelist(stranger));
        assertTrue(registry.whitelist(address(0x1234)));
    }

    function test_SetWhitelistBatch_RevokesAll() public {
        address[] memory addrs = new address[](2);
        addrs[0] = reporter; addrs[1] = reporter2;
        registry.setWhitelistBatch(addrs, true);
        registry.setWhitelistBatch(addrs, false);
        assertFalse(registry.whitelist(reporter));
        assertFalse(registry.whitelist(reporter2));
    }

    function test_SetWhitelistBatch_NotOwner_Reverts() public {
        address[] memory addrs = new address[](1);
        addrs[0] = stranger;
        vm.prank(stranger);
        vm.expectRevert("Not owner");
        registry.setWhitelistBatch(addrs, true);
    }

    function test_SetWhitelistBatch_EmptyArray_NoOp() public {
        address[] memory addrs = new address[](0);
        registry.setWhitelistBatch(addrs, true);
        assertEq(registry.nextRecordId(), 1);
    }

    // ── Ownership ────────────────────────────────────────────────────────────

    function test_TransferOwnership() public {
        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferred(owner, reporter);
        registry.transferOwnership(reporter);
        assertEq(registry.owner(), reporter);
    }

    function test_TransferOwnership_NewOwnerCanAdminister() public {
        registry.transferOwnership(reporter);
        vm.prank(reporter);
        registry.setWhitelist(stranger, true);
        assertTrue(registry.whitelist(stranger));
    }

    function test_TransferOwnership_OldOwnerLosesRights() public {
        registry.transferOwnership(reporter);
        vm.expectRevert("Not owner");
        registry.setWhitelist(stranger, true);
    }

    function test_TransferOwnership_ZeroAddress_Reverts() public {
        vm.expectRevert("Zero address");
        registry.transferOwnership(address(0));
    }

    function test_TransferOwnership_NotOwner_Reverts() public {
        vm.prank(stranger);
        vm.expectRevert("Not owner");
        registry.transferOwnership(stranger);
    }

    // ── Submit ───────────────────────────────────────────────────────────────

    function test_SubmitRecord_EmitsFullPayload() public {
        BiodiversityRegistry.SightingInput memory s = _input();
        s.latitude = 20370277; s.longitude = -87028333;
        s.species = "nurse_shark"; s.count = 3; s.behavior = "resting";
        s.observedAt = 1700000000; s.mediaUrl = "ipfs://cid"; s.comment = "comment";
        s.siteName = "PASO DEL CEDRAL"; s.depthFt = 60; s.sizeClass = "mediano";

        vm.prank(reporter);
        vm.expectEmit(true, true, false, true);
        emit RecordCreated(1, reporter, s);
        uint256 id = registry.submitRecord(s);
        assertEq(id, 1);
        assertEq(registry.nextRecordId(), 2);
    }

    function test_SubmitRecord_RecordsReporter() public {
        uint256 id = _submit(reporter);
        assertEq(registry.recordReporter(id), reporter);
    }

    function test_SubmitRecord_IdsAutoIncrement() public {
        assertEq(_submit(reporter), 1);
        assertEq(_submit(reporter), 2);
        assertEq(registry.nextRecordId(), 3);
    }

    function test_SubmitRecord_NotWhitelisted_Reverts() public {
        vm.prank(stranger);
        vm.expectRevert("Not whitelisted");
        registry.submitRecord(_input());
    }

    function test_SubmitRecord_UnknownDateStaysZero() public {
        // ID 743 in the field database has a genuinely unknown date.
        BiodiversityRegistry.SightingInput memory s = _input();
        s.observedAt = 0;
        vm.prank(reporter);
        vm.expectEmit(true, true, false, true);
        emit RecordCreated(1, reporter, s);
        registry.submitRecord(s);
    }

    // ── Batch submit ─────────────────────────────────────────────────────────

    function test_SubmitRecordBatch_CreatesAll() public {
        BiodiversityRegistry.SightingInput[] memory batch =
            new BiodiversityRegistry.SightingInput[](3);
        for (uint256 i = 0; i < 3; i++) {
            batch[i] = _input();
            batch[i].count = uint16(i + 1);
        }

        vm.prank(reporter);
        (uint256 first, uint256 last) = registry.submitRecordBatch(batch);

        assertEq(first, 1);
        assertEq(last, 3);
        assertEq(registry.nextRecordId(), 4);
        assertEq(registry.recordReporter(1), reporter);
        assertEq(registry.recordReporter(3), reporter);
    }

    function test_SubmitRecordBatch_ContinuesFromExistingIds() public {
        _submit(reporter);
        BiodiversityRegistry.SightingInput[] memory batch =
            new BiodiversityRegistry.SightingInput[](2);
        batch[0] = _input(); batch[1] = _input();

        vm.prank(reporter);
        (uint256 first, uint256 last) = registry.submitRecordBatch(batch);
        assertEq(first, 2);
        assertEq(last, 3);
    }

    function test_SubmitRecordBatch_Empty_Reverts() public {
        BiodiversityRegistry.SightingInput[] memory batch =
            new BiodiversityRegistry.SightingInput[](0);
        vm.prank(reporter);
        vm.expectRevert("Empty batch");
        registry.submitRecordBatch(batch);
    }

    function test_SubmitRecordBatch_NotWhitelisted_Reverts() public {
        BiodiversityRegistry.SightingInput[] memory batch =
            new BiodiversityRegistry.SightingInput[](1);
        batch[0] = _input();
        vm.prank(stranger);
        vm.expectRevert("Not whitelisted");
        registry.submitRecordBatch(batch);
    }

    function test_SubmitRecordBatch_EmitsEveryRecord() public {
        BiodiversityRegistry.SightingInput[] memory batch =
            new BiodiversityRegistry.SightingInput[](2);
        batch[0] = _input(); batch[0].species = "bull_shark";
        batch[1] = _input(); batch[1].species = "tiger_shark";

        vm.prank(reporter);
        vm.recordLogs();
        registry.submitRecordBatch(batch);
        assertEq(vm.getRecordedLogs().length, 2);
    }

    // ── Update ───────────────────────────────────────────────────────────────

    function test_UpdateRecord_ByReporter_EmitsEvent() public {
        _submit(reporter);
        BiodiversityRegistry.SightingInput memory s = _input();
        s.species = "bull_shark"; s.count = 2; s.behavior = "hunting";

        vm.prank(reporter);
        vm.expectEmit(true, true, false, true);
        emit RecordUpdated(1, reporter, s);
        registry.updateRecord(1, s);
    }

    function test_UpdateRecord_ByOwner_Allowed() public {
        _submit(reporter);
        // Owner corrects on the reporter's behalf; event still credits reporter.
        vm.expectEmit(true, true, false, false);
        emit RecordUpdated(1, reporter, _input());
        registry.updateRecord(1, _input());
    }

    /// @dev The v1 bug: any whitelisted address could rewrite anyone's record.
    function test_UpdateRecord_ByOtherWhitelisted_Reverts() public {
        _submit(reporter);
        registry.setWhitelist(reporter2, true);
        vm.prank(reporter2);
        vm.expectRevert("Not record owner");
        registry.updateRecord(1, _input());
    }

    function test_UpdateRecord_ByStranger_Reverts() public {
        _submit(reporter);
        vm.prank(stranger);
        vm.expectRevert("Not record owner");
        registry.updateRecord(1, _input());
    }

    function test_UpdateRecord_InvalidId_Reverts() public {
        vm.prank(reporter);
        vm.expectRevert("Invalid record ID");
        registry.updateRecord(0, _input());

        vm.prank(reporter);
        vm.expectRevert("Invalid record ID");
        registry.updateRecord(99, _input());
    }

    function test_UpdateRecord_NotYetSubmittedId_Reverts() public {
        vm.prank(reporter);
        vm.expectRevert("Invalid record ID");
        registry.updateRecord(1, _input());
    }

    function test_UpdateRecord_AfterWhitelistRevoked_StillAllowed() public {
        _submit(reporter);
        registry.setWhitelist(reporter, false);
        // Losing submit rights must not strand a reporter's existing corrections.
        vm.prank(reporter);
        registry.updateRecord(1, _input());
    }

    // ── Void ─────────────────────────────────────────────────────────────────

    function test_VoidRecord_ByOwner_Emits() public {
        _submit(reporter);
        vm.expectEmit(true, true, false, false);
        emit RecordVoided(1, owner);
        registry.voidRecord(1);
    }

    function test_VoidRecord_ByReporter_Emits() public {
        _submit(reporter);
        vm.prank(reporter);
        vm.expectEmit(true, true, false, false);
        emit RecordVoided(1, reporter);
        registry.voidRecord(1);
    }

    function test_VoidRecord_ClearsReporter() public {
        _submit(reporter);
        registry.voidRecord(1);
        assertEq(registry.reporterOf(1), address(0));
    }

    function test_VoidRecord_ByStranger_Reverts() public {
        _submit(reporter);
        vm.prank(stranger);
        vm.expectRevert("Not record owner");
        registry.voidRecord(1);
    }

    function test_VoidRecord_Twice_Reverts() public {
        _submit(reporter);
        registry.voidRecord(1);
        vm.expectRevert("Invalid record ID");
        registry.voidRecord(1);
    }

    function test_VoidRecord_ThenUpdate_Reverts() public {
        _submit(reporter);
        registry.voidRecord(1);
        vm.prank(reporter);
        vm.expectRevert("Invalid record ID");
        registry.updateRecord(1, _input());
    }

    function test_VoidRecord_DoesNotReuseId() public {
        _submit(reporter);
        registry.voidRecord(1);
        assertEq(_submit(reporter), 2);
    }

    function test_VoidRecord_InvalidId_Reverts() public {
        vm.expectRevert("Invalid record ID");
        registry.voidRecord(42);
    }

    function test_VoidRecordBatch_VoidsAll() public {
        _submit(reporter); _submit(reporter); _submit(reporter);
        uint256[] memory ids = new uint256[](3);
        ids[0] = 1; ids[1] = 2; ids[2] = 3;
        registry.voidRecordBatch(ids);
        assertEq(registry.reporterOf(1), address(0));
        assertEq(registry.reporterOf(2), address(0));
        assertEq(registry.reporterOf(3), address(0));
    }

    function test_VoidRecordBatch_RevertsWholeBatchOnBadId() public {
        _submit(reporter);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1; ids[1] = 99;
        vm.expectRevert("Invalid record ID");
        registry.voidRecordBatch(ids);
        // The valid id must survive the reverted batch.
        assertEq(registry.reporterOf(1), reporter);
    }


    // ── Seeding ──────────────────────────────────────────────────────────────

    function _batch(uint256 n) internal pure returns (BiodiversityRegistry.SightingInput[] memory b) {
        b = new BiodiversityRegistry.SightingInput[](n);
        for (uint256 i = 0; i < n; i++) b[i] = _input();
    }

    function test_SeedRecordBatch_CreatesRecords() public {
        (uint256 first, uint256 last) = registry.seedRecordBatch(_batch(3));
        assertEq(first, 1);
        assertEq(last, 3);
        assertEq(registry.nextRecordId(), 4);
    }

    function test_SeedRecordBatch_SetsSeedReporterOnce() public {
        vm.expectEmit(true, false, false, false);
        emit SeedReporterSet(owner);
        registry.seedRecordBatch(_batch(1));
        assertEq(registry.seedReporter(), owner);
    }

    /// @dev The saving only exists because no per-record slot is written.
    function test_SeedRecordBatch_SkipsPerRecordStorage() public {
        registry.seedRecordBatch(_batch(2));
        assertEq(registry.recordReporter(1), address(0));
        assertEq(registry.recordReporter(2), address(0));
        assertEq(registry.reporterOf(1), owner);
        assertEq(registry.reporterOf(2), owner);
    }

    function test_SeedRecordBatch_IsCheaperThanSubmitBatch() public {
        uint256 before = gasleft();
        registry.seedRecordBatch(_batch(10));
        uint256 seedGas = before - gasleft();

        BiodiversityRegistry other = new BiodiversityRegistry();
        before = gasleft();
        other.submitRecordBatch(_batch(10));
        uint256 submitGas = before - gasleft();

        assertLt(seedGas, submitGas);
    }

    function test_SeedRecordBatch_NotOwner_Reverts() public {
        vm.prank(reporter);
        vm.expectRevert("Not owner");
        registry.seedRecordBatch(_batch(1));
    }

    function test_SeedRecordBatch_Empty_Reverts() public {
        vm.expectRevert("Empty batch");
        registry.seedRecordBatch(_batch(0));
    }

    function test_SeedRecordBatch_ResumesAcrossCalls() public {
        registry.seedRecordBatch(_batch(2));
        (uint256 first, uint256 last) = registry.seedRecordBatch(_batch(2));
        assertEq(first, 3);
        assertEq(last, 4);
        assertEq(registry.reporterOf(1), owner);
        assertEq(registry.reporterOf(4), owner);
    }

    /// @dev A new owner must not silently re-attribute existing seeded records.
    function test_SeedRecordBatch_NewOwnerCannotReseed() public {
        registry.seedRecordBatch(_batch(1));
        registry.transferOwnership(reporter);
        vm.prank(reporter);
        vm.expectRevert("Seeded by another address");
        registry.seedRecordBatch(_batch(1));
    }

    function test_SeedRecordBatch_OwnershipTransferKeepsAuthorship() public {
        registry.seedRecordBatch(_batch(1));
        registry.transferOwnership(reporter);
        // Authorship stays with whoever seeded, not with whoever owns now.
        assertEq(registry.reporterOf(1), owner);
    }

    function test_SeededRecord_UpdatableBySeeder() public {
        registry.seedRecordBatch(_batch(1));
        vm.expectEmit(true, true, false, false);
        emit RecordUpdated(1, owner, _input());
        registry.updateRecord(1, _input());
    }

    function test_SeededRecord_NotUpdatableByStranger() public {
        registry.seedRecordBatch(_batch(1));
        vm.prank(stranger);
        vm.expectRevert("Not record owner");
        registry.updateRecord(1, _input());
    }

    function test_SeededRecord_NotUpdatableByOtherWhitelisted() public {
        registry.seedRecordBatch(_batch(1));
        vm.prank(reporter);
        vm.expectRevert("Not record owner");
        registry.updateRecord(1, _input());
    }

    function test_SeededRecord_Voidable() public {
        registry.seedRecordBatch(_batch(1));
        registry.voidRecord(1);
        assertEq(registry.reporterOf(1), address(0));
        assertTrue(registry.voided(1));
    }

    function test_SeededRecord_VoidedThenUpdate_Reverts() public {
        registry.seedRecordBatch(_batch(1));
        registry.voidRecord(1);
        vm.expectRevert("Invalid record ID");
        registry.updateRecord(1, _input());
    }

    function test_ReporterOf_UnknownIds() public {
        assertEq(registry.reporterOf(0), address(0));
        assertEq(registry.reporterOf(1), address(0));
        registry.seedRecordBatch(_batch(1));
        assertEq(registry.reporterOf(2), address(0));
    }

    /// @dev Mixed origins must not bleed authorship into one another.
    function test_SeedAndSubmit_AuthorshipStaysSeparate() public {
        registry.seedRecordBatch(_batch(2));
        vm.prank(reporter);
        registry.submitRecord(_input());

        assertEq(registry.reporterOf(1), owner);
        assertEq(registry.reporterOf(2), owner);
        assertEq(registry.reporterOf(3), reporter);
    }

    // ── Fuzz ─────────────────────────────────────────────────────────────────

    function testFuzz_SubmitRecord_AnyCoordinates(int256 lat, int256 lon, uint16 count) public {
        BiodiversityRegistry.SightingInput memory s = _input();
        s.latitude = lat; s.longitude = lon; s.count = count;
        vm.prank(reporter);
        uint256 id = registry.submitRecord(s);
        assertEq(registry.recordReporter(id), reporter);
    }

    function testFuzz_OnlyWhitelistedCanSubmit(address who) public {
        vm.assume(who != reporter && who != owner);
        vm.assume(!registry.whitelist(who));
        vm.prank(who);
        vm.expectRevert("Not whitelisted");
        registry.submitRecord(_input());
    }
}
