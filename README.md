# Pacts

A public, deterministic guild strategy game on Sepolia, played with the launch token **PACT**.
Guilds hold tiles on a shared 12x12 map, attack each other in the open, vote on every move,
and sign pacts backed by token bonds that are slashed to the victim on betrayal. Seasons pay the
top guilds from a fee-funded prize pool and mint trophy NFTs.

There is no randomness, no hidden information and **no admin**: no contract stores an owner, a
privileged wallet or the factory address, and nothing depends on anyone acting after deployment
other than players and permissionless keepers. Every token the game pays out was paid in by a
player; nothing is minted and the game receives no allocation at launch.

## Contracts

| Contract | File | Deployed by | Role |
| --- | --- | --- | --- |
| `LaunchToken` | `src/LaunchToken.sol` | factory (`$token`) | Fixed-supply ERC-20 "Pacts" / "PACT", 18 decimals, 10^27 minor units minted to the deployer. No mint, owner, pause, fee or upgrade path. |
| `Guilds` | `src/Guilds.sol` | factory (manifest) | Membership and one-member-one-vote proposals. |
| `Realm` | `src/Realm.sol` | factory (manifest) | Map, troops, attacks, epoch settlement, income and guild treasuries. **Creates `Diplomacy` and `Season` in its constructor.** |
| `Diplomacy` | `src/Diplomacy.sol` | `Realm` constructor | Pacts, bonds, betrayal detection and slashing. |
| `Season` | `src/Season.sol` | `Realm` constructor | Prize pool, standings, prize claims. **Creates `Banners` in its constructor.** |
| `Banners` | `src/Banners.sol` | `Season` constructor | ERC-721 trophies; only `Season` can mint. |

Addresses of the created contracts are read from immutables: `Realm.diplomacy()`,
`Realm.season()`, `Season.banners()`.

### Why Realm creates three contracts

The brief requires constructor-only wiring with no post-deployment calls. A manifest can only
pass the address of an *earlier* contract into a later one, so two contracts can never both know
each other. The game needs exactly that in three places:

* `Realm` must send purchase fees to `Season`, and `Season` must read standings from `Realm`.
* `Realm` must let `Diplomacy` (and nobody else) lock, release and slash treasury bonds, while
  `Diplomacy` reads the attack log from `Realm`.
* `Season` must be the only minter of `Banners`.

A "register me" call from a later constructor would be a first-come race if deployment is not
atomic. Creating the dependent contract inside the constructor is race-free: the parent stores the
child's address as an immutable and the child stores `msg.sender` (the parent) as its trusted
caller. The three created contracts are fully configured by their constructors, hold no privileged
role, contain no `DELEGATECALL`/`CALLCODE`/`SELFDESTRUCT`, and are covered by the same tests as
the manifest contracts (`test/Launch.t.sol` runs the floor's runtime checks on all six).

Realm's init code is about 38 KB including constructor arguments, under the 48 KB EIP-3860 cap
(`test_initCodeUnderEip3860Limit`); its runtime is 13.6 KB.

## Launch manifest guidance

Kind `evm_project`, token `LaunchToken`, two application contracts in this order:

| Name | Constructor arguments |
| --- | --- |
| `Guilds` | none |
| `Realm` | `$token`, `$contract:Guilds`, `3600`, `604800`, `1000000000000000000`, `1000` |

Realm's arguments are `(address token, address guilds, uint256 epochLength, uint256 seasonLength,
uint256 troopPrice, uint256 feeBps)`: one-hour epochs, seven-day seasons (168 epochs), one PACT
per troop, 10% purchase fee to the prize pool. `seasonLength` must be a multiple of
`epochLength`; `feeBps` is at most 10000. `$owner` is not used anywhere. No constructor is
payable and none needs ETH. All constructor argument types are `address` or `uint256`.

```json
{
  "contracts": [
    { "contract": "Guilds", "constructorArgs": [] },
    {
      "contract": "Realm",
      "constructorArgs": ["$token", "$contract:Guilds", "3600", "604800", "1000000000000000000", "1000"]
    }
  ]
}
```

ABIs: `docs/abi/<Contract>.json` for all six contracts.

## Rules

### Time

`Realm.genesis` is the deployment timestamp. Epoch `e` runs from `genesis + e*epochLength`;
season `s` covers epochs `s*168 … s*168+167`. `currentEpoch()`, `currentSeason()`,
`seasonEndTime(s)` and `epochStart(e)` expose the clock.

### Guilds and votes (`Guilds`)

* Anyone founds a guild (`found(name)`) or joins one (`join(id)`); a player belongs to at most one
  guild and a guild holds at most 32 members. `joinedAt(guild, member)` records when each current
  member joined (reset on every join) and is what `Season` uses to decide who earned a prize.
* Every guild action is a proposal: `propose(kind, data)` by a member (the proposer votes yes),
  `vote(id, support)` by members, votes may be changed. A proposal passes while **more than half of
  the guild's current members** have voted yes; the count is recomputed among current members at
  execution, so leavers and expelled members stop counting.
* **Proposals expire.** A proposal is executable only within `PROPOSAL_LIFETIME` (one day) of its
  creation (`isLive(id)`); every executor (`executeExpel`, `Realm`, `Diplomacy`) refuses an expired
  one. An approval given under one state of the game cannot be consumed long after it changed.
* Kinds: `1` expel (`data = address`), `2` attack, `3` pact, `4` distribute treasury, `5` buy
  troops from the treasury (`data = count`), `6` reinforce a tile. Expulsions execute in `Guilds`
  (`executeExpel`) and ban the member from rejoining that guild. The other kinds are executed by
  `Realm` or `Diplomacy`, which each mark a proposal used so it executes once. **A lone member can
  only add to a guild** (buy troops with their own tokens, donate to the treasury); every move of
  pooled troops or treasury tokens is a passed vote.
* Payload layouts: attack `tile (bits 192..255) | expected defender guild (bits 128..191) | troops
  (bits 0..127)` (`Realm.packAttackData(tile, troops)` binds the tile's current holder,
  `packAttackDataAgainst` takes an explicit defender); reinforce `tile (bits 192..255) | troops`
  (`Realm.packReinforceData`); pact `partner (32 bits) | duration in epochs (32 bits) | own bond
  (96 bits) | partner bond (96 bits)` (`Diplomacy.packPactData`).

### Troops and money (`Realm`)

* `buyTroops(guild, count)`: a member pays `count * troopPrice` PACT. `feeBps` of it is
  transferred to `Season` for the current season's prize pool; the rest joins the current epoch's
  **income pool**. Troops are pooled per guild.
* `buyTroopsFromTreasury(proposalId)` executes a passed **buy-troops** proposal (kind 5, payload
  = count) with the guild treasury (same fee). `fundTreasury(guild, amount)` lets a member donate
  to the treasury, for example to back a bond.
* At settlement of epoch `e`, its income pool (plus anything carried while nobody held tiles) is
  shared per tile among the guilds holding tiles at that moment, before the epoch's battles are
  resolved. Each tile receives a whole number of token minor units, rounded down. The uncredited
  remainder (less than the number of held tiles) carries into future epochs; it is never also
  credited to the accumulator. Idle epochs cannot turn that remainder into extra income.
  Income accrues as `pendingIncome(guild)` and is moved to `treasury(guild)` by
  `harvest` or automatically whenever the guild's tile count changes or the treasury is spent.
* A passed **distribute** proposal (`distributeTreasury`) pays the treasury out equally to the
  guild's current members. That, and the fee to `Season`, are the only ways tokens leave `Realm`.

### Map, attacks and settlement (`Realm`)

* 144 tiles, index `row*12 + col`, unheld at launch (`holder(tile) == 0`). Each held tile has a
  garrison. `reinforce(proposalId)` executes a passed **reinforce** proposal (kind 6), moving
  troops from the pool onto a tile the guild holds; garrisons stay until the tile is fought over.
* `declareAttack(proposalId)`: a member executes a passed, unexpired attack proposal in the
  current epoch. The troops are committed immediately and the attack is public
  (`AttackDeclared`). A guild can attack a given tile once per epoch, never its own tile, and at
  most 64 attacks can target one tile in an epoch.
* **The vote binds the defender.** The payload names the guild expected to hold the tile (0 for an
  empty tile); `declareAttack` reverts `WrongDefender` if the holder changed since the vote, so an
  approval to take an empty or enemy tile cannot be fired at whoever holds it later.
* **Breaking a pact needs a knowing vote.** If the target's holder is an active pact partner, the
  proposal must have been created after the pact was signed (`ProposalPredatesPact` otherwise), so
  an attack voted before the pact existed cannot be turned into a betrayal by one member.
* Attacks and reinforcements require all previous epochs to be settled (`settledEpoch ==
  currentEpoch()`), so declarations always see the true holder.
* All attacks on a tile resolve together when the epoch is settled. With garrison `D` and attacker
  forces `f_i`, total `T = D + Σ f_i`:
  * the tile is captured only if a single attacker has the strictly largest force and it is larger
    than `D`; ties keep the holder;
  * every party loses `f * (T − f) / T` troops (rounded down), always fewer than it committed;
  * the capturer's survivors become the new garrison, other attackers' survivors return to their
    pools, a displaced holder's survivors retreat to its pool.
* `settle(maxTiles)`: anyone settles ended epochs. One call resolves up to `maxTiles` contested
  tiles (and spends one unit per completed epoch), so a heavy epoch is settled over several calls.
  Idle epochs are cheap.

### Pacts (`Diplomacy`)

* Two guilds pass mirrored pact proposals (partner, duration, own bond, partner bond). Each bond is
  at least one troop's price (`troopPrice`), so every pact carries a stake. A member of either
  guild calls `signPact(proposalA, proposalB)` while both proposals are unexpired; both bonds are
  locked out of the guild treasuries in `Realm`. The pact runs from the signing epoch for
  `duration` epochs. One unsettled pact per pair. The signing timestamp is stored (`signedAt`).
* **No signing over an attack in flight.** If either guild has declared an attack on the other's
  tile in the signing epoch, `signPact` reverts `AttackInFlight`; that attack would resolve inside
  the window, so the pact can only be signed once the epoch has ended. Every attack on a partner
  from the signing onwards is therefore a betrayal.
* **Betrayal** is declaring an attack on a tile the partner holds (holder at declaration) during
  the window. `Realm` logs every attack on a held tile; `Diplomacy` reads the log after the
  signing snapshot. If both guilds attack each other, only the earlier attack is a betrayal (the
  later is retaliation); attacks in the same epoch by both count for both.
* `settlePact(id)`: anyone, once the first betrayal epoch has ended or the window has passed
  unbroken. Calls during the betrayal epoch revert `PactStillActive`, keeping both bonds locked
  until all same-epoch declarations are final. Realm need not have settled that epoch's battles.
  A betrayer's bond goes to the victim's treasury; an unbroken pact returns both bonds. The outcome
  does not depend on who calls or when, which is what "automatic" means without an admin or keeper role.

### Seasons and prizes (`Season`)

* The prize pool of season `s` is the sum of fees paid during it plus rollover from season `s-1`.
* After the season's last epoch is settled, anyone calls `close(s, maxGuilds)` until the season is
  closed (chunked over the guilds that existed at the first call). Seasons close in order starting
  at zero: even the first chunk requires the previous season to be fully closed, otherwise
  `PreviousSeasonNotClosed` reverts. This ensures all incoming rollover is included before prizes
  are calculated. Guilds are ranked by tiles held
  at season end (`Realm.tilesAtSeasonEnd`), ties in favour of the earlier-founded guild.
* Ranks 1–3 receive 50/30/20% of the pool, each split equally among the members the guild has at
  closing **who joined it before the season ended** (`Guilds.joinedAt < Realm.seasonEndTime(s)`).
  Closing always happens after the end, so wallets joining in between earn nothing and cannot
  dilute the members who played. Members claim with `claimPrize(s)` and receive a victory banner,
  including when the token prize is zero because the pool is empty or the per-member share rounds
  down to zero. `claimRank(s, member)` records unclaimed banner eligibility independently of
  `claimable` and is cleared before payment and minting, so each winning member can claim only
  once. Unassigned amounts (missing rank, no eligible member, rounding) roll into the next
  season's pool.
* `claimHonourBanner(s, guild)`: a current member who joined the guild before the season ended,
  of a guild that was party to at least one pact overlapping the season and broke none, mints the
  guild's honour banner (one per guild per season) to themselves. Leaving and rejoining resets the
  join time, so a rejoiner after the end cannot claim.

### Banners

ERC-721 "Pacts Banner" / "BANNER". `mint` is restricted to `Season`. `banner(id)` returns
`(season, guild, kind, rank)`; `tokenURI` is an on-chain JSON data URI. Kinds: 1 victory, 2 honour.

## Events for the frontend

`Guilds`: `GuildFounded`, `MemberJoined`, `MemberLeft`, `MemberExpelled`, `ProposalCreated`,
`VoteCast`. `Realm`: `TroopsBought` (its last field is the proposal id of a treasury purchase, 0
for a purchase with the buyer's own tokens), `TreasuryFunded`, `Reinforced` (carries the proposal
id), `AttackDeclared`,
`AttackResolved`, `TileResolved`, `IncomeDistributed`, `EpochSettled`, `IncomeHarvested`,
`TreasuryDistributed`, `BondLocked`, `BondReleased`, `BondSlashed`. `Diplomacy`: `PactSigned`,
`PactBroken`, `PactExpired`. `Season`: `FeeRecorded`, `SeasonClosed`, `PrizeClaimed`,
`HonourBannerClaimed`. `Banners`: `BannerMinted` plus ERC-721 `Transfer`. Views `Realm.map()`,
`Guilds.membersOf`, `Diplomacy.pactsOf`/`isActive`/`betrayalOf` and `Season.result`/`closing`
give current state without replaying logs.

## Token flows

| From | To | Trigger |
| --- | --- | --- |
| player | `Realm` | `buyTroops`, `fundTreasury` |
| `Realm` | `Season` | fee share of every purchase |
| `Realm` | guild members | `distributeTreasury` after a majority vote |
| `Realm` | `Season` | fee share of `buyTroopsFromTreasury` after a majority vote |
| `Season` | winning members | `claimPrize` |

Bonds and slashes move balances between guild treasuries inside `Realm`. `Realm` holds exactly
the sum of treasuries, locked bonds, unharvested income, unsettled income pools and the carried
remainder (`_assertRealmSolvent` in the tests). Income rounding stays in the carried remainder;
treasury payout rounding stays in the guild's treasury. Unsolicited direct token transfers are
outside this accounting.

## Building and testing (offline)

```
forge build
forge test
forge fmt --check
EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline
```

`foundry.toml` pins solc 0.8.26, optimizer 200 runs, `evm_version = "cancun"` (OpenZeppelin 5.7
uses `mcopy`; Sepolia is post-Cancun), `bytecode_hash = "none"`, no ffi and no filesystem
permissions. Dependencies are vendored as plain files under `lib/` (forge-std, OpenZeppelin
Contracts 5.7.0). Tests read no environment variables and run in any order.

The suite (including fuzz tests) covers token supply and transfer, membership and
majority arithmetic, expulsion and bans, fee/income split, attack authorisation, settlement with
several attackers on one tile including ties and proportional losses, chunked settlement, income
distribution and carry-over, treasury distribution, bond locking, betrayal slashing, retaliation
and mutual betrayal, pact expiry, season closing and ranking, prize claims and rollover, honour
banners, solvency of `Realm`, and the launch floor (supply untouched by constructors, runtime
sizes, forbidden opcodes, init code size, CREATE2 deployment) for all six contracts.
Revision regressions cover chronological closing with partially closed seasons, zero-value victory
claims, income remainder conservation through idle epochs and ownership changes, and identical
bond payouts with or without an early settlement attempt in the betrayal epoch. The second
revision adds: a lone member cannot spend the treasury or commit the troop pool
(`test_loneMemberCannotSpendTreasuryWithoutVote`, `test_loneMemberCannotReinforceWithoutVote`),
attack votes bound to the defender and expiring (`test_attackProposalBoundToDefenderAndExpires`),
old votes unable to break a later pact (`test_attackVotedBeforePactCannotBreakIt`), signing
refused over an in-flight attack (`test_signPactRefusedWhileAttackOnPartnerIsInFlight`), minimum
bonds, expiring pact offers and expulsions, and post-season joiners excluded from prizes and
honour banners (`test_membersJoiningAfterSeasonEndBeforeCloseGetNothing`,
`test_honourBannerRequiresMembershipBeforeSeasonEnd`).

## Deployment and operations

* **Sepolia launch** is performed by the network's ProjectFactory from `launch.json`; no key or
  broadcast happens in this repository. `script/Deploy.s.sol` deploys the same three contracts on a
  local anvil for development (`forge script script/Deploy.s.sol:Deploy --rpc-url <anvil>
  --broadcast` with the operator's own signer). It refuses chains other than 31337 and 11155111
  when `EXPECTED_CHAIN_ID` is set.
* **Keepers are permissionless.** Someone must call `Realm.settle` after each epoch (attacks and
  reinforcements are blocked until the previous epoch is settled), `Season.close` in chronological
  order after seasons end, and `Diplomacy.settlePact` after the betrayal epoch ends or the pact
  expires. Any wallet can do this; the frontend
  should offer the buttons and the launch operator may run a cron. Nothing is lost if calls are
  late: settlement, closing and slashing are deterministic whenever they run.
* Season closing iterates every guild ever founded once; use a `maxGuilds` that fits the block gas
  limit (a few hundred is fine).

## Assumptions and known limitations

* **Open membership is the game's main trust assumption.** Anyone can join a guild that has room,
  and every member has one vote from the moment they join, as the brief requires. A joiner alone
  can do nothing with the guild's troops, treasury or bonds: every such move is a majority vote,
  attack votes are bound to the defender and all votes expire after a day. But `k+1` fresh wallets
  joining a guild of `k` members hold the majority immediately and can expel the founders, pay
  the treasury to themselves (`distributeTreasury`), sign pacts that lock its bonds or throw its
  troops away. Expulsion is a defence only while the original members are still the majority;
  the other defences are keeping the guild full (32 members) and not accumulating a large
  treasury. **The first wallet to join a memberless guild is a 1-of-1 majority and can withdraw
  everything the guild holds.** A guild whose members all leave should distribute first. Prize
  shares are fixed at closing among members who joined before the season ended, so joining after
  the end earns nothing.
* **Reinforcement timing.** Holders may (by vote) reinforce a tile until the epoch ends, after
  attacks have been declared. This is a feature of open declarations, not a bug.
* **Honour banners** require at least one pact overlapping the season backed by at least one
  troop's price per side; a guild without pacts earns none. Two guilds controlled by one player
  can still earn honour banners by signing a one-epoch pact each season at the cost of locking
  the minimum bond; the banner is a trophy with no token value. Betrayal is judged by declaration
  epoch, which is final once the season has ended.
* **Pacts while a betrayal is unsettled.** Until `settlePact` runs after a betrayal, the pact still
  counts as active for the `ProposalPredatesPact` check, so a retaliation must use a proposal
  created after the pact was signed (the usual case) or wait for the settlement, which anyone can
  trigger once the betrayal epoch has ended.
* **Memberless guilds** keep their tiles, income and treasury; nobody can withdraw until someone
  joins. Prize shares for a winner with no eligible member roll over.
* **Unbounded pact duration** is allowed; bonds stay locked until expiry or betrayal.
* **Proposal lifetime** is one day of wall-clock time (24 epochs at the launch parameters). It is
  a `Guilds` constant, independent of Realm's epoch length.
* Delayed season closings must be caught up in chronological order, including empty seasons.
  Closing one season never requires its winners to claim before the next can close.
* Tests are not an audit. The game holds player funds and needs the independent adversarial
  review before release.
