// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {Guilds} from "../src/Guilds.sol";
import {Realm} from "../src/Realm.sol";
import {Diplomacy} from "../src/Diplomacy.sol";
import {Season} from "../src/Season.sol";
import {Banners} from "../src/Banners.sol";

/// @dev Shared fixture: the launch token minted to a stand-in factory, the two manifest
/// contracts and the three contracts Realm creates. Seasons are shortened to four epochs.
abstract contract PactsBase is Test {
    uint256 internal constant EPOCH = 1 hours;
    uint256 internal constant SEASON = 4 hours;
    uint256 internal constant EPOCHS_PER_SEASON = 4;
    uint256 internal constant PRICE = 1e18;
    uint256 internal constant FEE_BPS = 1000;
    uint256 internal constant GENESIS = 1_700_000_000;
    uint256 internal constant PLAYER_FUNDS = 1_000_000e18;

    address internal factory = makeAddr("factory");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal erin = makeAddr("erin");
    address internal frank = makeAddr("frank");

    LaunchToken internal token;
    Guilds internal guilds;
    Realm internal realm;
    Diplomacy internal diplomacy;
    Season internal season;
    Banners internal banners;

    function setUp() public virtual {
        vm.warp(GENESIS);
        vm.startPrank(factory);
        token = new LaunchToken();
        guilds = new Guilds();
        realm = new Realm(address(token), address(guilds), EPOCH, SEASON, PRICE, FEE_BPS);
        vm.stopPrank();
        diplomacy = realm.diplomacy();
        season = realm.season();
        banners = season.banners();

        address[6] memory players = [alice, bob, carol, dave, erin, frank];
        for (uint256 i; i < players.length; ++i) {
            vm.prank(factory);
            token.transfer(players[i], PLAYER_FUNDS);
            vm.prank(players[i]);
            token.approve(address(realm), type(uint256).max);
        }
    }

    // ------------------------------------------------------------ helpers

    function _found(address who, bytes32 name) internal returns (uint256 id) {
        vm.prank(who);
        id = guilds.found(name);
    }

    function _join(address who, uint256 guildId) internal {
        vm.prank(who);
        guilds.join(guildId);
    }

    function _buy(address who, uint256 guildId, uint256 count) internal {
        vm.prank(who);
        realm.buyTroops(guildId, count);
    }

    function _fund(address who, uint256 guildId, uint256 amount) internal {
        vm.prank(who);
        realm.fundTreasury(guildId, amount);
    }

    function _propose(address who, uint8 kind, bytes32 data) internal returns (uint256 id) {
        vm.prank(who);
        id = guilds.propose(kind, data);
    }

    function _vote(address who, uint256 proposalId, bool support) internal {
        vm.prank(who);
        guilds.vote(proposalId, support);
    }

    function _proposeAttack(address who, uint256 tile, uint256 count) internal returns (uint256 id) {
        id = _propose(who, guilds.KIND_ATTACK(), realm.packAttackData(tile, count));
    }

    /// @dev Propose and declare an attack for a guild whose majority is the proposer alone.
    function _attack(address who, uint256 tile, uint256 count) internal returns (uint256 attackId) {
        uint256 id = _proposeAttack(who, tile, count);
        vm.prank(who);
        attackId = realm.declareAttack(id);
    }

    /// @dev Propose and execute a reinforcement for a guild whose majority is the proposer alone.
    function _reinforce(address who, uint256 tile, uint256 count) internal {
        uint256 id = _propose(who, guilds.KIND_REINFORCE(), realm.packReinforceData(tile, count));
        vm.prank(who);
        realm.reinforce(id);
    }

    /// @dev Propose and execute a treasury purchase for a guild whose majority is the proposer alone.
    function _buyFromTreasury(address who, uint256 count) internal {
        uint256 id = _propose(who, guilds.KIND_BUY_TROOPS(), bytes32(count));
        vm.prank(who);
        realm.buyTroopsFromTreasury(id);
    }

    function _proposePact(address who, uint256 partner, uint256 duration, uint256 ownBond, uint256 partnerBond)
        internal
        returns (uint256 id)
    {
        id = _propose(who, guilds.KIND_PACT(), diplomacy.packPactData(partner, duration, ownBond, partnerBond));
    }

    function _nextEpoch() internal {
        vm.warp(block.timestamp + EPOCH);
    }

    function _settleAll() internal {
        realm.settle(10_000);
        assertEq(realm.settledEpoch(), realm.currentEpoch(), "not fully settled");
    }

    /// @dev Every token in Realm is owed to someone: treasuries, locked bonds, unharvested income,
    /// unsettled income pools and the carried remainder. Anything else is rounding dust.
    function _assertRealmSolvent(uint256 guildCount, uint256 maxDust) internal view {
        uint256 owed = realm.carriedIncome();
        for (uint256 g = 1; g <= guildCount; ++g) {
            owed += realm.treasury(g) + realm.lockedBonds(g) + realm.pendingIncome(g);
        }
        for (uint256 e = realm.settledEpoch(); e <= realm.currentEpoch(); ++e) {
            owed += realm.incomePool(e);
        }
        uint256 balance = token.balanceOf(address(realm));
        assertGe(balance, owed, "realm owes more than it holds");
        assertLe(balance - owed, maxDust, "unaccounted tokens in realm");
    }
}
