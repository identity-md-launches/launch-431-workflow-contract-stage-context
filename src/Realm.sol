// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IGuilds, GUILD_KIND_ATTACK, GUILD_KIND_DISTRIBUTE} from "./interfaces/IGuilds.sol";
import {Diplomacy} from "./Diplomacy.sol";
import {Season} from "./Season.sol";

/// @title Realm
/// @notice The 12x12 map, troops, attacks, epoch settlement and guild treasuries of Pacts.
/// @dev Time is divided into epochs; a fixed number of epochs is a season. Troops are bought
/// with the launch token; a fee share goes to Season's prize pool and the rest is the epoch's
/// income pool, split at settlement per tile among the guilds holding tiles during the epoch.
/// Attacks are declared openly during an epoch after a guild vote, with troops committed at
/// declaration, and every attack on a tile resolves together when the epoch is settled. Anyone
/// can settle. All tokens the contract pays out were paid in by players; nothing is minted.
///
/// Realm creates Diplomacy and Season in its constructor. That is the only way, with
/// constructor-only wiring and no post-deployment calls, for Realm to trust Diplomacy with
/// treasury bonds and to route fees to Season while Season reads standings from Realm.
contract Realm {
    uint256 public constant MAP_SIZE = 12;
    uint256 public constant TILE_COUNT = 144;
    uint256 public constant BPS = 10_000;
    /// @dev Bounds the gas of resolving one tile, which cannot be split across settle() calls.
    uint256 public constant MAX_ATTACKS_PER_TILE = 64;
    uint256 private constant ACC_SCALE = 1e18;

    struct Attack {
        uint64 epoch;
        uint64 guild;
        uint64 defender; // holder at declaration, 0 for an unheld tile
        uint8 tile;
        bool resolved;
        bool won;
        uint256 troops;
        uint256 survivors;
    }

    struct Checkpoint {
        uint32 season;
        uint32 tiles;
    }

    IERC20 public immutable token;
    IGuilds public immutable guilds;
    Diplomacy public immutable diplomacy;
    Season public immutable season;
    uint256 public immutable genesis;
    uint256 public immutable epochLength;
    uint256 public immutable seasonLength;
    uint256 public immutable epochsPerSeason;
    uint256 public immutable troopPrice;
    uint256 public immutable feeBps;

    // map
    mapping(uint256 tile => uint256 guildId) public holder;
    mapping(uint256 tile => uint256 troops) public garrison;
    mapping(uint256 guildId => uint256) public tilesHeld;
    uint256 public totalTilesHeld;
    mapping(uint256 guildId => Checkpoint[]) private _checkpoints;

    // armies and money
    mapping(uint256 guildId => uint256) public troops;
    mapping(uint256 guildId => uint256) public treasury;
    mapping(uint256 guildId => uint256) public lockedBonds;
    mapping(uint256 guildId => uint256) private _rewardDebt;
    mapping(uint256 epoch => uint256) public incomePool;
    uint256 public carriedIncome;
    uint256 public accIncomePerTile;

    // attacks
    Attack[] private _attacks;
    mapping(uint256 epoch => uint8[]) private _attackedTiles;
    mapping(uint256 epoch => mapping(uint256 tile => uint256[])) private _tileAttacks;
    mapping(uint256 epoch => mapping(uint256 guildId => mapping(uint256 tile => bool))) public hasAttacked;
    mapping(uint256 attacker => mapping(uint256 defender => uint32[])) private _attackLog;
    mapping(uint256 proposalId => bool) public proposalUsed;

    // settlement
    uint256 public settledEpoch; // number of fully settled epochs; epoch `settledEpoch` is next
    uint256 public settleCursor; // attacked tiles of the pending epoch resolved so far

    event TroopsBought(
        uint256 indexed guildId,
        address indexed buyer,
        uint256 indexed epoch,
        uint256 count,
        uint256 cost,
        uint256 fee,
        bool fromTreasury
    );
    event TreasuryFunded(uint256 indexed guildId, address indexed from, uint256 amount);
    event Reinforced(
        uint256 indexed tile, uint256 indexed guildId, address indexed member, uint256 count, uint256 garrison
    );
    event AttackDeclared(
        uint256 indexed attackId,
        uint256 indexed epoch,
        uint256 indexed guildId,
        uint256 tile,
        uint256 troops,
        uint256 defender,
        uint256 proposalId
    );
    event AttackResolved(uint256 indexed attackId, bool won, uint256 survivors);
    event TileResolved(
        uint256 indexed epoch, uint256 indexed tile, uint256 previousHolder, uint256 indexed newHolder, uint256 garrison
    );
    event IncomeDistributed(uint256 indexed epoch, uint256 amount, uint256 tiles);
    event EpochSettled(uint256 indexed epoch);
    event IncomeHarvested(uint256 indexed guildId, uint256 amount);
    event TreasuryDistributed(uint256 indexed guildId, uint256 indexed proposalId, uint256 perMember, uint256 members);
    event BondLocked(uint256 indexed guildId, uint256 amount);
    event BondReleased(uint256 indexed guildId, uint256 amount);
    event BondSlashed(uint256 indexed from, uint256 indexed to, uint256 amount);

    error ZeroAddress();
    error BadParams();
    error NotMember();
    error ZeroAmount();
    error TransferFailed();
    error InsufficientTreasury();
    error InsufficientTroops();
    error EpochNotSettled();
    error NotHolder();
    error WrongKind();
    error ProposalUsed();
    error NoMajority();
    error BadTile();
    error OwnTile();
    error AlreadyAttacking();
    error TileCrowded();
    error ZeroBudget();
    error NothingToDistribute();
    error NotDiplomacy();

    constructor(
        address token_,
        address guilds_,
        uint256 epochLength_,
        uint256 seasonLength_,
        uint256 troopPrice_,
        uint256 feeBps_
    ) {
        if (token_ == address(0) || guilds_ == address(0)) revert ZeroAddress();
        if (epochLength_ == 0 || seasonLength_ < epochLength_ || seasonLength_ % epochLength_ != 0) revert BadParams();
        if (troopPrice_ == 0 || feeBps_ > BPS) revert BadParams();
        token = IERC20(token_);
        guilds = IGuilds(guilds_);
        genesis = block.timestamp;
        epochLength = epochLength_;
        seasonLength = seasonLength_;
        epochsPerSeason = seasonLength_ / epochLength_;
        troopPrice = troopPrice_;
        feeBps = feeBps_;
        diplomacy = new Diplomacy(guilds_);
        season = new Season(token_, guilds_, address(diplomacy), seasonLength_ / epochLength_);
    }

    // ---------------------------------------------------------------- time

    function currentEpoch() public view returns (uint256) {
        return (block.timestamp - genesis) / epochLength;
    }

    function currentSeason() external view returns (uint256) {
        return currentEpoch() / epochsPerSeason;
    }

    function seasonOf(uint256 epoch) public view returns (uint256) {
        return epoch / epochsPerSeason;
    }

    function epochStart(uint256 epoch) external view returns (uint256) {
        return genesis + epoch * epochLength;
    }

    function seasonEndTime(uint256 season_) external view returns (uint256) {
        return genesis + (season_ + 1) * seasonLength;
    }

    // ---------------------------------------------------------------- money in

    /// @notice Buy troops for the caller's guild. The fee share goes to the season prize pool and
    /// the rest to this epoch's income pool.
    function buyTroops(uint256 guildId, uint256 count) external {
        _requireMember(guildId);
        if (count == 0) revert ZeroAmount();
        uint256 cost = count * troopPrice;
        if (!token.transferFrom(msg.sender, address(this), cost)) revert TransferFailed();
        _credit(guildId, count, cost, false);
    }

    /// @notice Buy troops with the guild treasury (harvested income, returned bonds, donations).
    function buyTroopsFromTreasury(uint256 guildId, uint256 count) external {
        _requireMember(guildId);
        if (count == 0) revert ZeroAmount();
        uint256 cost = count * troopPrice;
        _harvest(guildId);
        if (treasury[guildId] < cost) revert InsufficientTreasury();
        treasury[guildId] -= cost;
        _credit(guildId, count, cost, true);
    }

    /// @notice Donate tokens to the caller's guild treasury, for example to back a pact bond.
    function fundTreasury(uint256 guildId, uint256 amount) external {
        _requireMember(guildId);
        if (amount == 0) revert ZeroAmount();
        if (!token.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        treasury[guildId] += amount;
        emit TreasuryFunded(guildId, msg.sender, amount);
    }

    function _credit(uint256 guildId, uint256 count, uint256 cost, bool fromTreasury) private {
        uint256 epoch = currentEpoch();
        uint256 fee = cost * feeBps / BPS;
        if (fee != 0) {
            if (!token.transfer(address(season), fee)) revert TransferFailed();
            season.recordFee(seasonOf(epoch), fee);
        }
        incomePool[epoch] += cost - fee;
        troops[guildId] += count;
        emit TroopsBought(guildId, msg.sender, epoch, count, cost, fee, fromTreasury);
    }

    // ---------------------------------------------------------------- moves

    /// @notice Move troops from the guild pool onto a tile the guild holds. Garrisons stay until
    /// the tile is fought over.
    function reinforce(uint256 tile, uint256 count) external {
        _requireSettled();
        if (tile >= TILE_COUNT) revert BadTile();
        if (count == 0) revert ZeroAmount();
        uint256 guildId = holder[tile];
        if (guildId == 0 || !guilds.isMember(guildId, msg.sender)) revert NotHolder();
        if (troops[guildId] < count) revert InsufficientTroops();
        troops[guildId] -= count;
        garrison[tile] += count;
        emit Reinforced(tile, guildId, msg.sender, count, garrison[tile]);
    }

    /// @notice Pack the payload of a KIND_ATTACK proposal: tile (upper 128 bits) | troops.
    function packAttackData(uint256 tile, uint256 troopCount) public pure returns (bytes32) {
        require(tile < TILE_COUNT && troopCount < 2 ** 128, "pack");
        return bytes32((tile << 128) | troopCount);
    }

    function unpackAttackData(bytes32 data) public pure returns (uint256 tile, uint256 troopCount) {
        tile = uint256(data) >> 128;
        troopCount = uint256(data) & (2 ** 128 - 1);
    }

    /// @notice Declare a voted attack in the current epoch, committing the troops now.
    function declareAttack(uint256 proposalId) external returns (uint256 attackId) {
        uint256 epoch = _requireSettled();
        IGuilds.Proposal memory p = guilds.proposal(proposalId);
        if (p.kind != GUILD_KIND_ATTACK) revert WrongKind();
        if (proposalUsed[proposalId]) revert ProposalUsed();
        uint256 guildId = p.guild;
        if (!guilds.isMember(guildId, msg.sender)) revert NotMember();
        if (!guilds.hasMajority(proposalId)) revert NoMajority();
        (uint256 tile, uint256 force) = unpackAttackData(p.data);
        if (tile >= TILE_COUNT) revert BadTile();
        if (force == 0) revert ZeroAmount();
        uint256 defender = holder[tile];
        if (defender == guildId) revert OwnTile();
        if (hasAttacked[epoch][guildId][tile]) revert AlreadyAttacking();
        if (_tileAttacks[epoch][tile].length >= MAX_ATTACKS_PER_TILE) revert TileCrowded();
        if (troops[guildId] < force) revert InsufficientTroops();

        proposalUsed[proposalId] = true;
        hasAttacked[epoch][guildId][tile] = true;
        troops[guildId] -= force;
        attackId = _attacks.length;
        _attacks.push(
            Attack({
                epoch: uint64(epoch),
                guild: uint64(guildId),
                defender: uint64(defender),
                tile: uint8(tile),
                resolved: false,
                won: false,
                troops: force,
                survivors: 0
            })
        );
        if (_tileAttacks[epoch][tile].length == 0) _attackedTiles[epoch].push(uint8(tile));
        _tileAttacks[epoch][tile].push(attackId);
        if (defender != 0) _attackLog[guildId][defender].push(uint32(epoch));
        emit AttackDeclared(attackId, epoch, guildId, tile, force, defender, proposalId);
    }

    // ---------------------------------------------------------------- settlement

    /// @notice Settle ended epochs, resolving up to `maxTiles` contested tiles (one unit of budget
    /// is also spent per epoch completed). Call repeatedly until `settledEpoch == currentEpoch()`.
    function settle(uint256 maxTiles) external {
        if (maxTiles == 0) revert ZeroBudget();
        uint256 current = currentEpoch();
        uint256 budget = maxTiles;
        while (settledEpoch < current && budget != 0) {
            uint256 epoch = settledEpoch;
            uint8[] storage tiles = _attackedTiles[epoch];
            uint256 cursor = settleCursor;
            if (cursor == 0) _distribute(epoch);
            uint256 n = tiles.length;
            while (cursor < n && budget != 0) {
                _resolve(epoch, tiles[cursor]);
                ++cursor;
                --budget;
            }
            settleCursor = cursor;
            if (cursor < n) return;
            settleCursor = 0;
            settledEpoch = epoch + 1;
            if (budget != 0) --budget;
            emit EpochSettled(epoch);
        }
    }

    function _distribute(uint256 epoch) private {
        uint256 amount = incomePool[epoch] + carriedIncome;
        if (amount == 0) return;
        uint256 tiles = totalTilesHeld;
        if (tiles == 0) {
            carriedIncome = amount;
            return;
        }
        uint256 perTile = amount * ACC_SCALE / tiles;
        accIncomePerTile += perTile;
        uint256 distributed = perTile * tiles / ACC_SCALE;
        carriedIncome = amount - distributed;
        emit IncomeDistributed(epoch, distributed, tiles);
    }

    function _resolve(uint256 epoch, uint256 tile) private {
        uint256[] storage ids = _tileAttacks[epoch][tile];
        uint256 previous = holder[tile];
        uint256 defence = garrison[tile];
        (uint256 total, uint256 winningIndex) = _tally(ids, defence);
        (uint256 winner, uint256 newGarrison) = _applyAttacks(ids, total, winningIndex);
        uint256 defenceSurvivors = defence - _loss(defence, total);
        if (winner != 0) {
            if (previous != 0) {
                troops[previous] += defenceSurvivors;
                _setTiles(previous, tilesHeld[previous] - 1, epoch);
            }
            _setTiles(winner, tilesHeld[winner] + 1, epoch);
            holder[tile] = winner;
            garrison[tile] = newGarrison;
            emit TileResolved(epoch, tile, previous, winner, newGarrison);
        } else {
            garrison[tile] = defenceSurvivors;
            emit TileResolved(epoch, tile, previous, previous, defenceSurvivors);
        }
    }

    /// @dev Sum of all forces on the tile and the index of the capturing attack, or
    /// type(uint256).max when the holder keeps the tile (no attacker strictly stronger than the
    /// garrison and every other attacker).
    function _tally(uint256[] storage ids, uint256 defence) private view returns (uint256 total, uint256 winningIndex) {
        total = defence;
        uint256 best;
        bool tie;
        winningIndex = type(uint256).max;
        for (uint256 i; i < ids.length; ++i) {
            uint256 force = _attacks[ids[i]].troops;
            total += force;
            if (force > best) {
                best = force;
                winningIndex = i;
                tie = false;
            } else if (force == best) {
                tie = true;
            }
        }
        if (tie || best <= defence) winningIndex = type(uint256).max;
    }

    function _applyAttacks(uint256[] storage ids, uint256 total, uint256 winningIndex)
        private
        returns (uint256 winner, uint256 newGarrison)
    {
        for (uint256 i; i < ids.length; ++i) {
            Attack storage a = _attacks[ids[i]];
            uint256 survivors = a.troops - _loss(a.troops, total);
            bool won = i == winningIndex;
            a.resolved = true;
            a.won = won;
            a.survivors = survivors;
            if (won) {
                winner = a.guild;
                newGarrison = survivors;
            } else {
                troops[a.guild] += survivors;
            }
            emit AttackResolved(ids[i], won, survivors);
        }
    }

    /// @dev Troops lost by a force of `force` in a battle of `total` troops: proportional to the
    /// opposing strength, always strictly less than the force itself.
    function _loss(uint256 force, uint256 total) private pure returns (uint256) {
        return total == 0 ? 0 : force * (total - force) / total;
    }

    function _setTiles(uint256 guildId, uint256 count, uint256 epoch) private {
        _harvest(guildId);
        totalTilesHeld = totalTilesHeld + count - tilesHeld[guildId];
        tilesHeld[guildId] = count;
        _rewardDebt[guildId] = count * accIncomePerTile / ACC_SCALE;
        Checkpoint[] storage cps = _checkpoints[guildId];
        uint32 season_ = uint32(seasonOf(epoch));
        if (cps.length != 0 && cps[cps.length - 1].season == season_) {
            cps[cps.length - 1].tiles = uint32(count);
        } else {
            cps.push(Checkpoint({season: season_, tiles: uint32(count)}));
        }
    }

    // ---------------------------------------------------------------- treasury

    /// @notice Move a guild's accrued tile income into its treasury.
    function harvest(uint256 guildId) external {
        _harvest(guildId);
    }

    function _harvest(uint256 guildId) private {
        uint256 accrued = tilesHeld[guildId] * accIncomePerTile / ACC_SCALE;
        uint256 pending = accrued - _rewardDebt[guildId];
        if (pending != 0) {
            _rewardDebt[guildId] = accrued;
            treasury[guildId] += pending;
            emit IncomeHarvested(guildId, pending);
        }
    }

    /// @notice Pay the guild treasury out equally to current members after a KIND_DISTRIBUTE vote.
    function distributeTreasury(uint256 proposalId) external {
        IGuilds.Proposal memory p = guilds.proposal(proposalId);
        if (p.kind != GUILD_KIND_DISTRIBUTE) revert WrongKind();
        if (proposalUsed[proposalId]) revert ProposalUsed();
        uint256 guildId = p.guild;
        if (!guilds.isMember(guildId, msg.sender)) revert NotMember();
        if (!guilds.hasMajority(proposalId)) revert NoMajority();
        proposalUsed[proposalId] = true;
        _harvest(guildId);
        address[] memory members = guilds.membersOf(guildId);
        uint256 each = treasury[guildId] / members.length;
        if (each == 0) revert NothingToDistribute();
        treasury[guildId] -= each * members.length;
        for (uint256 i; i < members.length; ++i) {
            if (!token.transfer(members[i], each)) revert TransferFailed();
        }
        emit TreasuryDistributed(guildId, proposalId, each, members.length);
    }

    // ---------------------------------------------------------------- bonds (Diplomacy only)

    function lockBond(uint256 guildId, uint256 amount) external {
        if (msg.sender != address(diplomacy)) revert NotDiplomacy();
        _harvest(guildId);
        if (treasury[guildId] < amount) revert InsufficientTreasury();
        treasury[guildId] -= amount;
        lockedBonds[guildId] += amount;
        emit BondLocked(guildId, amount);
    }

    function releaseBond(uint256 guildId, uint256 amount) external {
        if (msg.sender != address(diplomacy)) revert NotDiplomacy();
        lockedBonds[guildId] -= amount;
        treasury[guildId] += amount;
        emit BondReleased(guildId, amount);
    }

    function slashBond(uint256 from, uint256 to, uint256 amount) external {
        if (msg.sender != address(diplomacy)) revert NotDiplomacy();
        lockedBonds[from] -= amount;
        treasury[to] += amount;
        emit BondSlashed(from, to, amount);
    }

    // ---------------------------------------------------------------- views

    function attackCount() external view returns (uint256) {
        return _attacks.length;
    }

    function attack(uint256 attackId) external view returns (Attack memory) {
        return _attacks[attackId];
    }

    function attackedTiles(uint256 epoch) external view returns (uint8[] memory) {
        return _attackedTiles[epoch];
    }

    function tileAttacks(uint256 epoch, uint256 tile) external view returns (uint256[] memory) {
        return _tileAttacks[epoch][tile];
    }

    function attackLogLength(uint256 attacker, uint256 defender) external view returns (uint256) {
        return _attackLog[attacker][defender].length;
    }

    function attackLogAt(uint256 attacker, uint256 defender, uint256 index) external view returns (uint256) {
        return _attackLog[attacker][defender][index];
    }

    function pendingIncome(uint256 guildId) external view returns (uint256) {
        return tilesHeld[guildId] * accIncomePerTile / ACC_SCALE - _rewardDebt[guildId];
    }

    function checkpointCount(uint256 guildId) external view returns (uint256) {
        return _checkpoints[guildId].length;
    }

    /// @notice Tiles a guild held once the last epoch of `season_` was settled. Only meaningful
    /// after that settlement; before it the value reflects the latest settled state.
    function tilesAtSeasonEnd(uint256 guildId, uint256 season_) external view returns (uint256) {
        Checkpoint[] storage cps = _checkpoints[guildId];
        uint256 lo;
        uint256 hi = cps.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (cps[mid].season <= season_) lo = mid + 1;
            else hi = mid;
        }
        return lo == 0 ? 0 : cps[lo - 1].tiles;
    }

    /// @notice The whole map as guild ids, row-major.
    function map() external view returns (uint256[144] memory tiles) {
        for (uint256 i; i < TILE_COUNT; ++i) {
            tiles[i] = holder[i];
        }
    }

    // ---------------------------------------------------------------- internals

    function _requireMember(uint256 guildId) private view {
        if (!guilds.isMember(guildId, msg.sender)) revert NotMember();
    }

    function _requireSettled() private view returns (uint256 epoch) {
        epoch = currentEpoch();
        if (settledEpoch != epoch) revert EpochNotSettled();
    }
}
