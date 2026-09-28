// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {Guilds} from "src/Guilds.sol";
import {Realm} from "src/Realm.sol";
import {Diplomacy} from "src/Diplomacy.sol";
import {Season} from "src/Season.sol";
import {Banners} from "src/Banners.sol";

/// @dev All funds originate in the fixed supply, with no deal(), privileged writes or mock fees.
/// Four-epoch seasons let random sequences cross several season boundaries. No external tokens
/// or arbitrary recipients are used, making the set of token holders enumerable.
contract PactsHandler is Test {
    LaunchToken public immutable token;
    Guilds public immutable guilds;
    Realm public immutable realm;
    Diplomacy public immutable diplomacy;
    Season public immutable season;
    Banners public immutable banners;
    address[6] public actors;
    uint256 public paidIn;
    uint256 public treasuryPaid;
    uint256 public fees;
    uint256 public prizesPaid;
    uint256 public realmDonations;
    uint256 public seasonDonations;
    uint256 public troopsBought;
    uint256 public trophies;
    uint256 public successfulAttacks;
    uint256 public signedPacts;
    uint256 public refusedPacts;
    uint256 public refusedHonours;
    uint256 public settledPacts;
    uint256 public closedSeasons;
    uint256 public zeroPrizeClaims;
    mapping(uint256 => bytes32) public closedResult;
    mapping(uint256 => bytes32) public settledPact;

    constructor(LaunchToken token_, Guilds guilds_, Realm realm_) {
        token = token_;
        guilds = guilds_;
        realm = realm_;
        diplomacy = realm_.diplomacy();
        season = realm_.season();
        banners = season.banners();
        for (uint256 i; i < 6; ++i) {
            actors[i] = address(uint160(0x1000 + i));
        }
    }

    function buy(uint256 actorSeed, uint256 countSeed, bool useTreasury) public {
        address actor = actors[actorSeed % 6];
        uint256 g = guilds.guildOf(actor);
        if (g == 0) return;
        uint256 available = useTreasury ? realm.treasury(g) + realm.pendingIncome(g) : token.balanceOf(actor);
        uint256 maxCount = available / realm.troopPrice();
        if (maxCount == 0) return;
        uint256 count = bound(countSeed, 1, min(maxCount, 1000));
        uint256 cost = count * realm.troopPrice();
        uint256 fee = cost * realm.feeBps() / 10_000;
        uint256 troopsBefore = realm.troops(g);
        if (useTreasury) {
            uint256 p = _approve(g, 5, bytes32(count));
            vm.prank(actor);
            realm.buyTroopsFromTreasury(p);
            assertTrue(realm.proposalUsed(p));
            assertEq(realm.treasury(g), available - cost, "treasury purchase charges exactly the cost");
            assertEq(realm.pendingIncome(g), 0, "treasury purchase harvests first");
        } else {
            vm.prank(actor);
            realm.buyTroops(g, count);
            paidIn += cost;
        }
        assertEq(realm.troops(g), troopsBefore + count);
        fees += fee;
        troopsBought += count;
    }

    function fund(uint256 actorSeed, uint256 amountSeed) public {
        address actor = actors[actorSeed % 6];
        uint256 g = guilds.guildOf(actor);
        uint256 balance = token.balanceOf(actor);
        if (g == 0 || balance == 0) return;
        uint256 amount = bound(amountSeed, 1, min(balance, 100e18));
        vm.prank(actor);
        realm.fundTreasury(g, amount);
        paidIn += amount;
    }

    function donate(uint256 actorSeed, uint256 amountSeed, bool toSeason) external {
        address actor = actors[actorSeed % 6];
        uint256 balance = token.balanceOf(actor);
        if (balance == 0) return;
        uint256 amount = bound(amountSeed, 1, min(balance, 1e18));
        vm.prank(actor);
        token.transfer(toSeason ? address(season) : address(realm), amount);
        if (toSeason) seasonDonations += amount;
        else realmDonations += amount;
    }

    function attack(uint256 actorSeed, uint256 tileSeed, uint256 countSeed) public {
        if (realm.currentEpoch() != realm.settledEpoch()) return;
        address actor = actors[actorSeed % 6];
        uint256 g = guilds.guildOf(actor);
        uint256 tile = tileSeed % 144;
        if (g == 0 || realm.holder(tile) == g || realm.troops(g) == 0) return;
        if (realm.hasAttacked(realm.currentEpoch(), g, tile)) return;
        uint256 force = bound(countSeed, 1, realm.troops(g));
        uint256 p = _approve(g, 2, realm.packAttackData(tile, force));
        vm.prank(actor);
        realm.declareAttack(p);
        ++successfulAttacks;
    }

    function reinforce(uint256 tileSeed, uint256 countSeed) external {
        if (realm.currentEpoch() != realm.settledEpoch()) return;
        uint256 tile = tileSeed % 144;
        uint256 g = realm.holder(tile);
        address[] memory members = guilds.membersOf(g);
        if (members.length == 0 || realm.troops(g) == 0) return;
        uint256 amount = bound(countSeed, 1, realm.troops(g));
        uint256 garrisonBefore = realm.garrison(tile);
        uint256 p = _approve(g, 6, realm.packReinforceData(tile, amount));
        vm.prank(members[0]);
        realm.reinforce(p);
        assertTrue(realm.proposalUsed(p));
        assertEq(realm.garrison(tile), garrisonBefore + amount);
        vm.prank(members[0]);
        vm.expectRevert(Realm.ProposalUsed.selector);
        realm.reinforce(p);
    }

    function advance(uint256 secondsSeed) public {
        vm.warp(block.timestamp + bound(secondsSeed, 1, 2 hours));
    }

    function settle(uint256 budgetSeed) public {
        uint256 beforeEpoch = realm.settledEpoch();
        realm.settle(bound(budgetSeed, 1, 160));
        assertGe(realm.settledEpoch(), beforeEpoch, "settlement cannot rewind");
        assertLe(realm.settledEpoch(), realm.currentEpoch(), "no future settlement");
    }

    function harvest(uint256 guildSeed) external {
        uint256 g = guildSeed % 3 + 1;
        realm.harvest(g);
        uint256 treasury = realm.treasury(g);
        realm.harvest(g);
        assertEq(realm.treasury(g), treasury, "harvest twice must not pay twice");
        assertEq(realm.pendingIncome(g), 0);
    }

    function distribute(uint256 guildSeed) public {
        uint256 g = guildSeed % 3 + 1;
        address[] memory members = guilds.membersOf(g);
        if (members.length == 0) return;
        uint256 each = (realm.treasury(g) + realm.pendingIncome(g)) / members.length;
        if (each == 0) return;
        uint256 p = _approve(g, 4, bytes32(0));
        uint256[] memory beforeBalances = new uint256[](members.length);
        for (uint256 i; i < members.length; ++i) {
            beforeBalances[i] = token.balanceOf(members[i]);
        }
        vm.prank(members[0]);
        realm.distributeTreasury(p);
        for (uint256 i; i < members.length; ++i) {
            assertEq(token.balanceOf(members[i]), beforeBalances[i] + each);
        }
        assertTrue(realm.proposalUsed(p));
        treasuryPaid += each * members.length;
    }

    function sign(uint256 guildSeed, uint256 partnerSeed, uint256 bondSeed, uint256 durationSeed) public {
        uint256 a = guildSeed % 3 + 1;
        uint256 b = (a + partnerSeed % 2) % 3 + 1;
        address[] memory membersA = guilds.membersOf(a);
        if (membersA.length == 0 || guilds.memberCount(b) == 0) return;
        if (diplomacy.activePactBetween(a, b) != 0) return;
        uint256 minBond = realm.troopPrice();
        uint256 availableA = realm.treasury(a) + realm.pendingIncome(a);
        uint256 availableB = realm.treasury(b) + realm.pendingIncome(b);
        if (availableA < minBond || availableB < minBond) return;
        uint256 bondA = bound(bondSeed, minBond, min(availableA, 10e18));
        uint256 bondB = bound(bondSeed >> 128, minBond, min(availableB, 10e18));
        uint256 duration = bound(durationSeed, 1, 4);
        uint256 pa = _approve(a, 3, diplomacy.packPactData(b, duration, bondA, bondB));
        uint256 pb = _approve(b, 3, diplomacy.packPactData(a, duration, bondB, bondA));
        if (_attackInFlightBetween(a, b)) {
            _expectSigningRefused(membersA[0], pa, pb);
            assertEq(realm.treasury(a) + realm.pendingIncome(a), availableA);
            assertEq(realm.treasury(b) + realm.pendingIncome(b), availableB);
            return;
        }
        vm.prank(membersA[0]);
        uint256 id = diplomacy.signPact(pa, pb);
        assertEq(diplomacy.pact(id).signedAt, block.timestamp);
        assertEq(diplomacy.pact(id).endEpoch, realm.currentEpoch() + duration - 1);
        assertEq(realm.treasury(a) + realm.pendingIncome(a), availableA - bondA, "bond A leaves the treasury");
        assertEq(realm.treasury(b) + realm.pendingIncome(b), availableB - bondB, "bond B leaves the treasury");
        ++signedPacts;
    }

    /// @dev An attack between the two declared this epoch has not resolved: signing must be
    /// refused without consuming the votes.
    function _expectSigningRefused(address signer, uint256 pa, uint256 pb) private {
        uint256 pacts = diplomacy.pactCount();
        vm.prank(signer);
        vm.expectRevert(Diplomacy.AttackInFlight.selector);
        diplomacy.signPact(pa, pb);
        assertEq(diplomacy.pactCount(), pacts);
        assertFalse(diplomacy.proposalUsed(pa));
        assertFalse(diplomacy.proposalUsed(pb));
        ++refusedPacts;
    }

    function _attackInFlightBetween(uint256 a, uint256 b) private view returns (bool) {
        uint256 epoch = realm.currentEpoch();
        return _lastAttackIn(a, b, epoch) || _lastAttackIn(b, a, epoch);
    }

    function _lastAttackIn(uint256 attacker, uint256 defender, uint256 epoch) private view returns (bool) {
        uint256 n = realm.attackLogLength(attacker, defender);
        return n != 0 && realm.attackLogAt(attacker, defender, n - 1) == epoch;
    }

    function settlePact(uint256 pactSeed) public {
        uint256 count = diplomacy.pactCount();
        if (count == 0) return;
        uint256 id = pactSeed % count;
        Diplomacy.Pact memory p = diplomacy.pact(id);
        if (p.settled) return;
        (bool a, uint256 epochA, bool b, uint256 epochB) = diplomacy.betrayalOf(id);
        uint256 current = realm.currentEpoch();
        if ((!a && !b && current <= p.endEpoch) || (a && current == epochA) || (b && current == epochB)) {
            uint256 treasuryA = realm.treasury(p.guildA);
            uint256 treasuryB = realm.treasury(p.guildB);
            uint256 lockedA = realm.lockedBonds(p.guildA);
            uint256 lockedB = realm.lockedBonds(p.guildB);
            vm.expectRevert(Diplomacy.PactStillActive.selector);
            diplomacy.settlePact(id);
            assertEq(keccak256(abi.encode(diplomacy.pact(id))), keccak256(abi.encode(p)));
            assertEq(realm.treasury(p.guildA), treasuryA);
            assertEq(realm.treasury(p.guildB), treasuryB);
            assertEq(realm.lockedBonds(p.guildA), lockedA);
            assertEq(realm.lockedBonds(p.guildB), lockedB);
            assertEq(diplomacy.activePactBetween(p.guildA, p.guildB), id + 1);
            assertEq(diplomacy.activePactBetween(p.guildB, p.guildA), id + 1);
            return;
        }
        diplomacy.settlePact(id);
        settledPact[id] = keccak256(abi.encode(diplomacy.pact(id)));
        ++settledPacts;
    }

    function close(uint256 seasonSeed, uint256 budgetSeed) public {
        uint256 ended = realm.settledEpoch() / realm.epochsPerSeason();
        if (ended == 0) return;
        uint256 id = seasonSeed % ended;
        if (season.result(id).closed) return;
        uint256 budget = bound(budgetSeed, 1, 3);
        if (id != 0 && !season.result(id - 1).closed) {
            bytes32 beforeClosing = keccak256(abi.encode(season.closing(id)));
            uint256 beforePool = season.prizePool(id);
            vm.expectRevert(Season.PreviousSeasonNotClosed.selector);
            season.close(id, budget);
            assertEq(keccak256(abi.encode(season.closing(id))), beforeClosing);
            assertEq(season.prizePool(id), beforePool);
            assertFalse(season.result(id).closed);
            return;
        }
        season.close(id, budget);
        Season.Result memory r = season.result(id);
        if (r.closed) {
            assertEq(r.prizes[0] + r.prizes[1] + r.prizes[2] + r.rollover, season.prizePool(id));
            closedResult[id] = keccak256(abi.encode(r));
            ++closedSeasons;
        }
    }

    function claim(uint256 actorSeed, uint256 seasonSeed) public {
        uint256 ended = realm.settledEpoch() / realm.epochsPerSeason();
        if (ended == 0) return;
        address actor = actors[actorSeed % 6];
        uint256 id = seasonSeed % ended;
        uint256 amount = season.claimable(id, actor);
        uint8 rank = season.claimRank(id, actor);
        if (rank == 0) return;
        uint256 winner = season.result(id).winners[rank - 1];
        uint256 beforeBalance = token.balanceOf(actor);
        vm.prank(actor);
        uint256 nft = season.claimPrize(id);
        assertEq(token.balanceOf(actor), beforeBalance + amount);
        assertEq(season.claimable(id, actor), 0);
        assertEq(season.claimRank(id, actor), 0);
        assertEq(banners.ownerOf(nft), actor);
        assertEq(banners.banner(nft).season, id);
        assertEq(banners.banner(nft).kind, 1);
        assertEq(banners.banner(nft).rank, rank);
        assertEq(banners.banner(nft).guild, winner);
        prizesPaid += amount;
        if (amount == 0) ++zeroPrizeClaims;
        ++trophies;
        vm.prank(actor);
        vm.expectRevert(Season.NothingToClaim.selector);
        season.claimPrize(id);
    }

    function honour(uint256 guildSeed, uint256 seasonSeed) external {
        uint256 ended = realm.currentEpoch() / realm.epochsPerSeason();
        if (ended == 0) return;
        uint256 id = seasonSeed % ended;
        uint256 g = guildSeed % 3 + 1;
        address[] memory members = guilds.membersOf(g);
        if (members.length == 0 || season.honourClaimed(id, g)) return;
        if (!diplomacy.hadPactDuring(g, season.firstEpoch(id), season.lastEpoch(id))) return;
        if (diplomacy.betrayedDuring(g, season.firstEpoch(id), season.lastEpoch(id))) return;
        address claimant = members[0];
        if (guilds.joinedAt(g, claimant) >= realm.seasonEndTime(id)) {
            // Joined after the season ended: the guild's honour is not this member's to claim.
            vm.prank(claimant);
            vm.expectRevert(Season.JoinedAfterSeason.selector);
            season.claimHonourBanner(id, g);
            assertFalse(season.honourClaimed(id, g));
            ++refusedHonours;
            return;
        }
        vm.prank(claimant);
        uint256 nft = season.claimHonourBanner(id, g);
        ++trophies;
        assertEq(banners.ownerOf(nft), claimant);
        assertEq(banners.banner(nft).guild, g);
        assertEq(banners.banner(nft).season, id);
        assertEq(banners.banner(nft).kind, 2);
        assertTrue(season.honourClaimed(id, g));
        vm.prank(claimant);
        vm.expectRevert(Season.AlreadyClaimed.selector);
        season.claimHonourBanner(id, g);
    }

    function transferBanner(uint256 tokenSeed, uint256 recipientSeed, bool useApproval) external {
        uint256 minted = banners.totalMinted();
        if (minted == 0) return;
        uint256 id = tokenSeed % minted + 1;
        address owner = banners.ownerOf(id);
        address recipient = actors[recipientSeed % 6];
        bytes32 metadata = keccak256(abi.encode(banners.banner(id)));
        if (useApproval) {
            vm.prank(owner);
            banners.approve(address(this), id);
            banners.transferFrom(owner, recipient, id);
        } else {
            vm.prank(owner);
            banners.transferFrom(owner, recipient, id);
        }
        assertEq(banners.ownerOf(id), recipient);
        assertEq(banners.getApproved(id), address(0), "transfer clears approval");
        assertEq(keccak256(abi.encode(banners.banner(id))), metadata, "transfer changes trophy history");
    }

    function membership(uint256 actorSeed, uint256 guildSeed) external {
        address actor = actors[actorSeed % 6];
        uint256 g = guildSeed % 3 + 1;
        if (guilds.guildOf(actor) != 0) {
            vm.prank(actor);
            guilds.leave();
        }
        if (!guilds.banned(g, actor)) {
            vm.prank(actor);
            guilds.join(g);
        }
    }

    function vote(uint256 actorSeed, uint256 proposalSeed, bool support) external {
        uint256 count = guilds.proposalCount();
        if (count == 0) return;
        uint256 p = proposalSeed % count + 1;
        address actor = actors[actorSeed % 6];
        if (guilds.guildOf(actor) != guilds.proposal(p).guild) return;
        vm.prank(actor);
        guilds.vote(p, support);
    }

    function expel(uint256 guildSeed) external {
        uint256 g = guildSeed % 3 + 1;
        address[] memory members = guilds.membersOf(g);
        if (members.length < 2) return;
        address target = members[members.length - 1];
        uint256 p = _approve(g, 1, bytes32(uint256(uint160(target))));
        vm.prank(members[0]);
        guilds.executeExpel(p);
        assertEq(guilds.guildOf(target), 0);
        assertTrue(guilds.banned(g, target));
        vm.prank(target);
        vm.expectRevert(Guilds.MemberBanned.selector);
        guilds.join(g);
    }

    function _approve(uint256 g, uint8 kind, bytes32 data) private returns (uint256 p) {
        address[] memory members = guilds.membersOf(g);
        vm.prank(members[0]);
        p = guilds.propose(kind, data);
        for (uint256 i = 1; i < members.length; ++i) {
            vm.prank(members[i]);
            guilds.vote(p, true);
        }
    }

    function min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract PactsInvariantTest is StdInvariant, Test {
    LaunchToken internal token;
    Guilds internal guilds;
    Realm internal realm;
    Diplomacy internal diplomacy;
    Season internal season;
    Banners internal banners;
    PactsHandler internal handler;

    function setUp() public {
        vm.warp(1_700_000_000);
        token = new LaunchToken();
        guilds = new Guilds();
        realm = new Realm(address(token), address(guilds), 1 hours, 4 hours, 1e18, 1000);
        diplomacy = realm.diplomacy();
        season = realm.season();
        banners = season.banners();
        handler = new PactsHandler(token, guilds, realm);
        for (uint256 i; i < 6; ++i) {
            address actor = handler.actors(i);
            token.transfer(actor, 1_000_000e18);
            vm.startPrank(actor);
            token.approve(address(realm), type(uint256).max);
            if (i < 3) guilds.found(bytes32(i + 1));
            else guilds.join(i - 2);
            vm.stopPrank();
        }
        // Seed active custody, competing armies, an outstanding pact and a claimable prize.
        // Random calls then operate on populated state even when no later setup call is chosen.
        for (uint256 i; i < 3; ++i) {
            handler.buy(i, 100, false);
            handler.fund(i, 100e18);
            handler.attack(i, i, 10);
        }
        handler.advance(1 hours);
        handler.settle(160);
        handler.sign(0, 0, 10e18, 4);
        handler.advance(2 hours);
        handler.advance(1 hours);
        handler.settle(160);
        handler.close(0, 3);
        handler.claim(0, 0);

        bytes4[] memory selectors = new bytes4[](18);
        selectors[0] = handler.buy.selector;
        selectors[1] = handler.fund.selector;
        selectors[2] = handler.donate.selector;
        selectors[3] = handler.attack.selector;
        selectors[4] = handler.reinforce.selector;
        selectors[5] = handler.advance.selector;
        selectors[6] = handler.settle.selector;
        selectors[7] = handler.harvest.selector;
        selectors[8] = handler.distribute.selector;
        selectors[9] = handler.sign.selector;
        selectors[10] = handler.settlePact.selector;
        selectors[11] = handler.close.selector;
        selectors[12] = handler.claim.selector;
        selectors[13] = handler.membership.selector;
        selectors[14] = handler.vote.selector;
        selectors[15] = handler.expel.selector;
        selectors[16] = handler.honour.selector;
        selectors[17] = handler.transferBanner.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_fixedSupplyAndCompleteTokenHolderSet() public view {
        uint256 sum =
            token.balanceOf(address(this)) + token.balanceOf(address(realm)) + token.balanceOf(address(season));
        for (uint256 i; i < 6; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, 1_000_000_000e18);
        assertEq(token.totalSupply(), 1_000_000_000e18);
    }

    function invariant_onlyRecordedPaymentsMoveCustodiedTokens() public view {
        assertEq(
            token.balanceOf(address(realm)) + handler.treasuryPaid() + handler.fees(),
            handler.paidIn() + handler.realmDonations()
        );
        assertEq(token.balanceOf(address(season)) + handler.prizesPaid(), handler.fees() + handler.seasonDonations());
        uint256 outstandingPrizes;
        for (uint256 s; s <= realm.currentEpoch() / 4; ++s) {
            for (uint256 i; i < 6; ++i) {
                outstandingPrizes += season.claimable(s, handler.actors(i));
            }
        }
        assertLe(outstandingPrizes, token.balanceOf(address(season)), "all assigned prizes are backed");
        assertEq(banners.totalMinted(), handler.trophies());
        uint256 nftBalances;
        for (uint256 i; i < 6; ++i) {
            nftBalances += banners.balanceOf(handler.actors(i));
        }
        assertEq(nftBalances, handler.trophies(), "NFT balances must match actual mints");
    }

    function invariant_realmBalanceExactlyBacksAllLiabilities() public view {
        uint256 owed = realm.carriedIncome();
        for (uint256 g = 1; g <= 3; ++g) {
            owed += realm.treasury(g) + realm.pendingIncome(g) + realm.lockedBonds(g);
        }
        // Income is distributed before the first battle. A partially settled epoch's
        // historical incomePool is already represented in treasuries/pending income/carry.
        uint256 firstUncredited = realm.settledEpoch();
        if (realm.settleCursor() != 0) ++firstUncredited;
        for (uint256 e = firstUncredited; e <= realm.currentEpoch(); ++e) {
            owed += realm.incomePool(e);
        }
        assertEq(token.balanceOf(address(realm)), owed + handler.realmDonations(), "unbacked or lost income");
    }

    function invariant_seasonBalanceExactlyBacksPrizesAndOpenPools() public view {
        uint256 owed;
        for (uint256 s; s <= realm.currentEpoch() / realm.epochsPerSeason(); ++s) {
            if (!season.result(s).closed) owed += season.prizePool(s);
            for (uint256 i; i < 6; ++i) {
                owed += season.claimable(s, handler.actors(i));
            }
        }
        assertEq(token.balanceOf(address(season)), owed + handler.seasonDonations(), "unbacked or stranded prizes");
    }

    function invariant_mapAndTroopsAreConserved() public view {
        uint256[4] memory tiles;
        uint256 liveTroops;
        uint256[144] memory map = realm.map();
        for (uint256 t; t < 144; ++t) {
            uint256 holder = realm.holder(t);
            assertEq(map[t], holder);
            if (holder != 0) ++tiles[holder];
            else assertEq(realm.garrison(t), 0, "unheld tile has no army");
            liveTroops += realm.garrison(t);
        }
        for (uint256 g = 1; g <= 3; ++g) {
            assertEq(realm.tilesHeld(g), tiles[g]);
            liveTroops += realm.troops(g);
        }
        assertEq(realm.totalTilesHeld(), tiles[1] + tiles[2] + tiles[3]);
        for (uint256 i; i < realm.attackCount(); ++i) {
            Realm.Attack memory a = realm.attack(i);
            if (a.epoch < realm.settledEpoch()) assertTrue(a.resolved, "finished epoch has unresolved attack");
            if (a.resolved) assertLt(a.epoch, realm.currentEpoch(), "live epoch resolved early");
            if (!a.resolved) liveTroops += a.troops;
            else assertLe(a.survivors, a.troops);
        }
        assertLe(liveTroops, handler.troopsBought(), "combat cannot create troops");
    }

    function invariant_bondsExactlyMatchUnsettledPacts() public view {
        uint256[4] memory bonds;
        for (uint256 id; id < diplomacy.pactCount(); ++id) {
            Diplomacy.Pact memory p = diplomacy.pact(id);
            if (p.settled) {
                assertEq(keccak256(abi.encode(p)), handler.settledPact(id), "settled pact changed");
            } else {
                bonds[p.guildA] += p.bondA;
                bonds[p.guildB] += p.bondB;
                assertEq(diplomacy.activePactBetween(p.guildA, p.guildB), id + 1);
                assertEq(diplomacy.activePactBetween(p.guildB, p.guildA), id + 1);
            }
        }
        for (uint256 g = 1; g <= 3; ++g) {
            assertEq(realm.lockedBonds(g), bonds[g]);
        }
    }

    function invariant_membershipAndVotesAgree() public view {
        for (uint256 g = 1; g <= 3; ++g) {
            address[] memory members = guilds.membersOf(g);
            assertEq(members.length, guilds.memberCount(g));
            for (uint256 i; i < members.length; ++i) {
                assertEq(guilds.guildOf(members[i]), g);
                assertFalse(guilds.banned(g, members[i]));
                for (uint256 j; j < i; ++j) {
                    assertTrue(members[i] != members[j]);
                }
            }
        }
        for (uint256 i; i < 6; ++i) {
            address actor = handler.actors(i);
            uint256 g = guilds.guildOf(actor);
            if (g == 0) continue;
            address[] memory members = guilds.membersOf(g);
            uint256 occurrences;
            for (uint256 j; j < members.length; ++j) {
                if (members[j] == actor) ++occurrences;
            }
            assertEq(occurrences, 1);
        }
        for (uint256 p = 1; p <= guilds.proposalCount(); ++p) {
            uint256 g = guilds.proposal(p).guild;
            uint256 yes;
            for (uint256 i; i < 6; ++i) {
                address actor = handler.actors(i);
                if (guilds.guildOf(actor) == g && guilds.votes(p, actor) == 1) ++yes;
            }
            assertEq(guilds.yesVotes(p), yes, "former members cannot supply votes");
            assertEq(guilds.hasMajority(p), yes > guilds.memberCount(g) / 2);
        }
    }

    function invariant_closedResultsNeverChange() public view {
        for (uint256 s; s <= realm.currentEpoch() / 4; ++s) {
            bytes32 frozen = handler.closedResult(s);
            if (frozen != 0) {
                Season.Result memory r = season.result(s);
                assertTrue(r.closed);
                assertEq(keccak256(abi.encode(r)), frozen);
                assertEq(season.prizePool(s), r.prizes[0] + r.prizes[1] + r.prizes[2] + r.rollover);
                if (s != 0) assertTrue(season.result(s - 1).closed, "closed seasons form a prefix");
            }
        }
    }

    function test_handlerRejectsEarlyPactSettlementAndIncludesCounterattack() public {
        uint256 treasuryA = realm.treasury(1);
        uint256 treasuryB = realm.treasury(2);
        Diplomacy.Pact memory p = diplomacy.pact(0);
        handler.attack(0, 1, 1);
        handler.settlePact(0); // Must test PactStillActive, not swallow an arbitrary failure.
        assertFalse(diplomacy.pact(0).settled);
        assertEq(handler.settledPacts(), 0);
        handler.attack(1, 0, 1);
        handler.settlePact(0);
        assertFalse(diplomacy.pact(0).settled);
        handler.advance(1 hours);
        handler.settlePact(0); // Does not require battle settlement.
        assertEq(diplomacy.pact(0).brokenBy, 3);
        assertEq(handler.settledPacts(), 1);
        assertEq(realm.treasury(1), treasuryA + p.bondB);
        assertEq(realm.treasury(2), treasuryB + p.bondA);
        invariant_bondsExactlyMatchUnsettledPacts();
        invariant_realmBalanceExactlyBacksAllLiabilities();
    }

    function test_handlerRefusesSigningOverAnInFlightAttackThenSignsAfterSettlement() public {
        handler.attack(0, 2, 1); // guild 1 attacks guild 3's tile this epoch
        handler.sign(0, 1, 10e18, 2); // guilds 1 and 3: must be refused with AttackInFlight
        assertEq(handler.refusedPacts(), 1);
        assertEq(handler.signedPacts(), 1);
        assertEq(diplomacy.pactCount(), 1);
        handler.advance(1 hours);
        handler.settle(160);
        handler.sign(0, 1, 10e18, 2);
        assertEq(handler.signedPacts(), 2);
        assertEq(diplomacy.pact(1).logAB, 1, "the resolved attack is outside the snapshot");
        (bool byA,, bool byB,) = diplomacy.betrayalOf(1);
        assertFalse(byA || byB);
        invariant_bondsExactlyMatchUnsettledPacts();
        invariant_realmBalanceExactlyBacksAllLiabilities();
    }

    function test_handlerRefusesHonourBannerToPostSeasonJoiner() public {
        // Guild 1 held a pact in season 0. Both of its members leave and rejoin at the season
        // end, so its first member is now a post-season joiner and the guild cannot claim.
        handler.membership(0, 0);
        handler.membership(3, 0);
        assertEq(guilds.memberCount(1), 2);
        assertGe(guilds.joinedAt(1, handler.actors(0)), realm.seasonEndTime(0));
        handler.honour(0, 0);
        assertEq(handler.refusedHonours(), 1);
        assertFalse(season.honourClaimed(0, 1));
        assertEq(banners.totalMinted(), handler.trophies());
    }

    function test_handlerRejectsOutOfOrderCloseThenCatchesUpInChunks() public {
        for (uint256 i; i < 4; ++i) {
            handler.advance(2 hours);
        }
        handler.settle(160);
        assertEq(realm.settledEpoch(), 12);
        handler.close(2, 3);
        assertFalse(season.result(2).closed);
        assertEq(season.closing(2).cursor, 0);
        handler.close(1, 1);
        assertEq(season.closing(1).cursor, 1);
        handler.close(2, 3);
        assertFalse(season.result(2).closed);
        assertEq(season.closing(2).guildCount, 0);
        handler.close(1, 2);
        handler.close(2, 3);
        assertEq(handler.closedSeasons(), 3);
        invariant_closedResultsNeverChange();
        invariant_seasonBalanceExactlyBacksPrizesAndOpenPools();
    }

    function test_handlerClaimsZeroPrizeAfterChangingGuild() public {
        handler.advance(2 hours);
        handler.advance(2 hours);
        handler.settle(160);
        handler.close(1, 3);
        address actor = handler.actors(0);
        assertEq(season.prizePool(1), 0);
        assertEq(season.claimable(1, actor), 0);
        assertEq(season.claimRank(1, actor), 1);
        handler.membership(0, 1); // Guild 2, after winning as a member of guild 1.
        assertEq(guilds.guildOf(actor), 2);
        uint256 minted = banners.totalMinted();
        uint256 balance = token.balanceOf(actor);
        handler.claim(0, 1);
        assertEq(handler.zeroPrizeClaims(), 1);
        assertEq(banners.totalMinted(), minted + 1);
        assertEq(banners.ownerOf(minted + 1), actor);
        assertEq(banners.banner(minted + 1).guild, 1);
        assertEq(banners.banner(minted + 1).rank, 1);
        assertEq(token.balanceOf(actor), balance);
        assertEq(season.claimRank(1, actor), 0);
        vm.prank(actor);
        vm.expectRevert(Season.NothingToClaim.selector);
        season.claimPrize(1);
        invariant_onlyRecordedPaymentsMoveCustodiedTokens();
        invariant_seasonBalanceExactlyBacksPrizesAndOpenPools();
    }

    function test_liabilitiesStayBackedDuringPartialSettlementAndPayout() public {
        handler.buy(0, 7, false);
        handler.attack(0, 140, 1);
        handler.attack(1, 141, 1);
        handler.attack(2, 142, 1);
        handler.advance(1 hours);
        handler.settle(1);
        assertEq(realm.settledEpoch(), 4);
        assertEq(realm.settleCursor(), 1);
        invariant_realmBalanceExactlyBacksAllLiabilities();
        handler.distribute(0);
        assertGt(handler.treasuryPaid(), 0);
        invariant_realmBalanceExactlyBacksAllLiabilities();
        handler.settle(160);
        assertEq(realm.settledEpoch(), 5);
        invariant_realmBalanceExactlyBacksAllLiabilities();
        invariant_seasonBalanceExactlyBacksPrizesAndOpenPools();
    }

    function test_handlerReachesCustodyAndPayoutStates() public {
        handler.honour(0, 0);
        handler.transferBanner(0, 1, true);
        handler.advance(1 hours);
        handler.settlePact(0);
        handler.distribute(0);
        assertGt(handler.paidIn(), 0);
        assertGt(handler.fees(), 0);
        assertGt(handler.prizesPaid(), 0);
        assertGt(handler.treasuryPaid(), 0);
        assertEq(handler.successfulAttacks(), 3);
        assertEq(handler.signedPacts(), 1);
        assertEq(handler.settledPacts(), 1);
        assertEq(handler.closedSeasons(), 1);
        invariant_fixedSupplyAndCompleteTokenHolderSet();
        invariant_onlyRecordedPaymentsMoveCustodiedTokens();
        invariant_realmBalanceExactlyBacksAllLiabilities();
        invariant_seasonBalanceExactlyBacksPrizesAndOpenPools();
        invariant_mapAndTroopsAreConserved();
        invariant_bondsExactlyMatchUnsettledPacts();
        invariant_membershipAndVotesAgree();
        invariant_closedResultsNeverChange();
    }
}
