// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title LaunchToken
/// @notice Fixed-supply ERC-20 used as the Pacts game currency.
/// @dev The whole supply (1,000,000,000 tokens, 18 decimals) is minted to the deployer, which at
/// launch is the ProjectFactory. There is no mint, owner, pause, blocklist, fee or upgrade path.
contract LaunchToken is ERC20 {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    constructor() ERC20("Pacts", "PACT") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
