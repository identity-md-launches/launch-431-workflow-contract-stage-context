// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PactsBase} from "./PactsBase.t.sol";
import {Guilds} from "../src/Guilds.sol";
import {
    GUILD_KIND_EXPEL,
    GUILD_KIND_ATTACK,
    GUILD_KIND_PACT,
    GUILD_KIND_DISTRIBUTE,
    GUILD_KIND_BUY_TROOPS,
    GUILD_KIND_REINFORCE
} from "../src/interfaces/IGuilds.sol";

contract GuildsTest is PactsBase {
    function test_foundAndJoin() public {
        uint256 g = _found(alice, "Alpha");
        assertEq(g, 1);
        assertEq(guilds.guildOf(alice), 1);
        assertEq(guilds.memberCount(1), 1);
        assertEq(guilds.guild(1).founder, alice);
        assertEq(guilds.guild(1).name, bytes32("Alpha"));
        assertEq(guilds.guild(1).foundedAt, block.timestamp);

        _join(bob, 1);
        assertEq(guilds.memberCount(1), 2);
        assertTrue(guilds.isMember(1, bob));
        address[] memory members = guilds.membersOf(1);
        assertEq(members.length, 2);
        assertEq(members[0], alice);
        assertEq(members[1], bob);
    }

    function test_onePlayerOneGuild() public {
        _found(alice, "Alpha");
        _found(bob, "Beta");
        vm.prank(alice);
        vm.expectRevert(Guilds.AlreadyInGuild.selector);
        guilds.join(2);
        vm.prank(alice);
        vm.expectRevert(Guilds.AlreadyInGuild.selector);
        guilds.found("Gamma");
    }

    function test_joinRejectsUnknownGuildAndEmptyName() public {
        vm.prank(alice);
        vm.expectRevert(Guilds.NoSuchGuild.selector);
        guilds.join(1);
        vm.prank(alice);
        vm.expectRevert(Guilds.EmptyName.selector);
        guilds.found(bytes32(0));
    }

    function test_leaveRemovesMember() public {
        _found(alice, "Alpha");
        _join(bob, 1);
        _join(carol, 1);
        vm.prank(alice);
        guilds.leave();
        assertEq(guilds.guildOf(alice), 0);
        assertEq(guilds.memberCount(1), 2);
        address[] memory members = guilds.membersOf(1);
        assertEq(members[0], carol); // swapped into alice's slot
        assertEq(members[1], bob);
        vm.prank(alice);
        vm.expectRevert(Guilds.NotInGuild.selector);
        guilds.leave();
        // leaving is not a ban
        _join(alice, 1);
        assertEq(guilds.memberCount(1), 3);
    }

    function test_guildIsCapped() public {
        _found(alice, "Alpha");
        for (uint256 i = 1; i < guilds.MAX_MEMBERS(); ++i) {
            _join(address(uint160(0x1000 + i)), 1);
        }
        assertEq(guilds.memberCount(1), guilds.MAX_MEMBERS());
        vm.prank(bob);
        vm.expectRevert(Guilds.GuildFull.selector);
        guilds.join(1);
    }

    function test_proposerVotesYesAndSoloGuildHasMajority() public {
        _found(alice, "Alpha");
        uint256 id = _propose(alice, GUILD_KIND_ATTACK, bytes32(uint256(1)));
        assertEq(guilds.votes(id, alice), guilds.VOTE_YES());
        assertTrue(guilds.hasMajority(id));
        Guilds.Proposal memory p = guilds.proposal(id);
        assertEq(p.guild, 1);
        assertEq(p.kind, GUILD_KIND_ATTACK);
        assertEq(p.data, bytes32(uint256(1)));
        assertEq(p.proposer, alice);
    }

    function test_majorityIsStrict() public {
        _found(alice, "Alpha");
        _join(bob, 1);
        uint256 id = _propose(alice, GUILD_KIND_DISTRIBUTE, bytes32(0));
        assertFalse(guilds.hasMajority(id), "1 of 2 is not a majority");
        _vote(bob, id, true);
        assertTrue(guilds.hasMajority(id));
        _vote(bob, id, false);
        assertFalse(guilds.hasMajority(id), "votes can be withdrawn");
        _join(carol, 1);
        _vote(bob, id, true);
        assertTrue(guilds.hasMajority(id), "2 of 3");
        _join(dave, 1);
        assertFalse(guilds.hasMajority(id), "2 of 4 is not a majority");
    }

    function test_majorityRecountedAmongCurrentMembers() public {
        _found(alice, "Alpha");
        _join(bob, 1);
        uint256 id = _propose(alice, GUILD_KIND_PACT, bytes32(0));
        _vote(bob, id, true);
        assertTrue(guilds.hasMajority(id));
        vm.prank(bob);
        guilds.leave();
        assertEq(guilds.yesVotes(id), 1);
        assertTrue(guilds.hasMajority(id), "1 of 1");
        vm.prank(alice);
        guilds.leave();
        assertFalse(guilds.hasMajority(id), "empty guild passes nothing");
    }

    function test_onlyMembersProposeAndVote() public {
        _found(alice, "Alpha");
        _found(bob, "Beta");
        uint256 id = _propose(alice, GUILD_KIND_ATTACK, bytes32(0));
        vm.prank(bob);
        vm.expectRevert(Guilds.NotMember.selector);
        guilds.vote(id, true);
        vm.prank(carol);
        vm.expectRevert(Guilds.NotInGuild.selector);
        guilds.propose(GUILD_KIND_ATTACK, bytes32(0));
        vm.prank(alice);
        vm.expectRevert(Guilds.InvalidKind.selector);
        guilds.propose(0, bytes32(0));
        vm.prank(alice);
        vm.expectRevert(Guilds.InvalidKind.selector);
        guilds.propose(7, bytes32(0));
        vm.prank(alice);
        vm.expectRevert(Guilds.NoSuchProposal.selector);
        guilds.vote(99, true);
    }

    function test_expelByMajorityAndBan() public {
        _found(alice, "Alpha");
        _join(bob, 1);
        _join(carol, 1);
        uint256 id = _propose(alice, GUILD_KIND_EXPEL, bytes32(uint256(uint160(carol))));
        vm.prank(alice);
        vm.expectRevert(Guilds.NoMajority.selector);
        guilds.executeExpel(id);
        _vote(carol, id, false);
        _vote(bob, id, true);
        vm.prank(dave); // outsiders cannot execute
        vm.expectRevert(Guilds.NotMember.selector);
        guilds.executeExpel(id);
        vm.prank(bob);
        guilds.executeExpel(id);
        assertEq(guilds.guildOf(carol), 0);
        assertEq(guilds.memberCount(1), 2);
        assertTrue(guilds.banned(1, carol));
        assertTrue(guilds.proposal(id).executed);
        vm.prank(carol);
        vm.expectRevert(Guilds.MemberBanned.selector);
        guilds.join(1);
        vm.prank(alice);
        vm.expectRevert(Guilds.AlreadyExecuted.selector);
        guilds.executeExpel(id);
        // carol can still found or join elsewhere
        _found(carol, "Gamma");
    }

    function test_expelTargetMustBeMember() public {
        _found(alice, "Alpha");
        _join(bob, 1);
        vm.prank(alice);
        vm.expectRevert(Guilds.InvalidTarget.selector);
        guilds.propose(GUILD_KIND_EXPEL, bytes32(uint256(uint160(carol))));
        vm.prank(alice);
        vm.expectRevert(Guilds.InvalidTarget.selector);
        guilds.propose(GUILD_KIND_EXPEL, bytes32(uint256(uint160(alice))));
        uint256 id = _propose(alice, GUILD_KIND_EXPEL, bytes32(uint256(uint160(bob))));
        vm.prank(bob);
        guilds.leave();
        _vote(alice, id, true);
        vm.prank(alice);
        vm.expectRevert(Guilds.InvalidTarget.selector);
        guilds.executeExpel(id);
        uint256 attackId = _propose(alice, GUILD_KIND_ATTACK, bytes32(0));
        vm.prank(alice);
        vm.expectRevert(Guilds.WrongKind.selector);
        guilds.executeExpel(attackId);
    }

    function test_kindConstantsMatchInterface() public view {
        assertEq(guilds.KIND_EXPEL(), GUILD_KIND_EXPEL);
        assertEq(guilds.KIND_ATTACK(), GUILD_KIND_ATTACK);
        assertEq(guilds.KIND_PACT(), GUILD_KIND_PACT);
        assertEq(guilds.KIND_DISTRIBUTE(), GUILD_KIND_DISTRIBUTE);
        assertEq(guilds.KIND_BUY_TROOPS(), GUILD_KIND_BUY_TROOPS);
        assertEq(guilds.KIND_REINFORCE(), GUILD_KIND_REINFORCE);
    }

    function test_joinedAtIsRecordedAndResetOnRejoin() public {
        _found(alice, "Alpha");
        assertEq(guilds.joinedAt(1, alice), block.timestamp);
        vm.warp(block.timestamp + 100);
        _join(bob, 1);
        assertEq(guilds.joinedAt(1, bob), block.timestamp);
        assertEq(guilds.joinedAt(1, carol), 0);
        vm.prank(bob);
        guilds.leave();
        assertEq(guilds.joinedAt(1, bob), 0);
        vm.warp(block.timestamp + 100);
        _join(bob, 1);
        assertEq(guilds.joinedAt(1, bob), block.timestamp, "rejoining starts over");
    }

    function test_proposalsExpireAfterLifetime() public {
        _found(alice, "Alpha");
        _join(bob, 1);
        _join(carol, 1);
        assertFalse(guilds.isLive(1), "unknown proposal");
        uint256 id = _propose(alice, GUILD_KIND_EXPEL, bytes32(uint256(uint160(carol))));
        _vote(bob, id, true);
        assertTrue(guilds.isLive(id));
        vm.warp(block.timestamp + guilds.PROPOSAL_LIFETIME() - 1);
        assertTrue(guilds.isLive(id));
        vm.warp(block.timestamp + 1);
        assertFalse(guilds.isLive(id));
        assertTrue(guilds.hasMajority(id), "expiry is separate from the vote count");
        vm.prank(alice);
        vm.expectRevert(Guilds.ProposalExpired.selector);
        guilds.executeExpel(id);
        assertEq(guilds.guildOf(carol), 1);
        uint256 again = _propose(alice, GUILD_KIND_EXPEL, bytes32(uint256(uint160(carol))));
        _vote(bob, again, true);
        vm.prank(alice);
        guilds.executeExpel(again);
        assertEq(guilds.guildOf(carol), 0);
    }

    function testFuzz_majorityThreshold(uint8 membersSeed, uint8 yesSeed) public {
        uint256 n = bound(membersSeed, 1, guilds.MAX_MEMBERS());
        uint256 yes = bound(yesSeed, 0, n);
        _found(alice, "Alpha");
        uint256 id = _propose(alice, GUILD_KIND_ATTACK, bytes32(0));
        _vote(alice, id, yes > 0);
        for (uint256 i = 1; i < n; ++i) {
            address m = address(uint160(0x2000 + i));
            _join(m, 1);
            _vote(m, id, i < yes);
        }
        assertEq(guilds.yesVotes(id), yes);
        assertEq(guilds.hasMajority(id), yes * 2 > n);
    }
}
