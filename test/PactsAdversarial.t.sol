// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PactsBase} from "./PactsBase.t.sol";
import {Realm} from "src/Realm.sol";
import {Guilds} from "src/Guilds.sol";
import {Diplomacy} from "src/Diplomacy.sol";
import {Season} from "src/Season.sol";
import {Banners} from "src/Banners.sol";
import {LaunchToken} from "src/LaunchToken.sol";

/// forge-config: default.fuzz.runs = 1000
contract PactsAdversarialTest is PactsBase {
    function test_failedPurchaseDoesNotCreditTroopsOrFees() public {
        _found(alice, "Alpha");
        vm.startPrank(alice);
        token.approve(address(realm), PRICE - 1);
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientAllowance(address,uint256,uint256)", address(realm), PRICE - 1, PRICE
            )
        );
        realm.buyTroops(1, 1);
        vm.stopPrank();
        _assertEmptyFundingState();
        assertEq(token.allowance(alice, address(realm)), PRICE - 1);
        assertEq(token.balanceOf(alice), PLAYER_FUNDS);
    }

    function test_failedDonationDoesNotIncreaseTreasury() public {
        _found(alice, "Alpha");
        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientBalance(address,uint256,uint256)", alice, PLAYER_FUNDS, PLAYER_FUNDS + 1
            )
        );
        realm.fundTreasury(1, PLAYER_FUNDS + 1);
        vm.stopPrank();
        _assertEmptyFundingState();
        assertEq(realm.treasury(1), 0);
    }

    function test_zeroDonationAndEmptyTreasuryPurchaseRevert() public {
        _found(alice, "Alpha");
        uint256 zero = _propose(alice, guilds.KIND_BUY_TROOPS(), bytes32(0));
        uint256 one = _propose(alice, guilds.KIND_BUY_TROOPS(), bytes32(uint256(1)));
        uint256 huge = _propose(alice, guilds.KIND_BUY_TROOPS(), bytes32(type(uint256).max));
        vm.startPrank(alice);
        vm.expectRevert(Realm.ZeroAmount.selector);
        realm.fundTreasury(1, 0);
        vm.expectRevert(Realm.ZeroAmount.selector);
        realm.buyTroopsFromTreasury(zero);
        vm.expectRevert(Realm.InsufficientTreasury.selector);
        realm.buyTroopsFromTreasury(one);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        realm.buyTroopsFromTreasury(huge);
        vm.stopPrank();
        _assertEmptyFundingState();
        assertFalse(realm.proposalUsed(zero));
        assertFalse(realm.proposalUsed(one));
        assertFalse(realm.proposalUsed(huge));
        // A failed purchase leaves the vote intact: funding the treasury lets it execute.
        _fund(alice, 1, PRICE);
        vm.prank(alice);
        realm.buyTroopsFromTreasury(one);
        assertTrue(realm.proposalUsed(one));
        assertEq(realm.troops(1), 1);
        assertEq(realm.treasury(1), 0);
    }

    function test_treasuryPurchaseNeedsUnusedVotedProposalOfOwnGuild() public {
        _found(alice, "Alpha");
        _join(bob, 1);
        _found(carol, "Gamma");
        _fund(alice, 1, 10 * PRICE);
        uint256 unvoted = _propose(alice, guilds.KIND_BUY_TROOPS(), bytes32(uint256(1)));
        uint256 wrongKind = _propose(alice, guilds.KIND_DISTRIBUTE(), bytes32(uint256(1)));
        _vote(bob, wrongKind, true);
        vm.prank(alice);
        vm.expectRevert(Realm.NoMajority.selector);
        realm.buyTroopsFromTreasury(unvoted);
        vm.prank(alice);
        vm.expectRevert(Realm.WrongKind.selector);
        realm.buyTroopsFromTreasury(wrongKind);
        vm.prank(alice);
        vm.expectRevert(Realm.WrongKind.selector);
        realm.buyTroopsFromTreasury(0);
        uint256 unknown = guilds.proposalCount() + 1;
        vm.prank(alice);
        vm.expectRevert(Realm.WrongKind.selector);
        realm.buyTroopsFromTreasury(unknown);
        _vote(bob, unvoted, true);
        // A member of another guild cannot fire Alpha's vote, and neither can a former member.
        vm.prank(carol);
        vm.expectRevert(Realm.NotMember.selector);
        realm.buyTroopsFromTreasury(unvoted);
        vm.prank(bob);
        guilds.leave();
        vm.prank(bob);
        vm.expectRevert(Realm.NotMember.selector);
        realm.buyTroopsFromTreasury(unvoted);
        assertEq(realm.troops(1), 0);
        assertEq(realm.treasury(1), 10 * PRICE);
        vm.prank(alice);
        realm.buyTroopsFromTreasury(unvoted);
        assertEq(realm.troops(1), 1);
        assertEq(realm.treasury(1), 9 * PRICE);
        assertEq(season.prizePool(0), PRICE * FEE_BPS / 10_000);
        vm.prank(alice);
        vm.expectRevert(Realm.ProposalUsed.selector);
        realm.buyTroopsFromTreasury(unvoted);
        assertEq(realm.troops(1), 1);
        _assertRealmSolvent(2, 0);
    }

    function test_everyExecutorRefusesProposalsAtExactlyOneDayOld() public {
        _found(alice, "Alpha");
        _join(bob, 1);
        _found(carol, "Gamma");
        _buy(alice, 1, 10);
        _buy(carol, 2, 10);
        _fund(alice, 1, 10 * PRICE);
        _fund(carol, 2, 10 * PRICE);
        _attack(carol, 0, 5);
        _nextEpoch();
        _settleAll();
        uint256 buy = _propose(alice, guilds.KIND_BUY_TROOPS(), bytes32(uint256(1)));
        uint256 distribute = _propose(alice, guilds.KIND_DISTRIBUTE(), bytes32(0));
        uint256 reinforce = _propose(alice, guilds.KIND_REINFORCE(), realm.packReinforceData(0, 1));
        uint256 attackVote = _proposeAttack(alice, 0, 1);
        uint256 expel = _propose(alice, guilds.KIND_EXPEL(), bytes32(uint256(uint160(bob))));
        uint256 pa = _proposePact(alice, 2, 1, PRICE, PRICE);
        uint256 pb = _proposePact(carol, 1, 1, PRICE, PRICE);
        uint256[5] memory own = [buy, distribute, reinforce, attackVote, expel];
        for (uint256 i; i < own.length; ++i) {
            _vote(bob, own[i], true);
        }
        _vote(bob, pa, true);
        uint256 lifetime = guilds.PROPOSAL_LIFETIME();
        vm.warp(block.timestamp + lifetime - 1);
        _settleAll();
        for (uint256 i; i < own.length; ++i) {
            assertTrue(guilds.isLive(own[i]));
            assertTrue(guilds.hasMajority(own[i]));
        }
        vm.warp(block.timestamp + 1);
        _settleAll();
        vm.startPrank(alice);
        vm.expectRevert(Realm.ProposalExpired.selector);
        realm.buyTroopsFromTreasury(buy);
        vm.expectRevert(Realm.ProposalExpired.selector);
        realm.distributeTreasury(distribute);
        vm.expectRevert(Realm.ProposalExpired.selector);
        realm.reinforce(reinforce);
        vm.expectRevert(Realm.ProposalExpired.selector);
        realm.declareAttack(attackVote);
        vm.expectRevert(Guilds.ProposalExpired.selector);
        guilds.executeExpel(expel);
        vm.expectRevert(Diplomacy.ProposalExpired.selector);
        diplomacy.signPact(pa, pb);
        vm.stopPrank();
        for (uint256 i; i < own.length; ++i) {
            assertFalse(realm.proposalUsed(own[i]));
            assertTrue(guilds.hasMajority(own[i]), "expiry does not touch the vote itself");
        }
        assertFalse(guilds.proposal(expel).executed);
        assertEq(guilds.guildOf(bob), 1);
        assertEq(diplomacy.pactCount(), 0);
        assertEq(realm.troops(1), 10);
        assertEq(realm.treasury(1), 10 * PRICE);
        assertEq(realm.lockedBonds(1) + realm.lockedBonds(2), 0);
        assertEq(realm.attackCount(), 1);
    }

    function test_reinforceRejectsBadPayloadsWithoutConsumingTheVote() public {
        _found(alice, "Alpha");
        _found(bob, "Beta");
        _buy(alice, 1, 10);
        _buy(bob, 2, 10);
        _attack(alice, 0, 3);
        _attack(bob, 1, 3);
        _nextEpoch();
        _settleAll();
        uint256 foreign = _propose(alice, guilds.KIND_REINFORCE(), realm.packReinforceData(1, 1));
        uint256 unheld = _propose(alice, guilds.KIND_REINFORCE(), realm.packReinforceData(2, 1));
        uint256 zero = _propose(alice, guilds.KIND_REINFORCE(), realm.packReinforceData(0, 0));
        uint256 tooMany = _propose(alice, guilds.KIND_REINFORCE(), realm.packReinforceData(0, 8));
        uint256 badTile = _propose(alice, guilds.KIND_REINFORCE(), bytes32(uint256(144) << 192));
        uint256 attackKind = _proposeAttack(alice, 1, 1);
        vm.startPrank(alice);
        vm.expectRevert(Realm.NotHolder.selector);
        realm.reinforce(foreign);
        vm.expectRevert(Realm.NotHolder.selector);
        realm.reinforce(unheld);
        vm.expectRevert(Realm.ZeroAmount.selector);
        realm.reinforce(zero);
        vm.expectRevert(Realm.InsufficientTroops.selector);
        realm.reinforce(tooMany);
        vm.expectRevert(Realm.BadTile.selector);
        realm.reinforce(badTile);
        vm.expectRevert(Realm.WrongKind.selector);
        realm.reinforce(attackKind);
        vm.stopPrank();
        uint256[5] memory ids = [foreign, unheld, zero, tooMany, badTile];
        for (uint256 i; i < ids.length; ++i) {
            assertFalse(realm.proposalUsed(ids[i]));
        }
        assertEq(realm.troops(1), 7);
        assertEq(realm.garrison(0), 3);
        assertEq(realm.garrison(1), 3);
        // The whole pool may be garrisoned, once; the epoch must be settled first.
        uint256 all = _propose(alice, guilds.KIND_REINFORCE(), realm.packReinforceData(0, 7));
        _nextEpoch();
        vm.prank(alice);
        vm.expectRevert(Realm.EpochNotSettled.selector);
        realm.reinforce(all);
        _settleAll();
        vm.prank(alice);
        realm.reinforce(all);
        assertEq(realm.troops(1), 0);
        assertEq(realm.garrison(0), 10);
        vm.prank(alice);
        vm.expectRevert(Realm.ProposalUsed.selector);
        realm.reinforce(all);
        // A garrison reinforced by vote still fights: the whole garrison is committed.
        _attack(bob, 0, 7);
        _nextEpoch();
        _settleAll();
        assertEq(realm.holder(0), 1);
        assertEq(realm.garrison(0), 6, "10 defenders lose floor(10*7/17)");
        assertEq(realm.troops(2), 3, "7 attackers lose floor(7*10/17) and return");
    }

    function test_attackVoteIsBoundToTheDefenderItWasTakenAgainst() public {
        _found(alice, "Alpha");
        _found(bob, "Beta");
        _found(carol, "Gamma");
        _buy(alice, 1, 10);
        _buy(bob, 2, 10);
        _buy(carol, 3, 10);
        // Voted against an empty tile, fired after Beta took it: refused.
        uint256 againstEmpty = _proposeAttack(alice, 5, 4);
        // Voted against a defender that does not hold the tile: refused too.
        uint256 againstGhost = _propose(alice, guilds.KIND_ATTACK(), realm.packAttackDataAgainst(6, 4, 3));
        _attack(bob, 5, 3);
        _nextEpoch();
        _settleAll();
        assertEq(realm.holder(5), 2);
        vm.prank(alice);
        vm.expectRevert(Realm.WrongDefender.selector);
        realm.declareAttack(againstEmpty);
        vm.prank(alice);
        vm.expectRevert(Realm.WrongDefender.selector);
        realm.declareAttack(againstGhost);
        assertFalse(realm.proposalUsed(againstEmpty));
        assertFalse(realm.proposalUsed(againstGhost));
        assertEq(realm.troops(1), 10);
        // Beta loses tile 5 to Gamma and takes it back: the vote against Beta is valid again.
        uint256 againstBeta = _proposeAttack(alice, 5, 4);
        _attack(carol, 5, 9);
        _nextEpoch();
        _settleAll();
        assertEq(realm.holder(5), 3);
        vm.prank(alice);
        vm.expectRevert(Realm.WrongDefender.selector);
        realm.declareAttack(againstBeta);
        assertEq(realm.troops(2), 8);
        _attack(bob, 5, 8);
        _nextEpoch();
        _settleAll();
        assertEq(realm.holder(5), 2);
        vm.prank(alice);
        uint256 id = realm.declareAttack(againstBeta);
        assertEq(realm.attack(id).defender, 2);
        assertEq(realm.attack(id).troops, 4);
        assertEq(realm.troops(1), 6);
        assertEq(realm.attackLogLength(1, 2), 1);
        assertEq(realm.attackLogAt(1, 2, 0), realm.currentEpoch());
    }

    function test_pactBondBelowOneTroopIsRefusedOnEitherSide() public {
        _found(alice, "Alpha");
        _found(bob, "Beta");
        _fund(alice, 1, 10 * PRICE);
        _fund(bob, 2, 10 * PRICE);
        uint256 pa = _proposePact(alice, 2, 1, PRICE - 1, PRICE);
        uint256 pb = _proposePact(bob, 1, 1, PRICE, PRICE - 1);
        vm.prank(alice);
        vm.expectRevert(Diplomacy.BondTooSmall.selector);
        diplomacy.signPact(pa, pb);
        pa = _proposePact(alice, 2, 1, PRICE, PRICE - 1);
        pb = _proposePact(bob, 1, 1, PRICE - 1, PRICE);
        vm.prank(bob);
        vm.expectRevert(Diplomacy.BondTooSmall.selector);
        diplomacy.signPact(pa, pb);
        pa = _proposePact(alice, 2, 1, 0, 0);
        pb = _proposePact(bob, 1, 1, 0, 0);
        vm.prank(bob);
        vm.expectRevert(Diplomacy.BondTooSmall.selector);
        diplomacy.signPact(pa, pb);
        assertEq(diplomacy.pactCount(), 0);
        assertEq(realm.lockedBonds(1) + realm.lockedBonds(2), 0);
        assertEq(realm.treasury(1), 10 * PRICE);
        assertEq(realm.treasury(2), 10 * PRICE);
        pa = _proposePact(alice, 2, 1, PRICE, PRICE);
        pb = _proposePact(bob, 1, 1, PRICE, PRICE);
        vm.prank(bob);
        diplomacy.signPact(pa, pb);
        assertEq(realm.lockedBonds(1), PRICE);
        assertEq(realm.lockedBonds(2), PRICE);
    }

    function test_honourBannerGoesOnlyToMembersFromBeforeSeasonEnd() public {
        _found(alice, "Alpha");
        _join(bob, 1);
        _found(carol, "Gamma");
        _fund(alice, 1, 10 * PRICE);
        _fund(carol, 2, 10 * PRICE);
        uint256 pa = _proposePact(alice, 2, 1, PRICE, PRICE);
        _vote(bob, pa, true);
        uint256 pc = _proposePact(carol, 1, 1, PRICE, PRICE);
        vm.prank(carol);
        diplomacy.signPact(pa, pc);
        vm.warp(realm.seasonEndTime(0));
        _join(dave, 1); // joined exactly at the end: excluded
        vm.prank(dave);
        vm.expectRevert(Season.JoinedAfterSeason.selector);
        season.claimHonourBanner(0, 1);
        vm.prank(frank);
        vm.expectRevert(Season.NotMember.selector);
        season.claimHonourBanner(0, 1);
        vm.prank(alice);
        vm.expectRevert(Season.NotMember.selector);
        season.claimHonourBanner(0, 2);
        assertFalse(season.honourClaimed(0, 1));
        // The pact is honoured whether or not it has been settled; a season-era member claims.
        vm.prank(bob);
        uint256 id = season.claimHonourBanner(0, 1);
        assertEq(banners.ownerOf(id), bob);
        assertEq(banners.banner(id).guild, 1);
        assertEq(banners.banner(id).kind, banners.KIND_HONOUR());
        vm.prank(alice);
        vm.expectRevert(Season.AlreadyClaimed.selector);
        season.claimHonourBanner(0, 1);
        // Leaving and rejoining after the end forfeits the claim for the other guild's banner.
        vm.prank(carol);
        guilds.leave();
        _join(carol, 2);
        vm.prank(carol);
        vm.expectRevert(Season.JoinedAfterSeason.selector);
        season.claimHonourBanner(0, 2);
        assertEq(banners.totalMinted(), 1);
    }

    function test_prizeSharesSkipPostSeasonJoinersAndKeepTokensBacked() public {
        _found(alice, "Alpha");
        _join(bob, 1);
        _buy(alice, 1, 100);
        uint256 p = _proposeAttack(alice, 0, 10);
        _vote(bob, p, true);
        vm.prank(bob);
        realm.declareAttack(p);
        _nextEpoch();
        _settleAll();
        vm.warp(realm.seasonEndTime(0));
        _settleAll();
        _join(carol, 1); // after the end, before the close
        vm.prank(bob);
        guilds.leave(); // season-era member who is gone at the close
        season.close(0, 10);
        uint256 pool = season.prizePool(0);
        assertEq(pool, 100 * PRICE * FEE_BPS / 10_000);
        assertEq(season.claimable(0, alice), pool / 2, "only alice is eligible");
        assertEq(season.claimRank(0, alice), 1);
        assertEq(season.claimable(0, carol), 0);
        assertEq(season.claimRank(0, carol), 0);
        assertEq(season.claimable(0, bob), 0);
        assertEq(season.claimRank(0, bob), 0);
        assertEq(season.result(0).prizes[0], pool / 2);
        assertEq(season.result(0).rollover, pool - pool / 2);
        assertEq(season.prizePool(1), pool - pool / 2);
        vm.prank(carol);
        vm.expectRevert(Season.NothingToClaim.selector);
        season.claimPrize(0);
        vm.prank(alice);
        season.claimPrize(0);
        assertEq(token.balanceOf(address(season)), season.prizePool(1));
    }

    function test_multiplicationOverflowCannotMoveTokens() public {
        _found(alice, "Alpha");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        realm.buyTroops(1, type(uint256).max);
        _assertEmptyFundingState();
        assertEq(token.balanceOf(alice), PLAYER_FUNDS);
    }

    function test_malformedAttackAndZeroForceDoNotConsumeProposal() public {
        _found(alice, "Alpha");
        _buy(alice, 1, 10);
        uint256 badTile = _propose(alice, 2, bytes32((uint256(144) << 192) | 1));
        uint256 zeroForce = _propose(alice, 2, bytes32(0));
        vm.prank(alice);
        vm.expectRevert(Realm.BadTile.selector);
        realm.declareAttack(badTile);
        vm.prank(alice);
        vm.expectRevert(Realm.ZeroAmount.selector);
        realm.declareAttack(zeroForce);
        assertFalse(realm.proposalUsed(badTile));
        assertFalse(realm.proposalUsed(zeroForce));
        assertEq(realm.attackCount(), 0);
        assertEq(realm.troops(1), 10);
    }

    function test_revokedVoteBlocksExecutionUntilMajorityRestored() public {
        _found(alice, "Alpha");
        _join(bob, 1);
        _join(carol, 1);
        _buy(alice, 1, 10);
        uint256 p = _proposeAttack(alice, 143, 1);
        _vote(bob, p, true);
        _vote(bob, p, false);
        vm.prank(alice);
        vm.expectRevert(Realm.NoMajority.selector);
        realm.declareAttack(p);
        assertFalse(realm.proposalUsed(p));
        assertEq(realm.troops(1), 10);
        _vote(carol, p, true);
        vm.prank(alice);
        realm.declareAttack(p);
        assertTrue(realm.proposalUsed(p));
        assertEq(realm.troops(1), 9);
        vm.prank(carol);
        vm.expectRevert(Realm.ProposalUsed.selector);
        realm.declareAttack(p);
    }

    function test_failedSecondBondLockRollsBackFirstLockAndProposalUse() public {
        _found(alice, "Alpha");
        _found(bob, "Beta");
        _fund(alice, 1, 10e18);
        uint256 pa = _proposePact(alice, 2, 2, 10e18, 10e18);
        uint256 pb = _proposePact(bob, 1, 2, 10e18, 10e18);
        vm.prank(alice);
        vm.expectRevert(Realm.InsufficientTreasury.selector);
        diplomacy.signPact(pa, pb);
        assertEq(realm.treasury(1), 10e18);
        assertEq(realm.lockedBonds(1), 0);
        assertEq(realm.lockedBonds(2), 0);
        assertEq(diplomacy.pactCount(), 0);
        assertEq(diplomacy.pactsOf(1).length, 0);
        assertEq(diplomacy.pactsOf(2).length, 0);
        assertEq(diplomacy.activePactBetween(1, 2), 0);
        assertEq(diplomacy.activePactBetween(2, 1), 0);
        assertFalse(diplomacy.proposalUsed(pa));
        assertFalse(diplomacy.proposalUsed(pb));
        _fund(bob, 2, 10e18);
        vm.prank(bob);
        diplomacy.signPact(pa, pb);
        assertEq(realm.lockedBonds(1), 10e18);
        assertEq(realm.lockedBonds(2), 10e18);
    }

    function test_pactExpiryBoundaryIsInclusiveAndSettlementCannotRepeat() public {
        _found(alice, "Alpha");
        _found(bob, "Beta");
        _fund(alice, 1, PRICE);
        _fund(bob, 2, PRICE);
        uint256 pa = _proposePact(alice, 2, 1, PRICE, PRICE);
        uint256 pb = _proposePact(bob, 1, 1, PRICE, PRICE);
        vm.prank(alice);
        diplomacy.signPact(pa, pb);
        assertEq(realm.treasury(1), 0, "the minimum bond takes the whole treasury");
        vm.warp(GENESIS + EPOCH - 1);
        vm.expectRevert(Diplomacy.PactStillActive.selector);
        diplomacy.settlePact(0);
        assertEq(realm.lockedBonds(1), PRICE);
        vm.warp(GENESIS + EPOCH);
        vm.prank(frank);
        diplomacy.settlePact(0);
        assertEq(realm.treasury(1), PRICE);
        assertEq(realm.treasury(2), PRICE);
        vm.expectRevert(Diplomacy.AlreadySettled.selector);
        diplomacy.settlePact(0);
        assertEq(token.balanceOf(address(realm)), 2 * PRICE);
    }

    function test_attackBeforePactSigningDoesNotSlashNewBonds() public {
        _found(alice, "Alpha");
        _found(bob, "Beta");
        _buy(alice, 1, 10);
        _buy(bob, 2, 10);
        _attack(bob, 0, 1);
        _nextEpoch();
        _settleAll();
        _attack(alice, 0, 2);
        _fund(alice, 1, 5e18);
        _fund(bob, 2, 5e18);
        uint256 pa = _proposePact(alice, 2, 1, 5e18, 5e18);
        uint256 pb = _proposePact(bob, 1, 1, 5e18, 5e18);
        // The attack declared this epoch is still in flight: neither side can sign over it,
        // and the refusal consumes nothing.
        vm.prank(alice);
        vm.expectRevert(Diplomacy.AttackInFlight.selector);
        diplomacy.signPact(pa, pb);
        vm.prank(bob);
        vm.expectRevert(Diplomacy.AttackInFlight.selector);
        diplomacy.signPact(pb, pa);
        assertFalse(diplomacy.proposalUsed(pa));
        assertFalse(diplomacy.proposalUsed(pb));
        assertEq(realm.lockedBonds(1) + realm.lockedBonds(2), 0);
        assertEq(diplomacy.pactCount(), 0);
        _nextEpoch();
        _settleAll();
        assertEq(realm.holder(0), 1, "the pre-pact attack resolved before signing");
        vm.prank(alice);
        diplomacy.signPact(pa, pb);
        assertEq(diplomacy.pact(0).logAB, 1);
        (bool a,, bool b,) = diplomacy.betrayalOf(0);
        assertFalse(a);
        assertFalse(b);
        uint256 treasuryA = realm.treasury(1);
        uint256 treasuryB = realm.treasury(2);
        assertEq(treasuryB, 18e18, "Beta harvested the carried income of its one epoch of holding");
        _nextEpoch();
        diplomacy.settlePact(0);
        assertEq(realm.treasury(1), treasuryA + 5e18);
        assertEq(realm.treasury(2), treasuryB + 5e18);
        assertEq(diplomacy.pact(0).brokenBy, 0);
        _assertRealmSolvent(2, 0);
    }

    function test_oneWeiTreasuryRoundsDownWithoutConsumingVote() public {
        _found(alice, "Alpha");
        _join(bob, 1);
        _fund(alice, 1, 1);
        uint256 p = _propose(alice, 4, bytes32(0));
        _vote(bob, p, true);
        vm.prank(alice);
        vm.expectRevert(Realm.NothingToDistribute.selector);
        realm.distributeTreasury(p);
        assertFalse(realm.proposalUsed(p));
        assertEq(realm.treasury(1), 1);
        _fund(alice, 1, 2);
        uint256 aliceBefore = token.balanceOf(alice);
        uint256 bobBefore = token.balanceOf(bob);
        vm.prank(bob);
        realm.distributeTreasury(p);
        assertEq(token.balanceOf(alice), aliceBefore + 1);
        assertEq(token.balanceOf(bob), bobBefore + 1);
        assertEq(realm.treasury(1), 1);
        assertEq(token.balanceOf(address(realm)), 1);
    }

    function test_lastTileAndEpochBoundarySettleOnlyAfterEnd() public {
        _found(alice, "Alpha");
        _buy(alice, 1, 1);
        _attack(alice, 143, 1);
        vm.warp(GENESIS + EPOCH - 1);
        realm.settle(1);
        assertFalse(realm.attack(0).resolved);
        assertEq(realm.holder(143), 0);
        vm.warp(GENESIS + EPOCH);
        realm.settle(1);
        assertTrue(realm.attack(0).resolved);
        assertEq(realm.holder(143), 1);
        assertEq(realm.garrison(143), 1);
        assertEq(realm.settledEpoch(), 1);
    }

    function test_packRejectsEveryTruncationBoundary() public {
        vm.expectRevert(bytes("pack"));
        realm.packAttackData(144, 1);
        vm.expectRevert(bytes("pack"));
        realm.packAttackData(0, 2 ** 128);
        vm.expectRevert(bytes("pack"));
        realm.packAttackDataAgainst(144, 1, 1);
        vm.expectRevert(bytes("pack"));
        realm.packAttackDataAgainst(0, 2 ** 128, 1);
        vm.expectRevert(bytes("pack"));
        realm.packAttackDataAgainst(0, 1, 2 ** 64);
        vm.expectRevert(bytes("pack"));
        realm.packReinforceData(144, 1);
        vm.expectRevert(bytes("pack"));
        realm.packReinforceData(0, 2 ** 128);
        vm.expectRevert(bytes("pack"));
        diplomacy.packPactData(2 ** 32, 1, 1, 1);
        vm.expectRevert(bytes("pack"));
        diplomacy.packPactData(1, 2 ** 32, 1, 1);
        vm.expectRevert(bytes("pack"));
        diplomacy.packPactData(1, 1, 2 ** 96, 1);
        vm.expectRevert(bytes("pack"));
        diplomacy.packPactData(1, 1, 1, 2 ** 96);
    }

    function testFuzz_packedInputsRoundTrip(
        uint256 tileSeed,
        uint128 force,
        uint64 defender,
        uint32 partner,
        uint32 duration,
        uint96 ownBond,
        uint96 otherBond
    ) public view {
        uint256 tile = bound(tileSeed, 0, 143);
        (uint256 decodedTile, uint256 decodedDefender, uint256 decodedForce) =
            realm.unpackAttackData(realm.packAttackDataAgainst(tile, force, defender));
        assertEq(decodedTile, tile);
        assertEq(decodedDefender, defender);
        assertEq(decodedForce, force);
        (decodedTile, decodedDefender, decodedForce) = realm.unpackAttackData(realm.packAttackData(tile, force));
        assertEq(decodedTile, tile);
        assertEq(decodedDefender, 0, "the fixture map is empty, so the bound defender is none");
        assertEq(decodedForce, force);
        (decodedTile, decodedDefender, decodedForce) = realm.unpackAttackData(realm.packReinforceData(tile, force));
        assertEq(decodedTile, tile);
        assertEq(decodedDefender, 0);
        assertEq(decodedForce, force);
        (uint256 p, uint256 d, uint256 a, uint256 b) =
            diplomacy.unpackPactData(diplomacy.packPactData(partner, duration, ownBond, otherBond));
        assertEq(p, partner);
        assertEq(d, duration);
        assertEq(a, ownBond);
        assertEq(b, otherBond);
    }

    function testFuzz_battleIsIndependentOfDeclarationOrder(uint256 forceB, uint256 forceC) public {
        forceB = bound(forceB, 1, 1000);
        forceC = bound(forceC, 1, 1000);
        _found(alice, "Alpha");
        _found(bob, "Beta");
        _found(carol, "Gamma");
        _buy(alice, 1, 50);
        _buy(bob, 2, forceB);
        _buy(carol, 3, forceC);
        _attack(alice, 0, 50);
        _nextEpoch();
        _settleAll();
        uint256 snapshot = vm.snapshotState();
        _attack(bob, 0, forceB);
        _attack(carol, 0, forceC);
        _nextEpoch();
        _settleAll();
        bytes32 first = _battleState();
        assertTrue(vm.revertToState(snapshot));
        _attack(carol, 0, forceC);
        _attack(bob, 0, forceB);
        _nextEpoch();
        _settleAll();
        assertEq(_battleState(), first, "same committed forces must produce same outcome");
    }

    function test_chunkedSettlementMatchesSingleCall() public {
        _found(alice, "Alpha");
        _found(bob, "Beta");
        _buy(alice, 1, 100);
        _buy(bob, 2, 100);
        _attack(alice, 0, 20);
        _attack(bob, 0, 10);
        _attack(alice, 143, 10);
        _attack(bob, 12, 10);
        vm.warp(GENESIS + 3 * EPOCH);
        uint256 snapshot = vm.snapshotState();
        realm.settle(100);
        bytes32 single = keccak256(
            abi.encode(
                realm.map(), _battleState(), realm.carriedIncome(), realm.settledEpoch(), realm.accIncomePerTile()
            )
        );
        assertTrue(vm.revertToState(snapshot));
        for (uint256 i; i < 6; ++i) {
            realm.settle(1);
        }
        bytes32 chunked = keccak256(
            abi.encode(
                realm.map(), _battleState(), realm.carriedIncome(), realm.settledEpoch(), realm.accIncomePerTile()
            )
        );
        assertEq(chunked, single);
    }

    function test_feeExtremesAndFullSupplyPurchase() public {
        _checkFullSupplyPurchase(0);
        _checkFullSupplyPurchase(10_000);
    }

    function testFuzz_feeSplitRoundingDoesNotLoseTokens(uint256 priceSeed, uint256 countSeed, uint256 feeSeed) public {
        uint256 price = bound(priceSeed, 1, 10_001);
        uint256 count = bound(countSeed, 1, 10_001);
        uint256 fee = bound(feeSeed, 0, 10_000);
        Realm tiny = new Realm(address(token), address(guilds), EPOCH, SEASON, price, fee);
        _found(alice, "Alpha");
        vm.startPrank(alice);
        token.approve(address(tiny), type(uint256).max);
        uint256 beforeBalance = token.balanceOf(alice);
        tiny.buyTroops(1, count);
        vm.stopPrank();
        uint256 cost = beforeBalance - token.balanceOf(alice);
        assertEq(cost, price * count);
        assertEq(tiny.troops(1), count);
        assertEq(tiny.incomePool(0) + tiny.season().prizePool(0), cost);
        assertEq(token.balanceOf(address(tiny)), tiny.incomePool(0));
        assertEq(token.balanceOf(address(tiny.season())), tiny.season().prizePool(0));
        // Exact rational bounds, including fees smaller than one token minor unit.
        uint256 charged = tiny.season().prizePool(0);
        assertLe(charged * 10_000, cost * fee);
        assertLt(cost * fee, (charged + 1) * 10_000);
    }

    function test_cannotForgeFeesPrizesOrBannersAsGuildMember() public {
        _found(alice, "Alpha");
        vm.startPrank(alice);
        vm.expectRevert(Season.NotRealm.selector);
        season.recordFee(0, 1e18);
        vm.expectRevert(Season.NothingToClaim.selector);
        season.claimPrize(0);
        vm.expectRevert(Banners.NotMinter.selector);
        banners.mint(alice, 0, 1, 1, 1);
        vm.stopPrank();
        assertEq(season.prizePool(0), 0);
        assertEq(banners.totalMinted(), 0);
    }

    function _checkFullSupplyPurchase(uint256 fee) private {
        LaunchToken full = new LaunchToken();
        Guilds solo = new Guilds();
        Realm game = new Realm(address(full), address(solo), EPOCH, SEASON, 1, fee);
        solo.found("FullSupply");
        full.approve(address(game), type(uint256).max);
        uint256 supply = full.totalSupply();
        game.buyTroops(1, supply);
        assertEq(full.balanceOf(address(this)), 0);
        assertEq(game.troops(1), supply);
        assertEq(full.balanceOf(address(game)) + full.balanceOf(address(game.season())), supply);
        assertEq(game.incomePool(0), fee == 0 ? supply : 0);
        assertEq(game.season().prizePool(0), fee == 0 ? 0 : supply);
        assertEq(full.totalSupply(), supply);
    }

    function _battleState() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                realm.holder(0),
                realm.garrison(0),
                realm.troops(1),
                realm.troops(2),
                realm.troops(3),
                realm.tilesHeld(1),
                realm.tilesHeld(2),
                realm.tilesHeld(3)
            )
        );
    }

    function _assertEmptyFundingState() private view {
        assertEq(realm.troops(1), 0);
        assertEq(realm.incomePool(0), 0);
        assertEq(season.prizePool(0), 0);
        assertEq(token.balanceOf(address(realm)), 0);
        assertEq(token.balanceOf(address(season)), 0);
    }
}
