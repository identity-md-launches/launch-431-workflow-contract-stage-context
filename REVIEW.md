# Review

Self-review of the Pacts contracts against the approved workflow, written from the perspective of
the adversarial reviewer. It records what was checked, what was found and how each finding was
disposed of. It is not the independent review the workflow requires before release.

## Scope

`src/LaunchToken.sol`, `src/Guilds.sol`, `src/Realm.sol`, `src/Diplomacy.sol`, `src/Season.sol`,
`src/Banners.sol`, `script/Deploy.s.sol`, `foundry.toml`, vendored `lib/`.

## Requirements traced

| Requirement | Where | Evidence |
| --- | --- | --- |
| Fixed-supply token, 10^27 to `msg.sender`, no admin | `LaunchToken` | `LaunchTokenTest`, pinned `Token.protected.t.sol` run from `test/scratch` (6/6 pass) |
| 12x12 map, epoch and season lengths as constructor args | `Realm` | `LaunchTest.test_productionParameters` |
| Troops bought with the token; income only from purchases and fees | `Realm.buyTroops`, `_credit`, `_distribute` | `test_buyTroopsSplitsFeeAndIncome`, `test_incomeSharedPerTileAndCarriedWhenUnheld` |
| Open declaration, committed troops, joint resolution at epoch end | `declareAttack`, `settle`, `_resolve` | `test_severalAttackersOnOneTile`, `testFuzz_battleConservesTroops` |
| Larger force wins, ties keep holder, proportional losses | `_tally`, `_loss` | same, plus `test_equalForceAgainstGarrisonKeepsHolder`, `test_tiedAttackersOnEmptyTileLeaveItEmpty` |
| Anyone settles | `settle` | `test_chunkedSettlement`, `test_outsiderCannotExtractFunds` |
| Found/join, pooled troops, one vote per member, majority for attacks and pacts, majority expel | `Guilds`, `Realm.declareAttack`, `Diplomacy.signPact` | `GuildsTest`, `test_attackNeedsMajorityMembershipAndTroops`, `test_signPactNeedsMajority…` |
| Pact bonds, automatic slash to the victim, return on unbroken expiry | `Diplomacy.settlePact`, `Realm.lock/release/slashBond` | `test_betrayalSlashesBondToVictim`, `test_expiryReturnsBonds`, `testFuzz_bondAccounting` |
| Fee-funded prize pool, close by anyone, 50/30/20 split equally among members | `Season.close`, `_finalize`, `claimPrize` | `test_closeRanksAndSplitsPrizes`, `test_claimsNeverExceedPool`, `testFuzz_prizeSplitNeverExceedsPool` |
| Banners only minted by Season, per winning member and per honourable guild | `Banners.mint`, `Season.claimPrize`, `claimHonourBanner` | `test_onlySeasonMintsBanners`, `test_honourBannerForUnbrokenPact`, `test_honourBannerDeniedToBetrayer` |
| Constructor-only wiring, no constructor ETH, no `$owner` | all | `LaunchTest.test_nothingDependsOnAnOwner`, no payable constructor, `$owner` unused |
| Events for every action | all | every state-changing function emits |
| No function moves player funds except the rules | `Realm`, `Season` | `test_outsiderCannotExtractFunds`, `test_bondFunctionsOnlyForDiplomacy`, `_assertRealmSolvent` in 8 tests |

## Findings

### F1. Manifest wiring cannot express mutual trust (design, resolved)

Realm/Season (fees vs standings), Realm/Diplomacy (bond authority vs attack log) and
Season/Banners (mint authority) each need both contracts to know the other. `$contract:Name` only
points backwards. A registration call from a later constructor would be a first-come race if the
factory's deployment were not atomic. **Disposition:** Realm creates Diplomacy and Season, and
Season creates Banners, inside their constructors; each child stores `msg.sender` as its trusted
parent. Verified race-free by construction; verified the floor's checks on all six runtimes and
the EIP-3860 init code cap (`LaunchTest`), and the pinned `Project.protected.t.sol` deploying
Guilds and Realm through CREATE2 with factory-style environment (2/2 pass). Documented in README
for the manifest node: two application contracts, Guilds then Realm.

### F2. Unbounded attackers on one tile could make settlement exceed the block gas limit (medium, fixed)

Resolution of a single tile is not chunkable. Sybil guilds could each declare a one-troop attack on
one tile until `settle` no longer fits in a block, freezing the game. **Disposition:** capped at 64
attacks per tile per epoch (`MAX_ATTACKS_PER_TILE`, `TileCrowded`), which bounds one tile to well
under 2M gas; the tile loop is already chunked by `settle(maxTiles)`. Test
`RealmCapTest.test_attacksPerTileAreCapped`. Residual: a griefer can fill the 64 slots of a tile
at the cost of 64 guild foundings per epoch, which denies other guilds that tile for one epoch.

### F3. Stale yes votes from departed members (low, mitigated)

Votes are recorded per address. **Disposition:** majority is recomputed over *current* members at
execution (`Guilds.hasMajority`, `yesVotes`), so leavers and expelled members never count, and
members can flip to no to kill a stale proposal. `test_majorityRecountedAmongCurrentMembers`.

### F4. Prize claims by late joiners (low, mitigated)

**Disposition:** shares are assigned to the member list at the moment of closing; joining afterwards
earns nothing, leaving afterwards keeps the claim. `test_membersJoiningAfterCloseGetNothing`,
`test_memberLeavingAfterCloseStillClaims`.

### F5. Betrayer could withdraw its bond before the victim reacts (medium, prevented)

If detection were event-driven, a betrayer could race to `settlePact` at expiry. **Disposition:**
betrayal is derived from Realm's append-only attack log at settlement time, whoever calls; the
snapshot index stored at signing and the window end make the result path-independent. Retaliation
after a betrayal is not a betrayal; same-epoch mutual attacks slash both. Tests
`test_retaliationIsNotBetrayal`, `test_mutualBetrayalInSameEpochSlashesBoth`.

### F6. Reentrancy (informational)

The only external tokens are the fixed launch ERC-20 (no hooks) and Banners minted with `_mint`
(no receiver callback). All functions update state before transferring. No reentrancy path exists;
`claimPrize` and `distributeTreasury` were checked specifically.

### F7. Rounding (informational)

Income uses a 1e18-scaled per-tile accumulator. Distribution dust is carried to the next epoch;
harvest rounding leaves at most a few wei per tile change in Realm permanently. Prize splits floor
per member and roll the remainder into the next season. `_assertRealmSolvent` asserts the balance
never falls below what is owed.

### F8. Arithmetic bounds (informational)

Attack troops are limited to 2^128 by the payload; total troops are bounded by supply / price
(10^9 at production parameters), so `force * (total - force)` cannot overflow. Checkpoint fields
(`uint32` season and tiles) and `uint64` guild ids and epochs cannot be exceeded.

### F9. Solidity lints (informational)

`forge build` reports style lints (calls in loops, events after external calls, mixed-case
immutables). The loops are bounded (32 members, 3 ranks, 64 attacks) and the post-call events are
in functions with no reentrancy path. Left as is.

## What was re-run

```
forge build                      # solc 0.8.26, cancun, optimizer 200, bytecode_hash none
forge test                       # 80 passed, 0 failed (7 fuzz tests, 256 runs each)
forge fmt --check                # clean
EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline   # simulates 3 deployments
forge build --sizes              # all runtimes ≤ 12.4 KB; Realm init code 35.3 KB + args
```

Pinned protected tests copied to `test/scratch/` and run with a factory-style environment
(chain 11155111, CREATE2 salts, predicted addresses via `cast create2`): `TokenProtectedTest` 6/6,
`ProjectProtectedTest` 2/2. `test/scratch/` is not part of the deliverable.

## Open items for the independent reviewer

* Confirm the nested-creation topology is acceptable to the manifest and deployer (two manifest
  contracts, three constructor-created contracts discovered via getters).
* Game-balance parameters (`troopPrice`, `feeBps`, epoch and season lengths, 64-attack cap,
  32-member cap) are choices, not requirements; any change is a constructor argument or constant.
* Open membership is by the brief; the sybil considerations in README apply.
