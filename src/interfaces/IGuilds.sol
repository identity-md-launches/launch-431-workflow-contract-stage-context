// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

uint8 constant GUILD_KIND_EXPEL = 1;
uint8 constant GUILD_KIND_ATTACK = 2;
uint8 constant GUILD_KIND_PACT = 3;
uint8 constant GUILD_KIND_DISTRIBUTE = 4;

/// @notice The subset of Guilds that Realm, Diplomacy and Season read.
interface IGuilds {
    struct Guild {
        bytes32 name;
        address founder;
        uint64 foundedAt;
    }

    struct Proposal {
        uint64 guild;
        uint8 kind;
        bool executed;
        address proposer;
        uint64 createdAt;
        bytes32 data;
    }

    function guildCount() external view returns (uint256);
    function guildOf(address account) external view returns (uint256);
    function isMember(uint256 guildId, address account) external view returns (bool);
    function membersOf(uint256 guildId) external view returns (address[] memory);
    function memberCount(uint256 guildId) external view returns (uint256);
    function hasMajority(uint256 proposalId) external view returns (bool);
    function proposal(uint256 proposalId) external view returns (Proposal memory);
    function guild(uint256 guildId) external view returns (Guild memory);
}
