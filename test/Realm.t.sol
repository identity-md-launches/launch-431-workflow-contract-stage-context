// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PactsBase} from "./PactsBase.t.sol";
import {Realm} from "../src/Realm.sol";
import {Guilds} from "../src/Guilds.sol";
import {GUILD_KIND_ATTACK, GUILD_KIND_DISTRIBUTE} from "../src/interfaces/IGuilds.sol";

contract RealmTest is PactsBase {
    function test_constructorWiring() public view {
        assertEq(address(realm.token()), address(token));
        assertEq(address(realm.guilds()), address(guilds));
        assertEq(address(diplomacy.realm()), address(realm));
        assertEq(address(diplomacy.guilds()), address(guilds));
        assertEq(address(season.realm()), address(realm));
        assertEq(address(season.diplomacy()), address(diplomacy));
        assertEq(address(season.token()), address(token));
        assertEq(banners.minter(), address(season));
        assertEq(realm.genesis(), GENESIS);
        assertEq(realm.epochLength(), EPOCH);
        assertEq(realm.seasonLength(), SEASON);
        assertEq(realm.epochsPerSeason(), EPOCHS_PER_SEASON);
        assertEq(season.epochsPerSeason(), EPOCHS_PER_SEASON);
        assertEq(realm.currentEpoch(), 0);
        assertEq(realm.seasonEndTime(0), GENESIS + SEASON);
        assertEq(realm.epochStart(3), GENESIS + 3 * EPOCH);
        assertEq(token.balanceOf(address(realm)), 0);
    }

    function test_constructorRejectsBadParams() public {
        vm.expectRevert(Realm.ZeroAddress.selector);
        new Realm(address(0), address(guilds), EPOCH, SEASON, PRICE, FEE_BPS);
        vm.expectRevert(Realm.BadParams.selector);
        new Realm(address(token), address(guilds), 0, SEASON, PRICE, FEE_BPS);
        vm.expectRevert(Realm.BadParams.selector);
        new Realm(address(token), address(guilds), EPOCH, EPOCH + 1, PRICE, FEE_BPS);
        vm.expectRevert(Realm.BadParams.selector);
        new Realm(address(token), address(guilds), EPOCH, SEASON, 0, FEE_BPS);
        vm.expectRevert(Realm.BadParams.selector);
        new Realm(address(token), address(guilds), EPOCH, SEASON, PRICE, 10_001);
    }

    // ------------------------------------------------------------ buying

    function test_buyTroopsSplitsFeeAndIncome() public {
        _found(alice, "Alpha");
        uint256 before = token.balanceOf(alice);
        _buy(alice, 1, 100);
        assertEq(token.balanceOf(alice), before - 100e18);
        assertEq(token.balanceOf(address(season)), 10e18);
        assertEq(season.prizePool(0), 10e18);
        assertEq(token.balanceOf(address(realm)), 90e18);
        assertEq(realm.incomePool(0), 90e18);
        assertEq(realm.troops(1), 100);
        _assertRealmSolvent(1, 0);
    }

    function test_buyTroopsRequiresMembershipAndAmount() public {
        _found(alice, "Alpha");
        vm.prank(bob);
        vm.expectRevert(Realm.NotMember.selector);
        realm.buyTroops(1, 1);
        vm.prank(alice);
        vm.expectRevert(Realm.ZeroAmount.selector);
        realm.buyTroops(1, 0);
        vm.prank(alice);
        vm.expectRevert(Realm.NotMember.selector);
        realm.fundTreasury(2, 1);
    }

    function test_feeIsAttributedToPurchaseSeason() public {
        _found(alice, "Alpha");
        vm.warp(GENESIS + SEASON + EPOCH);
        _buy(alice, 1, 10);
        assertEq(season.prizePool(0), 0);
        assertEq(season.prizePool(1), 1e18);
        assertEq(realm.incomePool(5), 9e18);
    }

    function testFuzz_buySplit(uint96 count) public {
        count = uint96(bound(count, 1, PLAYER_FUNDS / PRICE));
        _found(alice, "Alpha");
        _buy(alice, 1, count);
        uint256 cost = uint256(count) * PRICE;
        uint256 fee = cost * FEE_BPS / 10_000;
        assertEq(token.balanceOf(address(season)), fee);
        assertEq(token.balanceOf(address(realm)), cost - fee);
        assertEq(realm.troops(1), count);
        assertEq(
            token.balanceOf(address(realm)) + token.balanceOf(address(season)) + token.balanceOf(alice), PLAYER_FUNDS
        );
    }

    // ------------------------------------------------------------ attacks

    function test_attackNeedsMajorityMembershipAndTroops() public {
        _found(alice, "Alpha");
        _join(bob, 1);
        _buy(alice, 1, 10);
        uint256 id = _proposeAttack(alice, 5, 10);
        vm.prank(alice);
        vm.expectRevert(Realm.NoMajority.selector);
        realm.declareAttack(id);
        _vote(bob, id, true);
        vm.prank(carol);
        vm.expectRevert(Realm.NotMember.selector);
        realm.declareAttack(id);
        uint256 tooMany = _proposeAttack(alice, 6, 11);
        _vote(bob, tooMany, true);
        vm.prank(alice);
        vm.expectRevert(Realm.InsufficientTroops.selector);
        realm.declareAttack(tooMany);
        uint256 zero = _propose(alice, GUILD_KIND_ATTACK, bytes32(uint256(7) << 128));
        _vote(bob, zero, true);
        vm.prank(alice);
        vm.expectRevert(Realm.ZeroAmount.selector);
        realm.declareAttack(zero);
        uint256 badTile = _propose(alice, GUILD_KIND_ATTACK, bytes32((uint256(144) << 128) | 1));
        _vote(bob, badTile, true);
        vm.prank(alice);
        vm.expectRevert(Realm.BadTile.selector);
        realm.declareAttack(badTile);
        uint256 wrongKind = _propose(alice, GUILD_KIND_DISTRIBUTE, bytes32(0));
        _vote(bob, wrongKind, true);
        vm.prank(alice);
        vm.expectRevert(Realm.WrongKind.selector);
        realm.declareAttack(wrongKind);

        vm.prank(bob);
        uint256 attackId = realm.declareAttack(id);
        assertEq(attackId, 0);
        assertEq(realm.troops(1), 0, "troops committed at declaration");
        assertTrue(realm.proposalUsed(id));
        assertTrue(realm.hasAttacked(0, 1, 5));
        vm.prank(alice);
        vm.expectRevert(Realm.ProposalUsed.selector);
        realm.declareAttack(id);
        Realm.Attack memory a = realm.attack(0);
        assertEq(a.guild, 1);
        assertEq(a.tile, 5);
        assertEq(a.troops, 10);
        assertEq(a.defender, 0);
        assertFalse(a.resolved);
    }

    function test_sameGuildCannotAttackTileTwiceInEpochOrOwnTile() public {
        _found(alice, "Alpha");
        _buy(alice, 1, 30);
        _attack(alice, 5, 10);
        uint256 again = _proposeAttack(alice, 5, 5);
        vm.prank(alice);
        vm.expectRevert(Realm.AlreadyAttacking.selector);
        realm.declareAttack(again);
        _nextEpoch();
        _settleAll();
        assertEq(realm.holder(5), 1);
        uint256 own = _proposeAttack(alice, 5, 5);
        vm.prank(alice);
        vm.expectRevert(Realm.OwnTile.selector);
        realm.declareAttack(own);
    }

    function test_attacksNeedSettledEpoch() public {
        _found(alice, "Alpha");
        _buy(alice, 1, 10);
        _nextEpoch();
        uint256 id = _proposeAttack(alice, 5, 10);
        vm.prank(alice);
        vm.expectRevert(Realm.EpochNotSettled.selector);
        realm.declareAttack(id);
        vm.prank(alice);
        vm.expectRevert(Realm.EpochNotSettled.selector);
        realm.reinforce(5, 1);
        _settleAll();
        vm.prank(alice);
        realm.declareAttack(id);
    }

    function test_captureUnheldTile() public {
        _found(alice, "Alpha");
        _buy(alice, 1, 10);
        uint256 attackId = _attack(alice, 5, 10);
        _nextEpoch();
        _settleAll();
        assertEq(realm.holder(5), 1);
        assertEq(realm.garrison(5), 10, "no losses against an empty tile");
        assertEq(realm.tilesHeld(1), 1);
        assertEq(realm.totalTilesHeld(), 1);
        Realm.Attack memory a = realm.attack(attackId);
        assertTrue(a.resolved);
        assertTrue(a.won);
        assertEq(a.survivors, 10);
        assertEq(realm.map()[5], 1);
        assertEq(realm.tilesAtSeasonEnd(1, 0), 1);
    }

    function test_severalAttackersOnOneTile() public {
        _found(alice, "Alpha");
        _found(bob, "Beta");
        _found(carol, "Gamma");
        _found(dave, "Delta");
        _buy(alice, 1, 10);
        _buy(bob, 2, 100);
        _buy(carol, 3, 100);
        _buy(dave, 4, 100);
        _attack(alice, 5, 10);
        _nextEpoch();
        _settleAll();
        assertEq(realm.holder(5), 1);

        // Epoch 1: 30 vs 20 vs 30 against a garrison of 10. Top attackers tie: holder keeps.
        uint256 aBob = _attack(bob, 5, 30);
        uint256 aCarol = _attack(carol, 5, 20);
        uint256 aDave = _attack(dave, 5, 30);
        assertEq(realm.attack(aBob).defender, 1);
        _nextEpoch();
        _settleAll();
        assertEq(realm.holder(5), 1, "tie keeps the holder");
        // total 90: losses 30*60/90=20, 20*70/90=15, 30*60/90=20, defence 10*80/90=8
        assertEq(realm.attack(aBob).survivors, 10);
        assertEq(realm.attack(aCarol).survivors, 5);
        assertEq(realm.attack(aDave).survivors, 10);
        assertFalse(realm.attack(aBob).won);
        assertEq(realm.garrison(5), 2);
        assertEq(realm.troops(2), 70 + 10, "survivors return to the pool");
        assertEq(realm.troops(3), 80 + 5);
        assertEq(realm.troops(4), 70 + 10);

        // Epoch 2: 40 vs 20 against a garrison of 2: Beta takes the tile.
        aBob = _attack(bob, 5, 40);
        aCarol = _attack(carol, 5, 20);
        _nextEpoch();
        _settleAll();
        // total 62: losses 40*22/62=14, 20*42/62=13, defence 2*60/62=1
        assertEq(realm.holder(5), 2);
        assertTrue(realm.attack(aBob).won);
        assertEq(realm.attack(aBob).survivors, 26);
        assertEq(realm.garrison(5), 26, "winner's survivors garrison the tile");
        assertEq(realm.attack(aCarol).survivors, 7);
        assertEq(realm.troops(3), 65 + 7);
        assertEq(realm.troops(1), 1, "defender's survivors retreat to its pool");
        assertEq(realm.tilesHeld(1), 0);
        assertEq(realm.tilesHeld(2), 1);
        assertEq(realm.totalTilesHeld(), 1);
        assertEq(realm.tilesAtSeasonEnd(1, 0), 0);
        assertEq(realm.tilesAtSeasonEnd(2, 0), 1);
        _assertRealmSolvent(4, 0);
    }

    function test_weakerAttackerLosesToGarrison() public {
        _found(alice, "Alpha");
        _found(bob, "Beta");
        _buy(alice, 1, 10);
        _buy(bob, 2, 10);
        _attack(alice, 0, 10);
        _nextEpoch();
        _settleAll();
        uint256 id = _attack(bob, 0, 5);
        _nextEpoch();
        _settleAll();
        assertEq(realm.holder(0), 1);
        // total 15: attacker loses 5*10/15=3, defence loses 10*5/15=3
        assertEq(realm.attack(id).survivors, 2);
        assertEq(realm.garrison(0), 7);
        assertEq(realm.troops(2), 7);
    }

    function test_equalForceAgainstGarrisonKeepsHolder() public {
        _found(alice, "Alpha");
        _found(bob, "Beta");
        _buy(alice, 1, 10);
        _buy(bob, 2, 10);
        _attack(alice, 0, 10);
        _nextEpoch();
        _settleAll();
        _attack(bob, 0, 10);
        _nextEpoch();
        _settleAll();
        assertEq(realm.holder(0), 1);
        assertEq(realm.garrison(0), 5);
        assertEq(realm.troops(2), 5);
    }

    function test_tiedAttackersOnEmptyTileLeaveItEmpty() public {
        _found(alice, "Alpha");
        _found(bob, "Beta");
        _buy(alice, 1, 10);
        _buy(bob, 2, 10);
        _attack(alice, 0, 10);
        _attack(bob, 0, 10);
        _nextEpoch();
        _settleAll();
        assertEq(realm.holder(0), 0);
        assertEq(realm.troops(1), 5);
        assertEq(realm.troops(2), 5);
        assertEq(realm.totalTilesHeld(), 0);
    }

    function testFuzz_battleConservesTroops(uint64 garrisonSeed, uint64 f1, uint64 f2, uint64 f3) public {
        uint256 g = bound(garrisonSeed, 1, 1_000_000);
        uint256[3] memory f = [bound(f1, 1, 1_000_000), bound(f2, 1, 1_000_000), bound(f3, 1, 1_000_000)];
        _found(alice, "Alpha");
        _found(bob, "Beta");
        _found(carol, "Gamma");
        _found(dave, "Delta");
        _buy(alice, 1, g);
        _buy(bob, 2, f[0]);
        _buy(carol, 3, f[1]);
        _buy(dave, 4, f[2]);
        _attack(alice, 9, g);
        _nextEpoch();
        _settleAll();
        _attack(bob, 9, f[0]);
        _attack(carol, 9, f[1]);
        _attack(dave, 9, f[2]);
        _nextEpoch();
        _settleAll();
        uint256 total = g + f[0] + f[1] + f[2];
        uint256 remaining = realm.garrison(9) + realm.troops(1) + realm.troops(2) + realm.troops(3) + realm.troops(4);
        assertLe(remaining, total, "troops appeared");
        assertGt(realm.garrison(9), 0, "a held tile always keeps a garrison");
        uint256 h = realm.holder(9);
        assertTrue(h != 0);
        uint256 best = f[0] > f[1] ? f[0] : f[1];
        if (f[2] > best) best = f[2];
        uint256 bestCount = (f[0] == best ? 1 : 0) + (f[1] == best ? 1 : 0) + (f[2] == best ? 1 : 0);
        if (bestCount > 1 || best <= g) {
            assertEq(h, 1, "holder keeps on tie or when not outmatched");
        } else {
            assertEq(h, f[0] == best ? 2 : (f[1] == best ? 3 : 4));
        }
        assertEq(realm.totalTilesHeld(), 1);
    }

    // ------------------------------------------------------------ settlement mechanics

    function test_chunkedSettlement() public {
        _found(alice, "Alpha");
        _buy(alice, 1, 30);
        _attack(alice, 0, 10);
        _attack(alice, 1, 10);
        _attack(alice, 2, 10);
        _nextEpoch();
        vm.expectRevert(Realm.ZeroBudget.selector);
        realm.settle(0);
        realm.settle(1);
        assertEq(realm.settledEpoch(), 0);
        assertEq(realm.settleCursor(), 1);
        assertEq(realm.holder(0), 1);
        assertEq(realm.holder(1), 0);
        realm.settle(1);
        assertEq(realm.settleCursor(), 2);
        realm.settle(1);
        assertEq(realm.settledEpoch(), 1, "the epoch closes with its last tile");
        assertEq(realm.settleCursor(), 0);
        assertEq(realm.tilesHeld(1), 3);
        uint8[] memory tiles = realm.attackedTiles(0);
        assertEq(tiles.length, 3);
        assertEq(realm.tileAttacks(0, 1).length, 1);
        assertEq(realm.attackCount(), 3);
    }

    function test_settleManyIdleEpochsAndNoopBeforeEpochEnd() public {
        _found(alice, "Alpha");
        realm.settle(5);
        assertEq(realm.settledEpoch(), 0, "current epoch never settles");
        vm.warp(GENESIS + 10 * EPOCH);
        realm.settle(3);
        assertEq(realm.settledEpoch(), 3, "one budget unit per idle epoch");
        realm.settle(100);
        assertEq(realm.settledEpoch(), 10);
    }

    function test_incomeSharedPerTileAndCarriedWhenUnheld() public {
        _found(alice, "Alpha");
        _found(bob, "Beta");
        _found(carol, "Gamma");
        _buy(alice, 1, 100); // epoch 0 income 90e18, nobody holds a tile yet
        _buy(bob, 2, 100); // another 90e18
        _attack(alice, 0, 10);
        _attack(alice, 1, 10);
        _attack(bob, 2, 10);
        _nextEpoch();
        _settleAll();
        assertEq(realm.carriedIncome(), 180e18, "income with no holders carries over");
        assertEq(realm.pendingIncome(1), 0);
        _buy(carol, 3, 100); // epoch 1 income 90e18
        _nextEpoch();
        _settleAll();
        assertEq(realm.carriedIncome(), 0);
        assertEq(realm.pendingIncome(1), 180e18, "two of three tiles");
        assertEq(realm.pendingIncome(2), 90e18);
        assertEq(realm.pendingIncome(3), 0);
        realm.harvest(1);
        assertEq(realm.treasury(1), 180e18);
        assertEq(realm.pendingIncome(1), 0);
        _assertRealmSolvent(3, 0);
        // a guild losing its tiles keeps what it earned
        _buy(carol, 3, 100);
        _attack(carol, 2, 100);
        _nextEpoch();
        _settleAll();
        assertEq(realm.holder(2), 3);
        assertEq(realm.treasury(2), 90e18 + 30e18, "harvested on tile change, incl. epoch 2 income");
        assertEq(realm.pendingIncome(2), 0);
        assertEq(realm.pendingIncome(1), 60e18);
        _assertRealmSolvent(3, 0);
    }

    function test_reinforceOnlyByHolderMembers() public {
        _found(alice, "Alpha");
        _join(bob, 1);
        _found(carol, "Gamma");
        _buy(alice, 1, 20);
        uint256 p = _proposeAttack(alice, 0, 10);
        _vote(bob, p, true);
        vm.prank(alice);
        realm.declareAttack(p);
        _nextEpoch();
        _settleAll();
        vm.prank(carol);
        vm.expectRevert(Realm.NotHolder.selector);
        realm.reinforce(0, 1);
        vm.prank(alice);
        vm.expectRevert(Realm.NotHolder.selector);
        realm.reinforce(1, 1);
        vm.prank(alice);
        vm.expectRevert(Realm.BadTile.selector);
        realm.reinforce(144, 1);
        vm.prank(bob);
        vm.expectRevert(Realm.InsufficientTroops.selector);
        realm.reinforce(0, 11);
        vm.prank(bob);
        vm.expectRevert(Realm.ZeroAmount.selector);
        realm.reinforce(0, 0);
        vm.prank(bob);
        realm.reinforce(0, 7);
        assertEq(realm.garrison(0), 17);
        assertEq(realm.troops(1), 3);
    }

    // ------------------------------------------------------------ treasury

    function test_distributeTreasuryByVote() public {
        _found(alice, "Alpha");
        _join(bob, 1);
        _found(carol, "Gamma");
        _buy(alice, 1, 10);
        uint256 p = _proposeAttack(alice, 0, 10);
        _vote(bob, p, true);
        vm.prank(alice);
        realm.declareAttack(p);
        _nextEpoch();
        _settleAll();
        _buy(carol, 2, 100); // 90e18 income plus the 9e18 carried from epoch 0
        _nextEpoch();
        _settleAll();
        assertEq(realm.pendingIncome(1), 99e18);

        uint256 d = _propose(alice, GUILD_KIND_DISTRIBUTE, bytes32(0));
        vm.prank(alice);
        vm.expectRevert(Realm.NoMajority.selector);
        realm.distributeTreasury(d);
        _vote(bob, d, true);
        vm.prank(carol);
        vm.expectRevert(Realm.NotMember.selector);
        realm.distributeTreasury(d);
        uint256 aliceBefore = token.balanceOf(alice);
        uint256 bobBefore = token.balanceOf(bob);
        vm.prank(bob);
        realm.distributeTreasury(d);
        assertEq(token.balanceOf(alice), aliceBefore + 49.5e18);
        assertEq(token.balanceOf(bob), bobBefore + 49.5e18);
        assertEq(realm.treasury(1), 0);
        vm.prank(bob);
        vm.expectRevert(Realm.ProposalUsed.selector);
        realm.distributeTreasury(d);
        uint256 empty = _propose(alice, GUILD_KIND_DISTRIBUTE, bytes32(0));
        _vote(bob, empty, true);
        vm.prank(bob);
        vm.expectRevert(Realm.NothingToDistribute.selector);
        realm.distributeTreasury(empty);
        uint256 wrong = _proposeAttack(alice, 1, 1);
        _vote(bob, wrong, true);
        vm.prank(bob);
        vm.expectRevert(Realm.WrongKind.selector);
        realm.distributeTreasury(wrong);
        _assertRealmSolvent(3, 0);
    }

    function test_buyTroopsFromTreasury() public {
        _found(alice, "Alpha");
        _fund(alice, 1, 50e18);
        assertEq(realm.treasury(1), 50e18);
        vm.prank(alice);
        vm.expectRevert(Realm.InsufficientTreasury.selector);
        realm.buyTroopsFromTreasury(1, 51);
        vm.prank(bob);
        vm.expectRevert(Realm.NotMember.selector);
        realm.buyTroopsFromTreasury(1, 1);
        vm.prank(alice);
        realm.buyTroopsFromTreasury(1, 20);
        assertEq(realm.treasury(1), 30e18);
        assertEq(realm.troops(1), 20);
        assertEq(season.prizePool(0), 2e18, "fee applies to treasury purchases too");
        assertEq(realm.incomePool(0), 18e18);
        assertEq(token.balanceOf(address(realm)), 48e18);
        _assertRealmSolvent(1, 0);
    }

    function test_bondFunctionsOnlyForDiplomacy() public {
        _found(alice, "Alpha");
        _fund(alice, 1, 10e18);
        vm.prank(alice);
        vm.expectRevert(Realm.NotDiplomacy.selector);
        realm.lockBond(1, 1);
        vm.prank(alice);
        vm.expectRevert(Realm.NotDiplomacy.selector);
        realm.releaseBond(1, 1);
        vm.prank(alice);
        vm.expectRevert(Realm.NotDiplomacy.selector);
        realm.slashBond(1, 2, 1);
        vm.prank(address(diplomacy));
        vm.expectRevert(Realm.InsufficientTreasury.selector);
        realm.lockBond(1, 11e18);
        vm.prank(address(diplomacy));
        realm.lockBond(1, 4e18);
        assertEq(realm.treasury(1), 6e18);
        assertEq(realm.lockedBonds(1), 4e18);
        vm.prank(address(diplomacy));
        realm.slashBond(1, 2, 4e18);
        assertEq(realm.lockedBonds(1), 0);
        assertEq(realm.treasury(2), 4e18);
        vm.prank(address(diplomacy));
        vm.expectRevert(); // underflow: nothing locked to release
        realm.releaseBond(1, 1);
    }

    /// @dev No entry point moves a player's tokens out of Realm other than a majority-voted
    /// treasury distribution to the guild's own members and troop purchases (fee to Season).
    function test_outsiderCannotExtractFunds() public {
        _found(alice, "Alpha");
        _buy(alice, 1, 100);
        _fund(alice, 1, 100e18);
        uint256 realmBalance = token.balanceOf(address(realm));
        uint256 seasonBalance = token.balanceOf(address(season));
        address attacker = makeAddr("attacker");
        vm.startPrank(attacker);
        realm.harvest(1);
        realm.settle(10);
        vm.expectRevert(Realm.WrongKind.selector);
        realm.distributeTreasury(1);
        vm.expectRevert(Realm.NotDiplomacy.selector);
        realm.slashBond(1, 2, 1);
        vm.expectRevert(Realm.NotMember.selector);
        realm.buyTroopsFromTreasury(1, 1);
        vm.expectRevert(Realm.NotHolder.selector);
        realm.reinforce(0, 1);
        vm.expectRevert(Realm.WrongKind.selector);
        realm.declareAttack(99);
        vm.stopPrank();
        assertEq(token.balanceOf(address(realm)), realmBalance);
        assertEq(token.balanceOf(address(season)), seasonBalance);
        assertEq(token.balanceOf(attacker), 0);
        assertEq(address(realm).balance, 0);
    }

    function test_attackPackingRoundTrip() public view {
        bytes32 data = realm.packAttackData(143, 12345);
        (uint256 tile, uint256 count) = realm.unpackAttackData(data);
        assertEq(tile, 143);
        assertEq(count, 12345);
    }

    function test_attackLogRecordsOnlyHeldTargets() public {
        _found(alice, "Alpha");
        _found(bob, "Beta");
        _buy(alice, 1, 10);
        _buy(bob, 2, 10);
        _attack(bob, 3, 5); // unheld: no log entry
        assertEq(realm.attackLogLength(2, 0), 0);
        _attack(alice, 4, 10);
        _nextEpoch();
        _settleAll();
        _attack(bob, 4, 5);
        assertEq(realm.attackLogLength(2, 1), 1);
        assertEq(realm.attackLogAt(2, 1, 0), 1);
        assertEq(realm.attackLogLength(1, 2), 0);
    }

    function test_tilesAtSeasonEndUsesCheckpoints() public {
        _found(alice, "Alpha");
        _found(bob, "Beta");
        _buy(alice, 1, 30);
        _buy(bob, 2, 100);
        _attack(alice, 0, 10);
        _attack(alice, 1, 10);
        _nextEpoch();
        _settleAll(); // season 0: Alpha 2
        vm.warp(GENESIS + SEASON);
        _settleAll();
        _attack(bob, 0, 50);
        _nextEpoch();
        _settleAll(); // season 1: Alpha 1, Beta 1
        vm.warp(GENESIS + 3 * SEASON);
        _settleAll();
        _attack(bob, 1, 40);
        _nextEpoch();
        _settleAll(); // season 3: Alpha 0, Beta 2
        assertEq(realm.checkpointCount(1), 3);
        assertEq(realm.tilesAtSeasonEnd(1, 0), 2);
        assertEq(realm.tilesAtSeasonEnd(1, 1), 1);
        assertEq(realm.tilesAtSeasonEnd(1, 2), 1);
        assertEq(realm.tilesAtSeasonEnd(1, 3), 0);
        assertEq(realm.tilesAtSeasonEnd(2, 0), 0);
        assertEq(realm.tilesAtSeasonEnd(2, 1), 1);
        assertEq(realm.tilesAtSeasonEnd(2, 2), 1);
        assertEq(realm.tilesAtSeasonEnd(2, 3), 2);
        assertEq(realm.tilesAtSeasonEnd(2, 9), 2);
        assertEq(realm.tilesAtSeasonEnd(3, 9), 0);
    }
}

contract RealmCapTest is PactsBase {
    function test_attacksPerTileAreCapped() public {
        uint256 cap = realm.MAX_ATTACKS_PER_TILE();
        for (uint256 i; i < cap + 1; ++i) {
            address who = address(uint160(0x5000 + i));
            vm.prank(factory);
            token.transfer(who, 1e18);
            vm.prank(who);
            token.approve(address(realm), 1e18);
            uint256 g = _found(who, bytes32(uint256(i + 1)));
            _buy(who, g, 1);
            uint256 id = _proposeAttack(who, 7, 1);
            vm.prank(who);
            if (i == cap) vm.expectRevert(Realm.TileCrowded.selector);
            realm.declareAttack(id);
        }
        assertEq(realm.tileAttacks(0, 7).length, cap);
        _nextEpoch();
        _settleAll();
        assertEq(realm.holder(7), 0, "all forces tie: tile stays empty");
    }
}
