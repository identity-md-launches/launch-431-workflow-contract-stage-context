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
        vm.startPrank(alice);
        vm.expectRevert(Realm.ZeroAmount.selector);
        realm.fundTreasury(1, 0);
        vm.expectRevert(Realm.ZeroAmount.selector);
        realm.buyTroopsFromTreasury(1, 0);
        vm.expectRevert(Realm.InsufficientTreasury.selector);
        realm.buyTroopsFromTreasury(1, 1);
        vm.stopPrank();
        _assertEmptyFundingState();
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
        uint256 badTile = _propose(alice, 2, bytes32((uint256(144) << 128) | 1));
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
        _fund(alice, 1, 1);
        _fund(bob, 2, 1);
        uint256 pa = _proposePact(alice, 2, 1, 1, 1);
        uint256 pb = _proposePact(bob, 1, 1, 1, 1);
        vm.prank(alice);
        diplomacy.signPact(pa, pb);
        vm.warp(GENESIS + EPOCH - 1);
        vm.expectRevert(Diplomacy.PactStillActive.selector);
        diplomacy.settlePact(0);
        assertEq(realm.lockedBonds(1), 1);
        vm.warp(GENESIS + EPOCH);
        vm.prank(frank);
        diplomacy.settlePact(0);
        assertEq(realm.treasury(1), 1);
        assertEq(realm.treasury(2), 1);
        vm.expectRevert(Diplomacy.AlreadySettled.selector);
        diplomacy.settlePact(0);
        assertEq(token.balanceOf(address(realm)), 2);
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
        vm.prank(alice);
        diplomacy.signPact(pa, pb);
        (bool a,, bool b,) = diplomacy.betrayalOf(0);
        assertFalse(a);
        assertFalse(b);
        _nextEpoch();
        diplomacy.settlePact(0);
        assertEq(realm.treasury(1), 5e18);
        assertEq(realm.treasury(2), 5e18);
        assertEq(diplomacy.pact(0).brokenBy, 0);
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
        uint32 partner,
        uint32 duration,
        uint96 ownBond,
        uint96 otherBond
    ) public view {
        uint256 tile = bound(tileSeed, 0, 143);
        (uint256 decodedTile, uint256 decodedForce) = realm.unpackAttackData(realm.packAttackData(tile, force));
        assertEq(decodedTile, tile);
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
