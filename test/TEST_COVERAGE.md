The additional suite uses the real fixed-supply LaunchToken and constructor-created game contracts. It needs no network, forks, extra packages, environment writes, or configuration changes.

`PactsAdversarial.t.sol` adds failed-transfer and bond-lock rollback, revoked-majority execution, malformed proposals, packing overflow, one-unit amounts, exact epoch boundaries, full-supply purchases, and fee extremes. Three properties run 1,000 inputs each: packing round trips, fee conservation across rounding boundaries, and battle outcomes independent of declaration order. A snapshot comparison also checks chunked versus single-call settlement.

`PactsInvariant.t.sol` runs 256 random sequences of 64 handler calls across six actors and three guilds. It changes membership and votes, buys and reinforces troops, declares attacks, advances and settles epochs, funds and distributes treasuries, signs and settles pacts, closes seasons in arbitrary order, claims prizes and honour banners, transfers banners directly and through approvals, and directly donates tokens. Seeded state and a deterministic handler smoke test ensure custody, battles, bonds and actual prize/treasury payouts are exercised. All token funding comes from constructor supply; none of the contracts are given synthetic balances or privileged storage changes.

Its six invariants check supply and the complete holder set, independently recorded cash flows and backing of assigned prizes, map counts and no troop creation, locked bonds against outstanding pacts, current membership and majority counts, and permanence of closed season results. Handler postconditions additionally check payout amounts, repeat-claim rejection, expulsion bans, harvest idempotence, and settlement monotonicity. Unexpected handler reverts fail the campaign. Treasury distribution uses an explicit low-level call to check payment amounts on success and atomic rollback on failure; this does not assert withdrawal liveness.

Four stronger properties failed against the accepted source and are reported in the required root `.imd-findings.json`, each with an executed, self-contained failing Foundry proof:

- Late rollover must remain accessible when seasons close out of order: 5e18 tokens become stranded in an already closed season.
- Income liabilities must remain backed: seven tiles and idle epochs produce treasury of 9e18 + 1 against 9e18 tokens.
- Same-epoch attacks must have settlement-order-independent bond payouts: inserting settlement between the two declarations changes a 10e18 bond's recipient.
- Winning members must receive their victory banners even in seasons with no new fees: the zero token prize prevents claiming the NFT.

The passing suite does not certify these failed properties. In particular, cash-flow conservation is different from solvency of all Realm liabilities, and backing of assigned Season prizes does not prove every fee remains claimable. No assertion treats the reported defects as correct, and no dust tolerance conceals the income defect. The deliberately failing proofs are in the findings JSON rather than the submitted executable test suite. Scratch copies are disposable.

Run `forge build` and `forge test` to check the deliverable. Fuzz and invariant counts are specified inline in the test files.
