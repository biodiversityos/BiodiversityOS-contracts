// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title BiodiversityRegistry
/// @notice Append-only registry of wildlife sightings. Records live in events,
///         not in storage: an indexer replays them to build the queryable state.
///         Only the reporter address is kept on-chain, so authorship can be
///         enforced without paying to store the record itself.
contract BiodiversityRegistry {
    /// @param latitude  Degrees x 1e6. 20.123456째 -> 20123456.
    /// @param longitude Degrees x 1e6, negative west of Greenwich.
    /// @param count     Individuals observed.
    /// @param observedAt Unix seconds. Zero when the date is genuinely unknown.
    /// @param depthFt   Depth in feet, zero when not recorded.
    /// @param siteName  Official dive-site name from the project's site catalog.
    /// @param sizeClass Free-form size bucket as recorded in the field.
    struct SightingInput {
        int256 latitude;
        int256 longitude;
        string species;
        uint16 count;
        string behavior;
        uint256 observedAt;
        string mediaUrl;
        string comment;
        string siteName;
        uint16 depthFt;
        string sizeClass;
    }

    address public owner;
    uint256 public nextRecordId;

    mapping(address => bool) public whitelist;

    /// @notice Author of a record, stored only for individually submitted ones.
    ///         Seeded records leave this empty and fall back to `seedReporter`.
    mapping(uint256 => address) public recordReporter;

    /// @notice Records retracted by their reporter or the owner.
    mapping(uint256 => bool) public voided;

    /// @notice Author credited to records created by `seedRecordBatch`.
    ///         Writing one address for a whole import instead of one per record
    ///         is what keeps bulk seeding affordable: a fresh storage slot costs
    ///         20k gas, which would otherwise dominate the cost of the import.
    address public seedReporter;

    event RecordCreated(
        uint256 indexed recordId,
        address indexed reporter,
        SightingInput sighting
    );

    event RecordUpdated(
        uint256 indexed recordId,
        address indexed reporter,
        SightingInput sighting
    );

    /// @notice A record was retracted and must be dropped by indexers.
    event RecordVoided(uint256 indexed recordId, address indexed voidedBy);

    /// @notice Emitted once per seeding transaction, before its records.
    event SeedReporterSet(address indexed reporter);

    event WhitelistUpdated(address indexed addr, bool status);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
        nextRecordId = 1;
        whitelist[msg.sender] = true;
        emit OwnershipTransferred(address(0), msg.sender);
        emit WhitelistUpdated(msg.sender, true);
    }

    // ── Administration ───────────────────────────────────────────────────────

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setWhitelist(address addr, bool status) public onlyOwner {
        whitelist[addr] = status;
        emit WhitelistUpdated(addr, status);
    }

    /// @notice Grant or revoke many field reporters in a single transaction.
    function setWhitelistBatch(address[] calldata addrs, bool status) external onlyOwner {
        for (uint256 i = 0; i < addrs.length; i++) {
            setWhitelist(addrs[i], status);
        }
    }

    // ── Records ──────────────────────────────────────────────────────────────

    /// @dev Author of a record, or zero if it never existed or was voided.
    ///      Records created by `seedRecordBatch` store no per-record author and
    ///      resolve to `seedReporter`.
    function reporterOf(uint256 recordId) public view returns (address) {
        if (recordId == 0 || recordId >= nextRecordId || voided[recordId]) {
            return address(0);
        }
        address stored = recordReporter[recordId];
        return stored != address(0) ? stored : seedReporter;
    }

    function submitRecord(SightingInput calldata s) external returns (uint256 recordId) {
        require(whitelist[msg.sender], "Not whitelisted");
        recordId = _nextId();
        recordReporter[recordId] = msg.sender;
        emit RecordCreated(recordId, msg.sender, s);
    }

    /// @notice Submit many sightings at once, each attributed to the caller.
    function submitRecordBatch(SightingInput[] calldata batch)
        external
        returns (uint256 firstRecordId, uint256 lastRecordId)
    {
        require(whitelist[msg.sender], "Not whitelisted");
        require(batch.length > 0, "Empty batch");
        firstRecordId = nextRecordId;
        for (uint256 i = 0; i < batch.length; i++) {
            lastRecordId = _nextId();
            recordReporter[lastRecordId] = msg.sender;
            emit RecordCreated(lastRecordId, msg.sender, batch[i]);
        }
    }

    /// @notice Seed the registry from an existing field database.
    /// @dev    Skips the per-record author write, so a large import stays
    ///         affordable. Every seeded record is credited to `seedReporter`,
    ///         which is why only the owner may call this and why it may not be
    ///         re-pointed at a different address once records exist under it.
    function seedRecordBatch(SightingInput[] calldata batch)
        external
        onlyOwner
        returns (uint256 firstRecordId, uint256 lastRecordId)
    {
        require(batch.length > 0, "Empty batch");

        if (seedReporter == address(0)) {
            seedReporter = msg.sender;
            emit SeedReporterSet(msg.sender);
        } else {
            require(seedReporter == msg.sender, "Seeded by another address");
        }

        firstRecordId = nextRecordId;
        for (uint256 i = 0; i < batch.length; i++) {
            lastRecordId = _nextId();
            emit RecordCreated(lastRecordId, msg.sender, batch[i]);
        }
    }

    function _nextId() internal returns (uint256 recordId) {
        recordId = nextRecordId;
        nextRecordId = recordId + 1;
    }

    /// @dev Only the original reporter may correct a record; the owner may act
    ///      on their behalf to fix bad data without holding their key.
    function updateRecord(uint256 recordId, SightingInput calldata s) external {
        address reporter = reporterOf(recordId);
        require(reporter != address(0), "Invalid record ID");
        require(msg.sender == reporter || msg.sender == owner, "Not record owner");
        emit RecordUpdated(recordId, reporter, s);
    }

    /// @notice Retract a record so indexers delete it. The emitted history stays
    ///         on-chain; only the derived state drops the row.
    function voidRecord(uint256 recordId) public {
        address reporter = reporterOf(recordId);
        require(reporter != address(0), "Invalid record ID");
        require(msg.sender == reporter || msg.sender == owner, "Not record owner");
        voided[recordId] = true;
        emit RecordVoided(recordId, msg.sender);
    }

    /// @notice Retract many records at once, for cleaning up a bad import.
    function voidRecordBatch(uint256[] calldata recordIds) external {
        for (uint256 i = 0; i < recordIds.length; i++) {
            voidRecord(recordIds[i]);
        }
    }
}
