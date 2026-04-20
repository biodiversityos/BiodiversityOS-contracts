// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract BiodiversityRegistry {
    address public owner;
    uint256 public nextRecordId;

    mapping(address => bool) public whitelist;

    event RecordCreated(
        uint256 indexed recordId,
        address indexed reporter,
        int256 latitude,
        int256 longitude,
        string species,
        uint16 count,
        string behavior,
        uint256 observedAt,
        string mediaUrl,
        string comment
    );

    event RecordUpdated(
        uint256 indexed recordId,
        address indexed reporter,
        int256 latitude,
        int256 longitude,
        string species,
        uint16 count,
        string behavior,
        uint256 observedAt,
        string mediaUrl,
        string comment
    );

    event WhitelistUpdated(address indexed addr, bool status);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyWhitelisted() {
        require(whitelist[msg.sender], "Not whitelisted");
        _;
    }

    constructor() {
        owner = msg.sender;
        nextRecordId = 1;
    }

    function setWhitelist(address addr, bool status) external onlyOwner {
        whitelist[addr] = status;
        emit WhitelistUpdated(addr, status);
    }

    // lat/lon stored with 1e6 precision: 20.123456 degrees → 20123456
    function submitRecord(
        int256 latitude,
        int256 longitude,
        string calldata species,
        uint16 count,
        string calldata behavior,
        uint256 observedAt,
        string calldata mediaUrl,
        string calldata comment
    ) external onlyWhitelisted returns (uint256 recordId) {
        recordId = nextRecordId;
        nextRecordId++;
        emit RecordCreated(
            recordId,
            msg.sender,
            latitude,
            longitude,
            species,
            count,
            behavior,
            observedAt,
            mediaUrl,
            comment
        );
    }

    function updateRecord(
        uint256 recordId,
        int256 latitude,
        int256 longitude,
        string calldata species,
        uint16 count,
        string calldata behavior,
        uint256 observedAt,
        string calldata mediaUrl,
        string calldata comment
    ) external onlyWhitelisted {
        require(recordId > 0 && recordId < nextRecordId, "Invalid record ID");
        emit RecordUpdated(
            recordId,
            msg.sender,
            latitude,
            longitude,
            species,
            count,
            behavior,
            observedAt,
            mediaUrl,
            comment
        );
    }
}
