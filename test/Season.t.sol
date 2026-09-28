// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PactsBase} from "./PactsBase.t.sol";
import {Season} from "../src/Season.sol";
import {Banners} from "../src/Banners.sol";

contract SeasonTest is PactsBase {
    /// @dev Season 0 standings: Alpha (alice, bob) 3 tiles, Beta (carol) 2, Gamma (dave) 1,
    /// Delta (erin) none. Prize pool: 4 purchases of 100 troops, 10e18 fee each.
    function _playSeasonZero() internal {
        _found(alice, "Alpha");
        _join(bob, 1);
        _found(carol, "Beta");
        _found(dave, "Gamma");
        _found(erin, "Delta");
        _buy(alice, 1, 100);
        _buy(carol, 2, 100);
        _buy(dave, 3, 100);
        _buy(erin, 4, 100);
        for (uint256 t; t < 3; ++t) {
            uint256 p = _proposeAttack(alice, t, 10);
            _vote(bob, p, true);
            vm.prank(bob);
            realm.declareAttack(p);
        }
        _attack(carol, 10, 10);
        _attack(carol, 11, 10);
        _attack(dave, 20, 10);
        _nextEpoch();
        _settleAll();
        assertEq(season.prizePool(0), 40e18);
    }

    function _endSeasonZero() internal {
        vm.warp(GENESIS + SEASON);
        _settleAll();
        assertEq(realm.settledEpoch(), EPOCHS_PER_SEASON);
    }

    function test_closeRequiresFullSettlement() public {
        _playSeasonZero();
        vm.expectRevert(Season.SeasonNotSettled.selector);
        season.close(0, 10);
        vm.warp(GENESIS + SEASON);
        vm.expectRevert(Season.SeasonNotSettled.selector);
        season.close(0, 10);
        realm.settle(1);
        vm.expectRevert(Season.SeasonNotSettled.selector);
        season.close(0, 10);
        _settleAll();
        vm.expectRevert(Season.ZeroBudget.selector);
        season.close(0, 0);
        season.close(0, 10);
        assertTrue(season.result(0).closed);
        vm.expectRevert(Season.AlreadyClosed.selector);
        season.close(0, 10);
    }

    function test_closeRanksAndSplitsPrizes() public {
        _playSeasonZero();
        _endSeasonZero();
        vm.prank(frank); // anyone can close
        season.close(0, 100);
        Season.Result memory r = season.result(0);
        assertTrue(r.closed);
        assertEq(r.winners[0], 1);
        assertEq(r.winners[1], 2);
        assertEq(r.winners[2], 3);
        assertEq(r.prizes[0], 20e18);
        assertEq(r.prizes[1], 12e18);
        assertEq(r.prizes[2], 8e18);
        assertEq(r.rollover, 0);
        assertEq(season.claimable(0, alice), 10e18);
        assertEq(season.claimable(0, bob), 10e18);
        assertEq(season.claimable(0, carol), 12e18);
        assertEq(season.claimable(0, dave), 8e18);
        assertEq(season.claimable(0, erin), 0);
        assertEq(season.claimRank(0, carol), 2);
        assertEq(season.prizePool(1), 0);
    }

    function test_claimPrizePaysOnceAndMintsBanner() public {
        _playSeasonZero();
        _endSeasonZero();
        season.close(0, 100);
        uint256 before = token.balanceOf(bob);
        vm.prank(bob);
        uint256 tokenId = season.claimPrize(0);
        assertEq(token.balanceOf(bob), before + 10e18);
        assertEq(banners.ownerOf(tokenId), bob);
        Banners.Banner memory b = banners.banner(tokenId);
        assertEq(b.season, 0);
        assertEq(b.guild, 1);
        assertEq(b.kind, banners.KIND_VICTORY());
        assertEq(b.rank, 1);
        assertEq(season.claimable(0, bob), 0);
        vm.prank(bob);
        vm.expectRevert(Season.NothingToClaim.selector);
        season.claimPrize(0);
        vm.prank(erin);
        vm.expectRevert(Season.NothingToClaim.selector);
        season.claimPrize(0);
        vm.prank(dave);
        uint256 third = season.claimPrize(0);
        assertEq(banners.banner(third).rank, 3);
        assertEq(banners.totalMinted(), 2);
        assertEq(token.balanceOf(address(season)), 40e18 - 18e18);
        string memory uri = banners.tokenURI(tokenId);
        assertEq(bytes(uri).length > 0, true);
        assertEq(
            uri,
            "data:application/json;utf8,{\"name\":\"Pacts Victory Banner #1\",\"attributes\":[{\"trait_type\":\"season\",\"value\":0},{\"trait_type\":\"guild\",\"value\":1},{\"trait_type\":\"kind\",\"value\":\"Victory\"},{\"trait_type\":\"rank\",\"value\":1}]}"
        );
    }

    function test_membersJoiningAfterCloseGetNothing() public {
        _playSeasonZero();
        _endSeasonZero();
        season.close(0, 100);
        _join(frank, 1);
        assertEq(season.claimable(0, frank), 0);
        vm.prank(frank);
        vm.expectRevert(Season.NothingToClaim.selector);
        season.claimPrize(0);
    }

    function test_memberLeavingAfterCloseStillClaims() public {
        _playSeasonZero();
        _endSeasonZero();
        season.close(0, 100);
        vm.prank(bob);
        guilds.leave();
        vm.prank(bob);
        season.claimPrize(0);
    }

    function test_closeInChunks() public {
        _playSeasonZero();
        _endSeasonZero();
        season.close(0, 1);
        assertFalse(season.result(0).closed);
        Season.Closing memory c = season.closing(0);
        assertEq(c.cursor, 1);
        assertEq(c.guildCount, 4);
        assertEq(c.top[0], 1);
        _found(frank, "Late"); // founded after the first chunk: never ranked
        season.close(0, 2);
        assertFalse(season.result(0).closed);
        season.close(0, 5);
        assertTrue(season.result(0).closed);
        Season.Result memory r = season.result(0);
        assertEq(r.winners[0], 1);
        assertEq(r.winners[1], 2);
        assertEq(r.winners[2], 3);
    }

    function test_tieBreaksTowardsEarlierGuild() public {
        _found(alice, "Alpha");
        _found(bob, "Beta");
        _found(carol, "Gamma");
        _found(dave, "Delta");
        _buy(alice, 1, 10);
        _buy(bob, 2, 10);
        _buy(carol, 3, 10);
        _buy(dave, 4, 10);
        _attack(dave, 3, 10);
        _attack(carol, 2, 10);
        _attack(bob, 1, 10);
        _attack(alice, 0, 10);
        _endSeasonZero();
        season.close(0, 10);
        Season.Result memory r = season.result(0);
        assertEq(r.winners[0], 1);
        assertEq(r.winners[1], 2);
        assertEq(r.winners[2], 3);
        assertEq(season.claimable(0, dave), 0);
    }

    function test_unassignedSharesRollOver() public {
        _found(alice, "Alpha");
        _found(bob, "Beta");
        _buy(alice, 1, 100);
        _buy(bob, 2, 100);
        _attack(alice, 0, 10);
        _endSeasonZero();
        season.close(0, 10);
        Season.Result memory r = season.result(0);
        assertEq(r.winners[0], 1);
        assertEq(r.winners[1], 0);
        assertEq(r.prizes[0], 10e18);
        assertEq(r.rollover, 10e18);
        assertEq(season.prizePool(1), 10e18);
        // the winner's guild with no members at close also rolls over
        vm.warp(GENESIS + 2 * SEASON);
        _settleAll();
        vm.prank(alice);
        guilds.leave();
        season.close(1, 10);
        r = season.result(1);
        assertEq(r.winners[0], 1);
        assertEq(r.prizes[0], 0);
        assertEq(r.rollover, 10e18);
        assertEq(season.prizePool(2), 10e18);
    }

    function test_noGuildsClosesEmpty() public {
        _endSeasonZero();
        season.close(0, 1);
        assertTrue(season.result(0).closed);
        assertEq(season.result(0).winners[0], 0);
    }

    function test_claimsNeverExceedPool() public {
        _playSeasonZero();
        _endSeasonZero();
        season.close(0, 100);
        address[4] memory claimants = [alice, bob, carol, dave];
        uint256 paid;
        for (uint256 i; i < claimants.length; ++i) {
            uint256 before = token.balanceOf(claimants[i]);
            vm.prank(claimants[i]);
            season.claimPrize(0);
            paid += token.balanceOf(claimants[i]) - before;
        }
        assertEq(paid, 40e18);
        assertEq(token.balanceOf(address(season)), 0);
    }

    function test_recordFeeOnlyFromRealm() public {
        vm.expectRevert(Season.NotRealm.selector);
        season.recordFee(0, 1);
        vm.prank(address(realm));
        season.recordFee(0, 1);
        assertEq(season.prizePool(0), 1);
    }

    function test_onlySeasonMintsBanners() public {
        vm.expectRevert(Banners.NotMinter.selector);
        banners.mint(alice, 0, 1, 1, 1);
        vm.prank(address(season));
        vm.expectRevert(Banners.InvalidKind.selector);
        banners.mint(alice, 0, 1, 3, 1);
        vm.prank(address(season));
        uint256 id = banners.mint(alice, 0, 1, 2, 0);
        assertEq(banners.ownerOf(id), alice);
        assertEq(banners.name(), "Pacts Banner");
        assertEq(banners.symbol(), "BANNER");
        vm.expectRevert();
        banners.banner(99);
    }

    // ------------------------------------------------------------ honour banners

    function _pactBetweenAlphaAndBeta(uint256 duration) internal returns (uint256 pactId) {
        _fund(alice, 1, 10e18);
        _fund(carol, 2, 10e18);
        uint256 pa = _proposePact(alice, 2, duration, 1e18, 1e18);
        _vote(bob, pa, true);
        uint256 pb = _proposePact(carol, 1, duration, 1e18, 1e18);
        vm.prank(carol);
        pactId = diplomacy.signPact(pa, pb);
    }

    function test_honourBannerForUnbrokenPact() public {
        _playSeasonZero();
        _pactBetweenAlphaAndBeta(2); // epochs 1..2 of season 0
        vm.prank(alice);
        vm.expectRevert(Season.SeasonNotEnded.selector);
        season.claimHonourBanner(0, 1);
        _endSeasonZero();
        vm.prank(erin);
        vm.expectRevert(Season.NotMember.selector);
        season.claimHonourBanner(0, 1);
        vm.prank(dave); // Gamma never signed a pact
        vm.expectRevert(Season.NoPactHeld.selector);
        season.claimHonourBanner(0, 3);
        vm.prank(bob);
        uint256 id = season.claimHonourBanner(0, 1);
        assertEq(banners.ownerOf(id), bob);
        Banners.Banner memory b = banners.banner(id);
        assertEq(b.kind, banners.KIND_HONOUR());
        assertEq(b.guild, 1);
        assertEq(b.rank, 0);
        assertTrue(season.honourClaimed(0, 1));
        vm.prank(alice);
        vm.expectRevert(Season.AlreadyClaimed.selector);
        season.claimHonourBanner(0, 1);
        vm.prank(carol);
        season.claimHonourBanner(0, 2);
        // no pact overlapped season 1
        vm.warp(GENESIS + 2 * SEASON);
        vm.prank(carol);
        vm.expectRevert(Season.NoPactHeld.selector);
        season.claimHonourBanner(1, 2);
    }

    function test_honourBannerDeniedToBetrayer() public {
        _playSeasonZero();
        _pactBetweenAlphaAndBeta(3);
        _attack(carol, 0, 5); // Beta attacks Alpha's tile
        _endSeasonZero();
        vm.prank(carol);
        vm.expectRevert(Season.PactWasBroken.selector);
        season.claimHonourBanner(0, 2);
        vm.prank(alice); // the victim kept faith
        season.claimHonourBanner(0, 1);
    }

    function test_honourBannerRequiresGuildFoundedBeforeSeasonEnd() public {
        _playSeasonZero();
        _pactBetweenAlphaAndBeta(2);
        _endSeasonZero();
        vm.prank(bob);
        guilds.leave();
        _found(bob, "New");
        vm.prank(bob);
        vm.expectRevert(Season.GuildTooYoung.selector);
        season.claimHonourBanner(0, 5);
    }

    function test_seasonHelpers() public view {
        assertEq(season.firstEpoch(2), 8);
        assertEq(season.lastEpoch(2), 11);
        assertFalse(season.seasonEnded(0));
        assertEq(season.FIRST_SHARE() + season.SECOND_SHARE() + season.THIRD_SHARE(), 100);
    }

    function testFuzz_prizeSplitNeverExceedsPool(uint8 alphaMembers, uint96 pool) public {
        uint256 n = bound(alphaMembers, 1, 20);
        pool = uint96(bound(pool, 0, 1000e18));
        _found(alice, "Alpha");
        for (uint256 i = 1; i < n; ++i) {
            _join(address(uint160(0x3000 + i)), 1);
        }
        _found(bob, "Beta");
        _buy(alice, 1, 10);
        _buy(bob, 2, 10);
        uint256 p = _proposeAttack(alice, 0, 10);
        for (uint256 i = 1; i < n; ++i) {
            _vote(address(uint160(0x3000 + i)), p, true);
        }
        vm.prank(alice);
        realm.declareAttack(p);
        _attack(bob, 1, 10);
        vm.prank(address(realm));
        season.recordFee(0, pool);
        _endSeasonZero();
        season.close(0, 10);
        Season.Result memory r = season.result(0);
        uint256 total = 2e18 + pool;
        assertEq(r.prizes[0] + r.prizes[1] + r.rollover, total);
        assertEq(r.prizes[0], (total * 50 / 100 / n) * n);
        assertEq(r.prizes[1], total * 30 / 100);
        assertEq(season.claimable(0, alice), total * 50 / 100 / n);
    }
}
