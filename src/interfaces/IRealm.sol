// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The subset of Realm that Diplomacy and Season use.
interface IRealm {
    function currentEpoch() external view returns (uint256);
    function settledEpoch() external view returns (uint256);
    function epochsPerSeason() external view returns (uint256);
    function troopPrice() external view returns (uint256);
    function seasonEndTime(uint256 season) external view returns (uint256);
    function tilesAtSeasonEnd(uint256 guildId, uint256 season) external view returns (uint256);
    function attackLogLength(uint256 attacker, uint256 defender) external view returns (uint256);
    function attackLogAt(uint256 attacker, uint256 defender, uint256 index) external view returns (uint256);
    function lockBond(uint256 guildId, uint256 amount) external;
    function releaseBond(uint256 guildId, uint256 amount) external;
    function slashBond(uint256 from, uint256 to, uint256 amount) external;
}
