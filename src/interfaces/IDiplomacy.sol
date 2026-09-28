// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The subset of Diplomacy that Season reads.
interface IDiplomacy {
    function hadPactDuring(uint256 guildId, uint256 fromEpoch, uint256 toEpoch) external view returns (bool);
    function betrayedDuring(uint256 guildId, uint256 fromEpoch, uint256 toEpoch) external view returns (bool);
}
