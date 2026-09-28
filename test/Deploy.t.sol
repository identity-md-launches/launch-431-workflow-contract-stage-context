// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {Guilds} from "../src/Guilds.sol";
import {Realm} from "../src/Realm.sol";

contract DeployTest is Test {
    function test_deployWithProductionConfig() public {
        Deploy script = new Deploy();
        (LaunchToken token, Guilds guilds, Realm realm) = script.deploy(script.productionConfig());
        assertEq(token.balanceOf(address(script)), 10 ** 27, "supply minted to the deployer");
        assertEq(address(realm.token()), address(token));
        assertEq(address(realm.guilds()), address(guilds));
        assertEq(realm.epochLength(), 1 hours);
        assertEq(realm.seasonLength(), 7 days);
        assertEq(realm.troopPrice(), 1e18);
        assertEq(realm.feeBps(), 1000);
        assertTrue(address(realm.season()) != address(0));
        assertTrue(address(realm.diplomacy()) != address(0));
    }

    function test_deployWithCustomConfig() public {
        Deploy script = new Deploy();
        Deploy.Config memory cfg =
            Deploy.Config({epochLength: 10 minutes, seasonLength: 1 days, troopPrice: 5e17, feeBps: 250});
        (,, Realm realm) = script.deploy(cfg);
        assertEq(realm.epochsPerSeason(), 144);
        assertEq(realm.troopPrice(), 5e17);
        assertEq(realm.feeBps(), 250);
    }
}
