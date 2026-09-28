// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IGuilds} from "./interfaces/IGuilds.sol";
import {IRealm} from "./interfaces/IRealm.sol";
import {IDiplomacy} from "./interfaces/IDiplomacy.sol";
import {Banners} from "./Banners.sol";

/// @title Season
/// @notice Prize pool, standings and trophies of the Pacts game.
/// @dev Created by Realm in its constructor; Realm forwards the fee on every troop purchase here
/// and reports it through {recordFee}. After the last epoch of a season is settled anyone can
/// {close} it, in chunks of guilds, ranking guilds by tiles held at season end. The top three
/// guilds split the pool 50/30/20, each share divided equally among the members the guild had at
/// closing who joined it before the season ended. Unassigned shares roll into the next season.
/// Season creates and is the only minter of Banners.
contract Season {
    uint256 public constant FIRST_SHARE = 50;
    uint256 public constant SECOND_SHARE = 30;
    uint256 public constant THIRD_SHARE = 20;

    struct Closing {
        uint64 cursor; // guilds ranked so far
        uint64 guildCount; // guild count snapshot at first chunk
        uint64[3] top;
        uint32[3] topTiles;
    }

    struct Result {
        bool closed;
        uint64[3] winners;
        uint256[3] prizes; // total assigned to the members of each winner
        uint256 rollover;
    }

    IERC20 public immutable token;
    IGuilds public immutable guilds;
    IRealm public immutable realm;
    IDiplomacy public immutable diplomacy;
    Banners public immutable banners;
    uint256 public immutable epochsPerSeason;

    mapping(uint256 season => uint256) public prizePool;
    mapping(uint256 season => Closing) private _closing;
    mapping(uint256 season => Result) private _results;
    mapping(uint256 season => mapping(address member => uint256)) public claimable;
    /// @notice Unclaimed victory rank (1..3), including when the token prize is zero; cleared on claim.
    mapping(uint256 season => mapping(address member => uint8)) public claimRank;
    mapping(uint256 season => mapping(uint256 guildId => bool)) public honourClaimed;

    event FeeRecorded(uint256 indexed season, uint256 amount, uint256 pool);
    event SeasonClosed(uint256 indexed season, uint64[3] winners, uint256[3] prizes, uint256 rollover);
    event PrizeClaimed(
        uint256 indexed season,
        uint256 indexed guildId,
        address indexed member,
        uint8 rank,
        uint256 amount,
        uint256 tokenId
    );
    event HonourBannerClaimed(uint256 indexed season, uint256 indexed guildId, address indexed member, uint256 tokenId);

    error NotRealm();
    error AlreadyClosed();
    error ZeroBudget();
    error SeasonNotSettled();
    error PreviousSeasonNotClosed();
    error SeasonNotEnded();
    error NothingToClaim();
    error AlreadyClaimed();
    error NotMember();
    error JoinedAfterSeason();
    error NoPactHeld();
    error PactWasBroken();
    error TransferFailed();

    constructor(address token_, address guilds_, address diplomacy_, uint256 epochsPerSeason_) {
        token = IERC20(token_);
        guilds = IGuilds(guilds_);
        diplomacy = IDiplomacy(diplomacy_);
        realm = IRealm(msg.sender);
        epochsPerSeason = epochsPerSeason_;
        banners = new Banners();
    }

    // ---------------------------------------------------------------- funding

    /// @notice Called by Realm after transferring a troop-purchase fee to this contract.
    function recordFee(uint256 season, uint256 amount) external {
        if (msg.sender != address(realm)) revert NotRealm();
        prizePool[season] += amount;
        emit FeeRecorded(season, amount, prizePool[season]);
    }

    // ---------------------------------------------------------------- closing

    /// @notice Rank up to `maxGuilds` more guilds of an ended, fully settled season; the season is
    /// closed when every guild that existed at the first call has been ranked. The previous
    /// season must be closed first so all incoming rollover is included in this season's prizes.
    function close(uint256 season, uint256 maxGuilds) external {
        if (_results[season].closed) revert AlreadyClosed();
        if (maxGuilds == 0) revert ZeroBudget();
        if (realm.settledEpoch() < (season + 1) * epochsPerSeason) revert SeasonNotSettled();
        if (season != 0 && !_results[season - 1].closed) revert PreviousSeasonNotClosed();
        Closing storage c = _closing[season];
        if (c.guildCount == 0) c.guildCount = uint64(guilds.guildCount());
        uint256 i = c.cursor;
        uint256 n = c.guildCount;
        uint256 stop = i + maxGuilds;
        if (stop > n) stop = n;
        while (i < stop) {
            ++i;
            uint256 tiles = realm.tilesAtSeasonEnd(i, season);
            if (tiles != 0) _rank(c, i, tiles);
        }
        c.cursor = uint64(i);
        if (i < n) return;
        _finalize(season, c);
    }

    function _rank(Closing storage c, uint256 guildId, uint256 tiles) private {
        // Strict comparisons: on equal tiles the guild ranked first (lower id) keeps its place.
        if (tiles > c.topTiles[0]) {
            (c.top[2], c.topTiles[2]) = (c.top[1], c.topTiles[1]);
            (c.top[1], c.topTiles[1]) = (c.top[0], c.topTiles[0]);
            (c.top[0], c.topTiles[0]) = (uint64(guildId), uint32(tiles));
        } else if (tiles > c.topTiles[1]) {
            (c.top[2], c.topTiles[2]) = (c.top[1], c.topTiles[1]);
            (c.top[1], c.topTiles[1]) = (uint64(guildId), uint32(tiles));
        } else if (tiles > c.topTiles[2]) {
            (c.top[2], c.topTiles[2]) = (uint64(guildId), uint32(tiles));
        }
    }

    function _finalize(uint256 season, Closing storage c) private {
        Result storage r = _results[season];
        uint256 pool = prizePool[season];
        uint256 rollover = pool;
        uint256 seasonEnd = realm.seasonEndTime(season);
        uint256[3] memory shares = [FIRST_SHARE, SECOND_SHARE, THIRD_SHARE];
        for (uint256 rank; rank < 3; ++rank) {
            uint256 guildId = c.top[rank];
            if (guildId == 0) continue;
            r.winners[rank] = uint64(guildId);
            // Only members who joined before the season ended earned a share; closing runs after
            // the end, so wallets joining in between get nothing.
            address[] memory members = _eligibleMembers(guildId, seasonEnd);
            if (members.length == 0) continue;
            uint256 each = (pool * shares[rank] / 100) / members.length;
            for (uint256 m; m < members.length; ++m) {
                claimable[season][members[m]] = each;
                claimRank[season][members[m]] = uint8(rank + 1);
            }
            uint256 assigned = each * members.length;
            r.prizes[rank] = assigned;
            rollover -= assigned;
        }
        r.closed = true;
        r.rollover = rollover;
        if (rollover != 0) prizePool[season + 1] += rollover;
        emit SeasonClosed(season, r.winners, r.prizes, rollover);
    }

    function _eligibleMembers(uint256 guildId, uint256 seasonEnd) private view returns (address[] memory eligible) {
        address[] memory members = guilds.membersOf(guildId);
        uint256 n;
        for (uint256 i; i < members.length; ++i) {
            if (guilds.joinedAt(guildId, members[i]) < seasonEnd) members[n++] = members[i];
        }
        assembly ("memory-safe") {
            mstore(members, n)
        }
        eligible = members;
    }

    // ---------------------------------------------------------------- claims

    /// @notice Claim the caller's share of a closed season's prize and the victory banner,
    /// even if the token prize is zero. Each eligible member may claim only once.
    function claimPrize(uint256 season) external returns (uint256 tokenId) {
        uint8 rank = claimRank[season][msg.sender];
        if (rank == 0) revert NothingToClaim();
        uint256 amount = claimable[season][msg.sender];
        delete claimable[season][msg.sender];
        delete claimRank[season][msg.sender];
        uint256 guildId = _results[season].winners[rank - 1];
        if (amount != 0 && !token.transfer(msg.sender, amount)) revert TransferFailed();
        tokenId = banners.mint(msg.sender, season, guildId, banners.KIND_VICTORY(), rank);
        emit PrizeClaimed(season, guildId, msg.sender, rank, amount, tokenId);
    }

    /// @notice Claim the honour banner of a guild that held at least one pact during an ended
    /// season and broke none. Any member who belonged to the guild before the season ended may
    /// claim it; it is minted to the caller.
    function claimHonourBanner(uint256 season, uint256 guildId) external returns (uint256 tokenId) {
        if (!seasonEnded(season)) revert SeasonNotEnded();
        if (honourClaimed[season][guildId]) revert AlreadyClaimed();
        if (!guilds.isMember(guildId, msg.sender)) revert NotMember();
        // Implies the guild itself existed before the end: its founder joined at founding.
        if (guilds.joinedAt(guildId, msg.sender) >= realm.seasonEndTime(season)) revert JoinedAfterSeason();
        uint256 from = firstEpoch(season);
        uint256 to = lastEpoch(season);
        if (!diplomacy.hadPactDuring(guildId, from, to)) revert NoPactHeld();
        if (diplomacy.betrayedDuring(guildId, from, to)) revert PactWasBroken();
        honourClaimed[season][guildId] = true;
        tokenId = banners.mint(msg.sender, season, guildId, banners.KIND_HONOUR(), 0);
        emit HonourBannerClaimed(season, guildId, msg.sender, tokenId);
    }

    // ---------------------------------------------------------------- views

    function firstEpoch(uint256 season) public view returns (uint256) {
        return season * epochsPerSeason;
    }

    function lastEpoch(uint256 season) public view returns (uint256) {
        return (season + 1) * epochsPerSeason - 1;
    }

    function seasonEnded(uint256 season) public view returns (bool) {
        return realm.currentEpoch() > lastEpoch(season);
    }

    function result(uint256 season) external view returns (Result memory) {
        return _results[season];
    }

    function closing(uint256 season) external view returns (Closing memory) {
        return _closing[season];
    }
}
