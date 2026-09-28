// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IGuilds, GUILD_KIND_PACT} from "./interfaces/IGuilds.sol";
import {IRealm} from "./interfaces/IRealm.sol";

/// @title Diplomacy
/// @notice Pacts between guilds, backed by token bonds held in the guild treasuries of Realm.
/// @dev Created by Realm in its constructor, which is how Realm knows this contract is the only
/// address allowed to lock, release and slash treasury bonds. A pact is signed when both guilds
/// have passed matching KIND_PACT proposals. Betrayal is a fact recorded by Realm: declaring an
/// attack on a tile the partner holds during the pact window. Anyone can settle a pact once
/// the first betrayal epoch has ended, or once the window has passed; the outcome is the same whoever calls and
/// whenever they call, so the slash is automatic in effect even though a transaction triggers it.
contract Diplomacy {
    struct Pact {
        uint64 guildA;
        uint64 guildB;
        uint64 startEpoch;
        uint64 endEpoch; // inclusive
        bool settled;
        uint8 brokenBy; // bit 0: guildA betrayed, bit 1: guildB betrayed (set at settlement)
        uint256 bondA;
        uint256 bondB;
        uint256 logAB; // realm attack log length A->B at signing
        uint256 logBA; // realm attack log length B->A at signing
    }

    IGuilds public immutable guilds;
    IRealm public immutable realm;

    Pact[] private _pacts;
    mapping(uint256 guildId => uint256[]) private _pactsOf;
    /// @notice pactId + 1 of the unsettled pact between two guilds, 0 when none.
    mapping(uint256 guildA => mapping(uint256 guildB => uint256)) public activePactBetween;
    mapping(uint256 proposalId => bool) public proposalUsed;

    event PactSigned(
        uint256 indexed pactId,
        uint256 indexed guildA,
        uint256 indexed guildB,
        uint256 bondA,
        uint256 bondB,
        uint256 startEpoch,
        uint256 endEpoch,
        uint256 proposalA,
        uint256 proposalB
    );
    event PactBroken(
        uint256 indexed pactId, uint256 indexed betrayer, uint256 indexed victim, uint256 epoch, uint256 slashed
    );
    event PactExpired(uint256 indexed pactId, uint256 bondA, uint256 bondB);

    error WrongKind();
    error ProposalUsed();
    error SamePartner();
    error TermsMismatch();
    error BadDuration();
    error NotMember();
    error NoMajority();
    error PactExists();
    error NoSuchPact();
    error AlreadySettled();
    error PactStillActive();

    constructor(address guilds_) {
        guilds = IGuilds(guilds_);
        realm = IRealm(msg.sender);
    }

    // ---------------------------------------------------------------- proposal payload

    /// @notice Pack the payload of a KIND_PACT proposal.
    /// @dev Layout: partner (32 bits) | duration in epochs (32 bits) | own bond (96 bits) | partner bond (96 bits).
    function packPactData(uint256 partner, uint256 durationEpochs, uint256 ownBond, uint256 partnerBond)
        public
        pure
        returns (bytes32)
    {
        require(partner < 2 ** 32 && durationEpochs < 2 ** 32 && ownBond < 2 ** 96 && partnerBond < 2 ** 96, "pack");
        return bytes32((partner << 224) | (durationEpochs << 192) | (ownBond << 96) | partnerBond);
    }

    function unpackPactData(bytes32 data)
        public
        pure
        returns (uint256 partner, uint256 durationEpochs, uint256 ownBond, uint256 partnerBond)
    {
        uint256 v = uint256(data);
        partner = v >> 224;
        durationEpochs = (v >> 192) & (2 ** 32 - 1);
        ownBond = (v >> 96) & (2 ** 96 - 1);
        partnerBond = v & (2 ** 96 - 1);
    }

    // ---------------------------------------------------------------- actions

    /// @notice Sign a pact from two passed proposals whose terms mirror each other.
    /// @param proposalA A KIND_PACT proposal of the first guild naming the second as partner.
    /// @param proposalB The matching proposal of the second guild.
    function signPact(uint256 proposalA, uint256 proposalB) external returns (uint256 pactId) {
        if (proposalUsed[proposalA] || proposalUsed[proposalB]) revert ProposalUsed();
        if (!guilds.hasMajority(proposalA) || !guilds.hasMajority(proposalB)) revert NoMajority();
        (uint256 a, uint256 b, uint256 duration, uint256 bondA, uint256 bondB) = _matchTerms(proposalA, proposalB);
        if (!guilds.isMember(a, msg.sender) && !guilds.isMember(b, msg.sender)) revert NotMember();
        if (activePactBetween[a][b] != 0) revert PactExists();

        proposalUsed[proposalA] = true;
        proposalUsed[proposalB] = true;
        uint256 start = realm.currentEpoch();
        pactId = _pacts.length;
        _pacts.push(
            Pact({
                guildA: uint64(a),
                guildB: uint64(b),
                startEpoch: uint64(start),
                endEpoch: uint64(start + duration - 1),
                settled: false,
                brokenBy: 0,
                bondA: bondA,
                bondB: bondB,
                logAB: realm.attackLogLength(a, b),
                logBA: realm.attackLogLength(b, a)
            })
        );
        _pactsOf[a].push(pactId);
        _pactsOf[b].push(pactId);
        activePactBetween[a][b] = pactId + 1;
        activePactBetween[b][a] = pactId + 1;
        realm.lockBond(a, bondA);
        realm.lockBond(b, bondB);
        _emitSigned(pactId, proposalA, proposalB);
    }

    function _emitSigned(uint256 pactId, uint256 proposalA, uint256 proposalB) private {
        Pact storage p = _pacts[pactId];
        emit PactSigned(pactId, p.guildA, p.guildB, p.bondA, p.bondB, p.startEpoch, p.endEpoch, proposalA, proposalB);
    }

    /// @notice Settle a pact: slash the betrayer's bond to the victim, or return both bonds once
    /// the window has passed unbroken. Anyone may call after the first betrayal epoch ends,
    /// allowing both sides' attacks in that epoch to count before any bonds are released.
    function settlePact(uint256 pactId) external {
        if (pactId >= _pacts.length) revert NoSuchPact();
        Pact storage p = _pacts[pactId];
        if (p.settled) revert AlreadySettled();
        (bool byA, uint256 epochA, bool byB, uint256 epochB) = _betrayal(p);
        uint256 current = realm.currentEpoch();
        if ((!byA && !byB && current <= p.endEpoch) || (byA && current <= epochA) || (byB && current <= epochB)) {
            revert PactStillActive();
        }

        p.settled = true;
        uint256 a = p.guildA;
        uint256 b = p.guildB;
        delete activePactBetween[a][b];
        delete activePactBetween[b][a];

        if (!byA && !byB) {
            realm.releaseBond(a, p.bondA);
            realm.releaseBond(b, p.bondB);
            emit PactExpired(pactId, p.bondA, p.bondB);
            return;
        }
        if (byA) {
            p.brokenBy |= 1;
            realm.slashBond(a, b, p.bondA);
            emit PactBroken(pactId, a, b, epochA, p.bondA);
        } else {
            realm.releaseBond(a, p.bondA);
        }
        if (byB) {
            p.brokenBy |= 2;
            realm.slashBond(b, a, p.bondB);
            emit PactBroken(pactId, b, a, epochB, p.bondB);
        } else {
            realm.releaseBond(b, p.bondB);
        }
    }

    // ---------------------------------------------------------------- views

    function pactCount() external view returns (uint256) {
        return _pacts.length;
    }

    function pact(uint256 pactId) external view returns (Pact memory) {
        if (pactId >= _pacts.length) revert NoSuchPact();
        return _pacts[pactId];
    }

    function pactsOf(uint256 guildId) external view returns (uint256[] memory) {
        return _pactsOf[guildId];
    }

    /// @notice Betrayal facts of a pact, computed from Realm's attack log. Stable once the pact
    /// window has passed; before that a new betrayal can still appear.
    function betrayalOf(uint256 pactId) external view returns (bool byA, uint256 epochA, bool byB, uint256 epochB) {
        if (pactId >= _pacts.length) revert NoSuchPact();
        return _betrayal(_pacts[pactId]);
    }

    /// @notice True while the pact is unsettled, unbroken and inside its window.
    function isActive(uint256 pactId) external view returns (bool) {
        if (pactId >= _pacts.length) return false;
        Pact storage p = _pacts[pactId];
        if (p.settled || realm.currentEpoch() > p.endEpoch) return false;
        (bool byA,, bool byB,) = _betrayal(p);
        return !byA && !byB;
    }

    /// @notice True when the guild was party to a pact overlapping [fromEpoch, toEpoch].
    function hadPactDuring(uint256 guildId, uint256 fromEpoch, uint256 toEpoch) external view returns (bool) {
        uint256[] storage ids = _pactsOf[guildId];
        for (uint256 i; i < ids.length; ++i) {
            Pact storage p = _pacts[ids[i]];
            if (p.startEpoch > toEpoch) continue;
            if (_effectiveEnd(p) >= fromEpoch) return true;
        }
        return false;
    }

    /// @notice True when the guild betrayed a pact partner in an epoch inside [fromEpoch, toEpoch].
    function betrayedDuring(uint256 guildId, uint256 fromEpoch, uint256 toEpoch) external view returns (bool) {
        uint256[] storage ids = _pactsOf[guildId];
        for (uint256 i; i < ids.length; ++i) {
            Pact storage p = _pacts[ids[i]];
            (bool byA, uint256 epochA, bool byB, uint256 epochB) = _betrayal(p);
            if (p.guildA == guildId && byA && epochA >= fromEpoch && epochA <= toEpoch) return true;
            if (p.guildB == guildId && byB && epochB >= fromEpoch && epochB <= toEpoch) return true;
        }
        return false;
    }

    // ---------------------------------------------------------------- internals

    /// @dev Both proposals must be KIND_PACT, from two different guilds, each naming the other as
    /// partner with the same duration and mirrored bonds.
    function _matchTerms(uint256 proposalA, uint256 proposalB)
        private
        view
        returns (uint256 a, uint256 b, uint256 duration, uint256 bondA, uint256 bondB)
    {
        IGuilds.Proposal memory pa = guilds.proposal(proposalA);
        IGuilds.Proposal memory pb = guilds.proposal(proposalB);
        if (pa.kind != GUILD_KIND_PACT || pb.kind != GUILD_KIND_PACT) revert WrongKind();
        a = pa.guild;
        b = pb.guild;
        if (a == b) revert SamePartner();
        (uint256 partnerA, uint256 durA, uint256 ownA, uint256 expectB) = unpackPactData(pa.data);
        (uint256 partnerB, uint256 durB, uint256 ownB, uint256 expectA) = unpackPactData(pb.data);
        if (partnerA != b || partnerB != a || durA != durB || ownA != expectA || ownB != expectB) {
            revert TermsMismatch();
        }
        if (durA == 0) revert BadDuration();
        duration = durA;
        bondA = ownA;
        bondB = ownB;
    }

    /// @dev The first attack each side declared on the other inside the window. If both betrayed,
    /// only the earlier one counts; a later attack is retaliation. Same-epoch attacks both count.
    function _betrayal(Pact storage p) private view returns (bool byA, uint256 epochA, bool byB, uint256 epochB) {
        (byA, epochA) = _firstAttack(p.guildA, p.guildB, p.logAB, p.endEpoch);
        (byB, epochB) = _firstAttack(p.guildB, p.guildA, p.logBA, p.endEpoch);
        if (byA && byB) {
            if (epochA < epochB) byB = false;
            else if (epochB < epochA) byA = false;
        }
    }

    function _firstAttack(uint256 attacker, uint256 defender, uint256 fromIndex, uint256 endEpoch)
        private
        view
        returns (bool found, uint256 epoch)
    {
        if (realm.attackLogLength(attacker, defender) > fromIndex) {
            epoch = realm.attackLogAt(attacker, defender, fromIndex);
            found = epoch <= endEpoch;
        }
    }

    function _effectiveEnd(Pact storage p) private view returns (uint256 end) {
        end = p.endEpoch;
        (bool byA, uint256 epochA, bool byB, uint256 epochB) = _betrayal(p);
        if (byA && epochA < end) end = epochA;
        if (byB && epochB < end) end = epochB;
    }
}
