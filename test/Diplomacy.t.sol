// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PactsBase} from "./PactsBase.t.sol";
import {Diplomacy} from "../src/Diplomacy.sol";
import {Realm} from "../src/Realm.sol";
import {GUILD_KIND_ATTACK} from "../src/interfaces/IGuilds.sol";

contract DiplomacyTest is PactsBase {
    uint256 internal constant BOND_A = 40e18;
    uint256 internal constant BOND_B = 25e18;

    /// @dev Alpha (alice) holds tile 0, Beta (bob) holds tile 1, both with funded treasuries.
    function _twoGuildsWithTiles() internal {
        _found(alice, "Alpha");
        _found(bob, "Beta");
        _buy(alice, 1, 50);
        _buy(bob, 2, 50);
        _fund(alice, 1, 100e18);
        _fund(bob, 2, 100e18);
        _attack(alice, 0, 10);
        _attack(bob, 1, 10);
        _nextEpoch();
        _settleAll();
    }

    function _signDefault(uint256 duration) internal returns (uint256 pactId) {
        uint256 pa = _proposePact(alice, 2, duration, BOND_A, BOND_B);
        uint256 pb = _proposePact(bob, 1, duration, BOND_B, BOND_A);
        vm.prank(alice);
        pactId = diplomacy.signPact(pa, pb);
    }

    function test_packingRoundTrip() public view {
        bytes32 data = diplomacy.packPactData(7, 12, 1e27 - 1, 5);
        (uint256 partner, uint256 duration, uint256 own, uint256 other) = diplomacy.unpackPactData(data);
        assertEq(partner, 7);
        assertEq(duration, 12);
        assertEq(own, 1e27 - 1);
        assertEq(other, 5);
    }

    function test_signPactLocksBothBonds() public {
        _twoGuildsWithTiles();
        uint256 id = _signDefault(3);
        assertEq(id, 0);
        Diplomacy.Pact memory p = diplomacy.pact(0);
        assertEq(p.guildA, 1);
        assertEq(p.guildB, 2);
        assertEq(p.bondA, BOND_A);
        assertEq(p.bondB, BOND_B);
        assertEq(p.startEpoch, 1);
        assertEq(p.endEpoch, 3);
        assertFalse(p.settled);
        assertEq(realm.treasury(1), 100e18 - BOND_A);
        assertEq(realm.lockedBonds(1), BOND_A);
        assertEq(realm.treasury(2), 100e18 - BOND_B);
        assertEq(realm.lockedBonds(2), BOND_B);
        assertEq(diplomacy.activePactBetween(1, 2), 1);
        assertEq(diplomacy.activePactBetween(2, 1), 1);
        assertEq(diplomacy.pactsOf(1).length, 1);
        assertEq(diplomacy.pactsOf(2).length, 1);
        assertEq(diplomacy.pactCount(), 1);
        assertTrue(diplomacy.isActive(0));
        assertTrue(diplomacy.hadPactDuring(1, 0, 3));
        assertFalse(diplomacy.hadPactDuring(1, 4, 9));
        assertFalse(diplomacy.betrayedDuring(1, 0, 3));
        _assertRealmSolvent(2, 0);
    }

    function test_signPactRejectsMismatchedTerms() public {
        _twoGuildsWithTiles();
        uint256 pa = _proposePact(alice, 2, 3, BOND_A, BOND_B);
        uint256 wrongBond = _proposePact(bob, 1, 3, BOND_B, BOND_A + 1);
        vm.prank(alice);
        vm.expectRevert(Diplomacy.TermsMismatch.selector);
        diplomacy.signPact(pa, wrongBond);
        uint256 wrongDuration = _proposePact(bob, 1, 4, BOND_B, BOND_A);
        vm.prank(alice);
        vm.expectRevert(Diplomacy.TermsMismatch.selector);
        diplomacy.signPact(pa, wrongDuration);
        _found(carol, "Gamma");
        uint256 wrongPartner = _proposePact(carol, 1, 3, BOND_B, BOND_A);
        vm.prank(alice);
        vm.expectRevert(Diplomacy.TermsMismatch.selector);
        diplomacy.signPact(pa, wrongPartner);
        uint256 selfPact = _proposePact(alice, 1, 3, BOND_A, BOND_A);
        vm.prank(alice);
        vm.expectRevert(Diplomacy.SamePartner.selector);
        diplomacy.signPact(selfPact, selfPact);
        uint256 zeroDuration = _proposePact(bob, 1, 0, BOND_B, BOND_A);
        uint256 zeroDurationA = _proposePact(alice, 2, 0, BOND_A, BOND_B);
        vm.prank(alice);
        vm.expectRevert(Diplomacy.BadDuration.selector);
        diplomacy.signPact(zeroDurationA, zeroDuration);
        uint256 attackProposal = _propose(bob, GUILD_KIND_ATTACK, bytes32(0));
        vm.prank(alice);
        vm.expectRevert(Diplomacy.WrongKind.selector);
        diplomacy.signPact(pa, attackProposal);
    }

    function test_signPactNeedsMajorityMembershipTreasuryAndNoDuplicate() public {
        _twoGuildsWithTiles();
        _join(carol, 2);
        uint256 pa = _proposePact(alice, 2, 3, BOND_A, BOND_B);
        uint256 pb = _proposePact(bob, 1, 3, BOND_B, BOND_A);
        vm.prank(alice);
        vm.expectRevert(Diplomacy.NoMajority.selector);
        diplomacy.signPact(pa, pb);
        _vote(carol, pb, true);
        vm.prank(dave);
        vm.expectRevert(Diplomacy.NotMember.selector);
        diplomacy.signPact(pa, pb);
        vm.prank(carol);
        diplomacy.signPact(pa, pb);
        vm.prank(alice);
        vm.expectRevert(Diplomacy.ProposalUsed.selector);
        diplomacy.signPact(pa, pb);
        uint256 pa2 = _proposePact(alice, 2, 3, 1, 1);
        uint256 pb2 = _proposePact(bob, 1, 3, 1, 1);
        _vote(carol, pb2, true);
        vm.prank(alice);
        vm.expectRevert(Diplomacy.PactExists.selector);
        diplomacy.signPact(pa2, pb2);
        // treasury too small for the bond
        _found(dave, "Delta");
        uint256 pa3 = _proposePact(alice, 3, 3, 100e18, 0);
        uint256 pd = _proposePact(dave, 1, 3, 0, 100e18);
        vm.prank(dave);
        vm.expectRevert(Realm.InsufficientTreasury.selector);
        diplomacy.signPact(pa3, pd);
    }

    function test_betrayalSlashesBondToVictim() public {
        _twoGuildsWithTiles();
        _signDefault(3); // epochs 1..3
        _nextEpoch();
        _settleAll();
        _attack(bob, 0, 5); // Beta attacks Alpha's tile in epoch 2
        (bool byA,, bool byB, uint256 epochB) = diplomacy.betrayalOf(0);
        assertFalse(byA);
        assertTrue(byB);
        assertEq(epochB, 2);
        assertFalse(diplomacy.isActive(0));
        assertTrue(diplomacy.betrayedDuring(2, 0, 3));
        assertFalse(diplomacy.betrayedDuring(1, 0, 3));
        assertFalse(diplomacy.betrayedDuring(2, 3, 3));

        vm.prank(carol); // anyone settles
        diplomacy.settlePact(0);
        Diplomacy.Pact memory p = diplomacy.pact(0);
        assertTrue(p.settled);
        assertEq(p.brokenBy, 2);
        assertEq(realm.lockedBonds(2), 0);
        assertEq(realm.lockedBonds(1), 0);
        assertEq(realm.treasury(1), 100e18 + BOND_B, "victim receives the betrayer's bond and its own back");
        assertEq(realm.treasury(2), 100e18 - BOND_B);
        assertEq(diplomacy.activePactBetween(1, 2), 0);
        vm.expectRevert(Diplomacy.AlreadySettled.selector);
        diplomacy.settlePact(0);
        _assertRealmSolvent(2, 0);
    }

    function test_retaliationIsNotBetrayal() public {
        _twoGuildsWithTiles();
        _signDefault(4); // epochs 1..4
        _attack(alice, 1, 5); // Alpha betrays in epoch 1
        _nextEpoch();
        _settleAll();
        _attack(bob, 0, 5); // Beta strikes back in epoch 2
        (bool byA, uint256 epochA, bool byB,) = diplomacy.betrayalOf(0);
        assertTrue(byA);
        assertEq(epochA, 1);
        assertFalse(byB);
        assertTrue(diplomacy.hadPactDuring(1, 1, 1));
        assertFalse(diplomacy.hadPactDuring(1, 2, 4), "pact effectively ended at the betrayal");
        diplomacy.settlePact(0);
        assertEq(diplomacy.pact(0).brokenBy, 1);
        assertEq(realm.treasury(2), 100e18 + BOND_A);
        assertEq(realm.treasury(1), 100e18 - BOND_A);
    }

    function test_mutualBetrayalInSameEpochSlashesBoth() public {
        _twoGuildsWithTiles();
        _signDefault(3);
        _attack(alice, 1, 5);
        _attack(bob, 0, 5);
        diplomacy.settlePact(0);
        assertEq(diplomacy.pact(0).brokenBy, 3);
        assertEq(realm.treasury(1), 100e18 - BOND_A + BOND_B);
        assertEq(realm.treasury(2), 100e18 - BOND_B + BOND_A);
        assertEq(realm.lockedBonds(1), 0);
        assertEq(realm.lockedBonds(2), 0);
        _assertRealmSolvent(2, 0);
    }

    function test_expiryReturnsBonds() public {
        _twoGuildsWithTiles();
        _signDefault(2); // epochs 1..2
        vm.expectRevert(Diplomacy.PactStillActive.selector);
        diplomacy.settlePact(0);
        vm.warp(GENESIS + 3 * EPOCH); // epoch 3
        _settleAll();
        assertFalse(diplomacy.isActive(0));
        diplomacy.settlePact(0);
        Diplomacy.Pact memory p = diplomacy.pact(0);
        assertTrue(p.settled);
        assertEq(p.brokenBy, 0);
        assertEq(realm.treasury(1), 100e18);
        assertEq(realm.treasury(2), 100e18);
        assertEq(realm.lockedBonds(1), 0);
        assertEq(realm.lockedBonds(2), 0);
        // an attack after expiry is not a betrayal and a new pact can be signed
        _attack(bob, 0, 5);
        (bool byA,, bool byB,) = diplomacy.betrayalOf(0);
        assertFalse(byA || byB);
        uint256 id = _signDefault(1);
        assertEq(id, 1);
        assertEq(diplomacy.pact(1).logBA, 1, "log snapshot skips the earlier attack");
        _assertRealmSolvent(2, 0);
    }

    function test_attacksOnOthersOrEmptyTilesAreNotBetrayal() public {
        _twoGuildsWithTiles();
        _found(carol, "Gamma");
        _buy(carol, 3, 20);
        _attack(carol, 5, 10);
        _nextEpoch();
        _settleAll();
        _signDefault(3);
        _attack(alice, 5, 5); // Gamma's tile
        _attack(bob, 7, 5); // empty tile
        (bool byA,, bool byB,) = diplomacy.betrayalOf(0);
        assertFalse(byA);
        assertFalse(byB);
        assertTrue(diplomacy.isActive(0));
    }

    function test_unknownPactReverts() public {
        vm.expectRevert(Diplomacy.NoSuchPact.selector);
        diplomacy.pact(0);
        vm.expectRevert(Diplomacy.NoSuchPact.selector);
        diplomacy.settlePact(0);
        vm.expectRevert(Diplomacy.NoSuchPact.selector);
        diplomacy.betrayalOf(0);
        assertFalse(diplomacy.isActive(0));
    }

    function testFuzz_bondAccounting(uint96 bondA, uint96 bondB, bool betray) public {
        bondA = uint96(bound(bondA, 0, 100e18));
        bondB = uint96(bound(bondB, 0, 100e18));
        _twoGuildsWithTiles();
        uint256 pa = _proposePact(alice, 2, 2, bondA, bondB);
        uint256 pb = _proposePact(bob, 1, 2, bondB, bondA);
        vm.prank(bob);
        diplomacy.signPact(pa, pb);
        assertEq(realm.lockedBonds(1), bondA);
        assertEq(realm.lockedBonds(2), bondB);
        if (betray) {
            _attack(alice, 1, 1);
        } else {
            vm.warp(GENESIS + 3 * EPOCH);
        }
        diplomacy.settlePact(0);
        assertEq(realm.lockedBonds(1) + realm.lockedBonds(2), 0);
        assertEq(realm.treasury(1) + realm.treasury(2), 200e18, "bonds only move between the two treasuries");
        assertEq(realm.treasury(2), betray ? 100e18 + uint256(bondA) : 100e18);
        _assertRealmSolvent(2, 0);
    }
}
