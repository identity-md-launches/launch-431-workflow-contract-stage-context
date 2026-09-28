// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Guilds
/// @notice Guild membership and one-member-one-vote proposals for the Pacts game.
/// @dev Anyone can found or join a guild. Every game action a guild takes (attack, reinforcement,
/// pact, treasury spending, expulsion) is a proposal that passes when a strict majority of the
/// guild's current members has voted yes. Only expulsions are executed here; Realm and Diplomacy
/// read the other kinds through {proposal}, {hasMajority} and {isLive} and record their own
/// execution. Because the majority is recounted among current members at execution time, a
/// member who leaves or is expelled no longer counts, and any member can withdraw support by
/// voting no. A proposal can only be executed within {PROPOSAL_LIFETIME} of its creation, so an
/// approval given under one state of the game cannot be consumed long after that state changed.
contract Guilds {
    uint256 public constant MAX_MEMBERS = 32;
    /// @notice How long a passed proposal stays executable after it was created.
    uint256 public constant PROPOSAL_LIFETIME = 1 days;

    uint8 public constant KIND_EXPEL = 1;
    uint8 public constant KIND_ATTACK = 2;
    uint8 public constant KIND_PACT = 3;
    uint8 public constant KIND_DISTRIBUTE = 4;
    uint8 public constant KIND_BUY_TROOPS = 5;
    uint8 public constant KIND_REINFORCE = 6;

    uint8 public constant VOTE_YES = 1;
    uint8 public constant VOTE_NO = 2;

    struct Guild {
        bytes32 name;
        address founder;
        uint64 foundedAt;
    }

    struct Proposal {
        uint64 guild;
        uint8 kind;
        bool executed;
        address proposer;
        uint64 createdAt;
        bytes32 data;
    }

    uint256 public guildCount;
    uint256 public proposalCount;

    mapping(uint256 guildId => Guild) private _guilds;
    mapping(uint256 guildId => address[]) private _members;
    mapping(uint256 guildId => mapping(address member => uint256)) private _memberIndex; // 1-based
    mapping(address member => uint256 guildId) public guildOf;
    /// @notice When the account joined the guild (0 when not a member). Reset on every join.
    mapping(uint256 guildId => mapping(address member => uint256)) public joinedAt;
    mapping(uint256 guildId => mapping(address member => bool)) public banned;
    mapping(uint256 proposalId => Proposal) private _proposals;
    mapping(uint256 proposalId => mapping(address voter => uint8)) public votes;

    event GuildFounded(uint256 indexed guildId, bytes32 name, address indexed founder);
    event MemberJoined(uint256 indexed guildId, address indexed member);
    event MemberLeft(uint256 indexed guildId, address indexed member);
    event MemberExpelled(uint256 indexed guildId, address indexed member, uint256 indexed proposalId);
    event ProposalCreated(
        uint256 indexed proposalId, uint256 indexed guildId, uint8 indexed kind, bytes32 data, address proposer
    );
    event VoteCast(uint256 indexed proposalId, address indexed voter, bool support);

    error AlreadyInGuild();
    error NotInGuild();
    error NoSuchGuild();
    error GuildFull();
    error MemberBanned();
    error NotMember();
    error NoSuchProposal();
    error WrongKind();
    error NoMajority();
    error AlreadyExecuted();
    error ProposalExpired();
    error InvalidKind();
    error InvalidTarget();
    error EmptyName();

    // ---------------------------------------------------------------- membership

    /// @notice Found a new guild and become its first member.
    function found(bytes32 name) external returns (uint256 guildId) {
        if (name == bytes32(0)) revert EmptyName();
        if (guildOf[msg.sender] != 0) revert AlreadyInGuild();
        guildId = ++guildCount;
        _guilds[guildId] = Guild({name: name, founder: msg.sender, foundedAt: uint64(block.timestamp)});
        _add(guildId, msg.sender);
        emit GuildFounded(guildId, name, msg.sender);
    }

    /// @notice Join an existing guild. A player belongs to at most one guild at a time.
    function join(uint256 guildId) external {
        if (guildId == 0 || guildId > guildCount) revert NoSuchGuild();
        if (guildOf[msg.sender] != 0) revert AlreadyInGuild();
        if (banned[guildId][msg.sender]) revert MemberBanned();
        if (_members[guildId].length >= MAX_MEMBERS) revert GuildFull();
        _add(guildId, msg.sender);
        emit MemberJoined(guildId, msg.sender);
    }

    /// @notice Leave the current guild.
    function leave() external {
        uint256 guildId = guildOf[msg.sender];
        if (guildId == 0) revert NotInGuild();
        _remove(guildId, msg.sender);
        emit MemberLeft(guildId, msg.sender);
    }

    // ---------------------------------------------------------------- proposals

    /// @notice Open a proposal for the caller's guild. The proposer votes yes automatically.
    /// @param kind One of KIND_EXPEL, KIND_ATTACK, KIND_PACT, KIND_DISTRIBUTE, KIND_BUY_TROOPS or
    /// KIND_REINFORCE.
    /// @param data Kind-specific payload; see Realm and Diplomacy for the packed layouts.
    function propose(uint8 kind, bytes32 data) external returns (uint256 proposalId) {
        uint256 guildId = guildOf[msg.sender];
        if (guildId == 0) revert NotInGuild();
        if (kind == 0 || kind > KIND_REINFORCE) revert InvalidKind();
        if (kind == KIND_EXPEL) {
            address target = address(uint160(uint256(data)));
            if (target == msg.sender || guildOf[target] != guildId) revert InvalidTarget();
        }
        proposalId = ++proposalCount;
        _proposals[proposalId] = Proposal({
            guild: uint64(guildId),
            kind: kind,
            executed: false,
            proposer: msg.sender,
            createdAt: uint64(block.timestamp),
            data: data
        });
        votes[proposalId][msg.sender] = VOTE_YES;
        emit ProposalCreated(proposalId, guildId, kind, data, msg.sender);
        emit VoteCast(proposalId, msg.sender, true);
    }

    /// @notice Vote on a proposal of the caller's guild. Votes may be changed at any time.
    function vote(uint256 proposalId, bool support) external {
        Proposal storage p = _proposals[proposalId];
        if (p.kind == 0) revert NoSuchProposal();
        if (guildOf[msg.sender] != p.guild) revert NotMember();
        votes[proposalId][msg.sender] = support ? VOTE_YES : VOTE_NO;
        emit VoteCast(proposalId, msg.sender, support);
    }

    /// @notice Execute a passed expulsion. The expelled member cannot rejoin this guild.
    function executeExpel(uint256 proposalId) external {
        Proposal storage p = _proposals[proposalId];
        if (p.kind != KIND_EXPEL) revert WrongKind();
        if (p.executed) revert AlreadyExecuted();
        uint256 guildId = p.guild;
        if (guildOf[msg.sender] != guildId) revert NotMember();
        address target = address(uint160(uint256(p.data)));
        if (guildOf[target] != guildId) revert InvalidTarget();
        if (!isLive(proposalId)) revert ProposalExpired();
        if (!hasMajority(proposalId)) revert NoMajority();
        p.executed = true;
        banned[guildId][target] = true;
        _remove(guildId, target);
        emit MemberExpelled(guildId, target, proposalId);
    }

    // ---------------------------------------------------------------- views

    function guild(uint256 guildId) external view returns (Guild memory) {
        return _guilds[guildId];
    }

    function proposal(uint256 proposalId) external view returns (Proposal memory) {
        return _proposals[proposalId];
    }

    function membersOf(uint256 guildId) external view returns (address[] memory) {
        return _members[guildId];
    }

    function memberCount(uint256 guildId) public view returns (uint256) {
        return _members[guildId].length;
    }

    function isMember(uint256 guildId, address account) external view returns (bool) {
        return guildId != 0 && guildOf[account] == guildId;
    }

    /// @notice Yes votes from members who currently belong to the proposal's guild.
    function yesVotes(uint256 proposalId) public view returns (uint256 count) {
        address[] storage members = _members[_proposals[proposalId].guild];
        uint256 n = members.length;
        for (uint256 i; i < n; ++i) {
            if (votes[proposalId][members[i]] == VOTE_YES) ++count;
        }
    }

    /// @notice True when a strict majority of the guild's current members has voted yes.
    function hasMajority(uint256 proposalId) public view returns (bool) {
        Proposal storage p = _proposals[proposalId];
        if (p.kind == 0) return false;
        uint256 n = _members[p.guild].length;
        return n != 0 && yesVotes(proposalId) * 2 > n;
    }

    /// @notice True while the proposal exists and less than {PROPOSAL_LIFETIME} has passed since
    /// it was created. Executors refuse expired proposals whatever their vote count.
    function isLive(uint256 proposalId) public view returns (bool) {
        Proposal storage p = _proposals[proposalId];
        return p.kind != 0 && block.timestamp < uint256(p.createdAt) + PROPOSAL_LIFETIME;
    }

    // ---------------------------------------------------------------- internals

    function _add(uint256 guildId, address account) private {
        _members[guildId].push(account);
        _memberIndex[guildId][account] = _members[guildId].length;
        guildOf[account] = guildId;
        joinedAt[guildId][account] = block.timestamp;
    }

    function _remove(uint256 guildId, address account) private {
        address[] storage members = _members[guildId];
        uint256 index = _memberIndex[guildId][account] - 1;
        uint256 last = members.length - 1;
        if (index != last) {
            address moved = members[last];
            members[index] = moved;
            _memberIndex[guildId][moved] = index + 1;
        }
        members.pop();
        delete _memberIndex[guildId][account];
        delete guildOf[account];
        delete joinedAt[guildId][account];
    }
}
