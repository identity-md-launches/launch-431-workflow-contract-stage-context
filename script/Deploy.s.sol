// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {Guilds} from "../src/Guilds.sol";
import {Realm} from "../src/Realm.sol";

/// @title Deploy
/// @notice Local deployment of the Pacts contracts for development against anvil.
/// @dev On Sepolia the launch is performed by the network's ProjectFactory from launch.json; this
/// script is never used for the real launch and reads no keys. `run()` only checks that the chain
/// matches EXPECTED_CHAIN_ID when one is set (0 or unset means simulation only) and then deploys
/// the token, Guilds and Realm with the production parameters. Tests call {deploy} directly.
contract Deploy is Script {
    struct Config {
        uint256 epochLength;
        uint256 seasonLength;
        uint256 troopPrice;
        uint256 feeBps;
    }

    uint256 public constant ANVIL = 31337;
    uint256 public constant SEPOLIA = 11155111;

    function productionConfig() public pure returns (Config memory) {
        return Config({epochLength: 1 hours, seasonLength: 7 days, troopPrice: 1e18, feeBps: 1000});
    }

    function run() external returns (LaunchToken token, Guilds guilds, Realm realm) {
        uint256 expected = vm.envOr("EXPECTED_CHAIN_ID", uint256(0));
        if (expected != 0) {
            require(expected == ANVIL || expected == SEPOLIA, "unsupported chain");
            require(block.chainid == expected, "chain id mismatch");
        }
        vm.startBroadcast();
        (token, guilds, realm) = deploy(productionConfig());
        vm.stopBroadcast();
    }

    function deploy(Config memory config) public returns (LaunchToken token, Guilds guilds, Realm realm) {
        token = new LaunchToken();
        guilds = new Guilds();
        realm = new Realm(
            address(token), address(guilds), config.epochLength, config.seasonLength, config.troopPrice, config.feeBps
        );
    }
}
