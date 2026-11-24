# Season 0 — Technical design

> Binding for Season 0. The game itself is specified in [`RULES.md`](RULES.md), and the work is ordered in
> [`TASKS.md`](TASKS.md). When this document and the code disagree, fix one of them in the same pull request.

## 1. Shape of the system

| Path | What it is |
|---|---|
| `packages/garden` | Foundry project. `Garden.sol` implements every rule of `RULES.md` and holds every encrypted value. |
| `packages/garden/script` | The Sepolia deployment script and the keeper, which publishes duels and closes seasons. |
| `packages/app` | The React client: Vite, wagmi, viem and Zama's React SDK. UI copy is Italian. |
| `packages/contracts`, `packages/client` | The MUD MVP. Frozen: no new work, and not deployed for Season 0. Its notes (`docs/architecture.md`, `docs/tasks/`, `deploy_instructions.md`) describe the MVP only. |

**Why Season 0 leaves MUD.** In FHEVM, access to an encrypted value is granted to a contract address. A MUD
System is upgraded by registering a new address, which would lose access to every encrypted value the old one
stored. And the namespace owner can rewrite any table, so whoever deploys the World could replace a crystal's level
with another encrypted value. Both break invariant 4 of `RULES.md`. A single immutable contract keeps that promise
simple to state and easy to check.

## 2. The Garden contract

- **Immutable.** No owner, no admin, no proxy, no pause, no setter, no `selfdestruct`, no `delegatecall`. Every
  parameter in `RULES.md` §12 is a constructor argument stored as an `immutable`. A fix is a new deployment.
- **One contract holds every encrypted value.** If `Garden` exceeds the 24,576-byte limit, move the ERC-721 into a
  `CrystalToken` deployed by `Garden`'s constructor. The token holds no secrets and calls back into `Garden` on
  every transfer. Do not split the game logic itself across contracts.
- **ERC-721** comes from OpenZeppelin. Every function that sends ETH is `nonReentrant`.
- **Configuration.** `Garden` inherits `ZamaEthereumConfig`, which supplies the FHEVM addresses for Sepolia and
  mainnet. Never hard-code a protocol address.

### 2.1 State

Per crystal (`tokenId`):

| Field | Type | Who can read it |
|---|---|---|
| `element` | `euint8`: 0 = Fire, 1 = Earth, 2 = Water | The owner, and past owners |
| `level` | `euint8`, from 1 to `MAX_LEVEL` | The owner |
| `mana` | `euint64`, whole MANA | The owner |
| `lastAccrual` | `uint64` timestamp | Everyone |
| `openLobby` | lobby id, 0 when none | Everyone |
| `wins`, `losses` | `uint32`, lifetime, kept after the crystal is shattered | Everyone |

- **Per lobby:** the creator's crystal, `stake` (`uint64`), `openedAt`, `creatorPaid` (`ebool`) and a status: open,
  cancelled or fought.
- **Per duel:** both crystals, the stake, its season, `creatorWins` (`ebool`, publicly decryptable) and a
  `published` flag.
- **Per season:** `pot` (`euint64`), wins and losses per crystal, the id of each crystal's latest counted win, the
  top three and a `closed` flag. Seasons are numbered from 1, and season 1 starts at the deployment.
- **Choices used:** every input handle `attune` has accepted (§2.2, Attune).

The contract's ETH balance always equals `CHARGE × live crystals`. `forge` is the only call that takes ETH: `Garden`
has no `receive` or `fallback`. ETH that arrives without a call would sit on top, and nothing would ever move it. It
can come from another contract's `selfdestruct`, from a block reward or withdrawal credited to the address, or from a
transfer before deployment.

### 2.2 Encrypted logic (normative)

Names follow `@fhevm/solidity` 0.13.4; check the installed `FHE.sol` before writing a call. After every operation,
call `FHE.allowThis` on each new handle that is stored, and `FHE.allow(handle, owner)` on each one the owner may
read.

**Handles.** The protocol derives a handle from its operation, its operands and the block, not from the contract or
the caller.
- So whoever is allowed on every operand of an operation can recompute its result in the same block, through a
  contract of their own, and grant it to anyone. A trivial encryption has no encrypted operand, so anyone can
  recompute it.
- Granting a handle to the contract and the owner alone is therefore not enough. Nobody else may be able to
  recompute it either.

Garden keeps to this in three places:
- **A crystal's handles descend from its own random draw**, which only Garden ever holds. With `asEuint8(1)` and
  `asEuint64(0)`, every crystal forged in a block would share its level and MANA handles. Any contract could also
  make the same handles and grant them to anyone.
- **Every pot starts from `GARDEN_ZERO`**, an encrypted zero that only Garden holds, drawn at construction as
  `and(randEuint64(), 0)`. For an empty pot `FHE.add` would use an encrypted plaintext 0, and a shatterer, who holds
  the crystal's MANA handle, could recompute the season's first pot.
- **A transfer seals the crystal again with `GARDEN_ZERO`** (Transfer, below).

Every later stored handle combines a crystal's own handles with public scalars, encrypted inputs, other crystals'
handles or `GARDEN_ZERO`. So nobody but Garden and the crystal's owner can recompute it. The element is the exception,
because past owners keep it under the rules.

The Arena keeps to the same line:
- **`creatorPaid`** is granted to Garden alone. The creator can recompute it in the opening block, from its own MANA and
  the public stake, and learns only whether it paid, which it knew.
- **A duel's outcome and both new balances** descend from the coin, which only Garden draws on every join. Nobody can
  recompute them, not even an owner of both crystals. A publicly decryptable handle can be decrypted by anyone, but
  only Garden may compute on it.

**Accrual.** Plaintext, and run first in every call that touches a crystal's MANA. `SECONDS_PER_MANA` is
`1 days / MANA_PER_DAY`; the constructor requires the division to be exact.

```
units        = (block.timestamp - lastAccrual) / SECONDS_PER_MANA
lastAccrual += units * SECONDS_PER_MANA          // the remainder waits for the next call
mana         = add(mana, units)
```

Garden stores the credit at once and keeps it for itself (`allowThis`). The call then grants the owner the balance it
ends with.
- A call that reads `mana` after accruing, or accrues twice, still finds the credit.
- A call that forgets the owner's grant cannot lock the crystal. The next action, or a shatter, still computes on the
  stored balance, and the charge still comes back.

**Forge** — payable, `msg.value == CHARGE`.

```
draw    = randEuint16()
element = asEuint8(rem(draw, 3))                  // 65,536 mod 3 = 1: a bias of one part in 65,536
zero    = and(draw, 0)                            // beside rem, so it adds nothing to the depth
level   = asEuint8(or(zero, 1))                   // level 1 and no MANA are public facts, but their handles
mana    = asEuint64(zero)                         // come from the draw (Handles, above)
```

**Attune** `(tokenId, externalEbool rise, bytes proof)` — owner only, with a proof that is not empty and an input
that has not been used before. Accrue first.

```
r     = fromExternal(rise, proof)
cost  = mul(asEuint64(mul(level, level)), LEVEL_COST)   // level ≤ MAX_LEVEL ≤ 15, so level² fits in euint8
doIt  = and(and(r, lt(level, MAX_LEVEL)), ge(mana, cost))  // the MANA check waits on the cost, so it comes last
level = select(doIt, add(level, 1), level)
spent = select(doIt, cost, asEuint64(0))
mana  = sub(mana, spent)
pot[currentSeason] = add(pot[currentSeason], spent)    // an empty pot starts from GARDEN_ZERO
```

- **The proof.** With an empty proof, `fromExternal` turns the zero handle into an encrypted plaintext `false`, a hold
  that anyone reads in the calldata. It also takes any `ebool` that the caller and Garden are allowed on, whose value
  can be public too, such as a trivial encryption. Garden refuses an empty proof, so every choice it accepts was
  encrypted for Garden and for the owner, who submits it.
- **Once per input.** The input's handle sits in the calldata. Used twice, it would show everyone that two
  attunements made the same choice. Garden records every handle it accepts and refuses it a second time, so each
  attunement takes a fresh encryption. Both checks read only public data.
- **New handles every time.** On a hold or a refused rise, `spent` is an encrypted 0, so the level, the MANA and the
  pot get new handles whatever happened. An unchanged handle would tell everyone that nothing had changed.
- **Who can recompute.** Importing the input leaves the caller allowed on `r` until the transaction ends. A contract
  that owns a crystal can therefore recompute the new level and MANA in that transaction, and they are its own. It
  cannot recompute the pot, because it never holds the pot that `spent` was added to, nor `GARDEN_ZERO` when the pot
  is empty.

**Open a lobby** `(tokenId, uint64 stake)` — owner only, the crystal not already waiting, and
`MIN_STAKE <= stake <= MAX_STAKE` (`RULES.md` §7). The stake and its bounds are public, so the check reveals nothing.

```
paid = ge(mana, stake)
mana = sub(mana, select(paid, asEuint64(stake), asEuint64(0)))
lobby.creatorPaid = paid
```

**Cancel** — the creator, from `LOBBY_TIMEOUT` after opening, if nobody joined. Accrue, then
`mana = add(mana, select(creatorPaid, stake, 0))`, and unlock the crystal. A lobby does not expire: until its creator
cancels it, a challenger can still join.

**Join** `(lobbyId, tokenId)` — the owner of a different crystal that is not waiting. The duel is fought here.
Close the lobby and unlock the creator's crystal first, before any encrypted operation. `A` is the creator's crystal
and `B` the challenger's; accrue both first.

```
same    = eq(eA, eB)
aBeatsB = eq(eB, rem(add(eA, 1), 3))              // Fire > Earth > Water > Fire
coin    = randEbool()                             // drawn every time: nothing branches on the inputs
mirror  = select(eq(lA, lB), coin, gt(lA, lB))
aWins   = select(same, mirror, aBeatsB)           // elements and levels alone: MANA never wins a duel
both    = and(paidA, ge(manaB, stake))            // the stake moves only if both crystals covered it
moved   = select(both, stake, 0)
manaA   = add(manaA, select(both, select(aWins, 2 × stake, 0), select(paidA, stake, 0)))
manaB   = select(aWins, sub(manaB, moved), add(manaB, moved))
duel.creatorWins = makePubliclyDecryptable(aWins)
```

`RULES.md` §7 as amended in #12: the outcome reads no payment, and the stake changes hands only when both crystals
covered it.
- **A** put up its stake at opening if it covered it (`paidA`). When both covered, A gets both stakes if it won and
  nothing if it lost. Otherwise it gets back what it put up: its stake, or nothing if it could not cover it.
- **B** puts up its stake and settles it in the same call, so its balance moves only by `moved`. The `sub` cannot
  wrap: `moved` is nonzero only if B covered the stake.
- **Whether the stakes moved** is never stored or granted. Every line runs whatever the payments were, so the duel
  itself shows nobody outside it. Each player sees it in its own balance (`RULES.md` §9). Public history can still
  settle it when it settles whether each side could cover the stake. A crystal forged too recently to have earned
  the stake cannot, and one that has never attuned has a balance others can often work out (`RULES.md` §5).

The duel records the season in progress, which it counts for once published.

**Publish** `(duelId, bool creatorWon, bytes proof)` — anyone, once per duel.

```
checkSignatures([duel.creatorWins], abi.encode(creatorWon), proof)
```

Check only the stored handle, never one the caller passes. Set `published` before the check, which reverts the whole
call if it fails. Then update both lifetime records, also for a crystal shattered since the duel, and, if the duel's
season is still open, its wins and losses and the winner's place in the top three (T06).

The ranking key is the season's wins, then the latest counted win's duel id, lower first: duel ids grow as duels
are fought, so this is "reached the score first" in `RULES.md` §8, whatever order results are published in. A
crystal's key changes only when it wins, and then it improves, so inserting the winner keeps the top three exact
without scanning every crystal. A tie-break on losses would break that: a ranked crystal that lost could fall below
one nobody tracks.

**Close a season** `(season)` — anyone, once, from `SEASON_CLOSE_DELAY` after the season ends.

```
for each of the top three that still exists:
    share = div(mul(pot, pct), 100)
    mana  = add(mana, share)
rest = sub(pot, sum of the shares)
pot[currentSeason] = add(pot[currentSeason], rest)
```

The shares of missing or shattered crystals stay in `rest`. It goes to the season in progress, which cannot be
closed yet, rather than to `season + 1`, which may already be closed if this call comes late. The pot is never
decrypted. Each winner can still work out the pot from its own share, because the split is fixed; `RULES.md` §8
accepts this.

**Shatter** `(tokenId)` — owner only, the crystal not waiting in a lobby. Accrue, add the crystal's MANA to the
current season's pot (an empty pot starts from `GARDEN_ZERO`), burn the token, and send `CHARGE` to the owner last.

**Transfer** — the ERC-721 `_update` hook. Revert if the crystal is waiting in a lobby. On a transfer between two
accounts (not a mint or a burn), seal the crystal again for the new owner.
- `level = add(level, asEuint8(GARDEN_ZERO))` and `mana = add(mana, GARDEN_ZERO)` produce new handles. Call
  `allowThis` and `allow(newOwner)` on both, and `allow(newOwner)` on `element`.
- A plaintext 0 would not do. The previous owner still holds the old handles, so she could recompute
  `add(level, 0)` in the transfer's block and grant herself the result.
- A test must show that the previous owner cannot decrypt the new handles, even with a contract of hers that
  recomputes the reseal in that block.

Until T07 builds this, `_update` refuses every transfer between accounts: a waiting crystal with `CrystalWaiting`
(since T05, checked first so that the lock outlasts this refusal), any other with `TransfersNotOpen`. Without the
reseal, the previous owner would keep reading the level and MANA, and the new owner could not read them.

### 2.3 Rules for every change

1. Encrypted values never steer control flow: no `if`, `require` or `revert` reads one. Compute both sides and
   choose with `FHE.select`.
2. No event field, revert reason or public storage write depends on a secret. Events carry public data only (§2.5).
3. A plaintext becomes encrypted (`asEuintXX`) only when its value is public anyway: constants, stakes, accrual.
4. Only duel outcomes are ever revealed, and only through the publish flow in §2.2.
5. Access to an encrypted value is granted to the contract itself and to the crystal's current owner, and to
   nobody else: not the deployer, not a builder, not the keeper. Nor may anyone else be able to recompute a stored
   handle and grant it to themselves (§2.2, Handles).
6. Checks-effects-interactions, and `nonReentrant` around ETH transfers.
7. Every external function's HCU is measured in a test with `lastHCU()`: the transaction total (cap 20,000,000)
   and the depth (cap 5,000,000). Keep each below half of its cap and record the numbers in §2.6.
8. A rule of the game changes in `RULES.md` first.

### 2.4 Public API

`forge()`, `shatter(tokenId)`, `attune(tokenId, rise, proof)`, `openLobby(tokenId, stake)`, `cancelLobby(lobbyId)`,
`joinLobby(lobbyId, tokenId)`, `publish(duelId, creatorWon, proof)`, `closeSeason(season)`. Views return a crystal's
public fields and its handles (so the owner can request decryption), open lobbies and pending duels with
pagination, the current season, and a season's ranking. Until the Sepolia deployment (T09), names and views may be
refined, and every change is recorded here. After it, changing the API means a new deployment: stop and ask.

Refined so far:

- **T03.**
  - **Construction.** The constructor takes one `Params` struct, and each later task adds its parameters to it. They
    are readable as `CHARGE`, `MANA_PER_DAY`, `SECONDS_PER_MANA` and `SEASON_LENGTH`, and `GENESIS` is the deployment
    time.
  - **The token.** It is named "Atlantysm Crystal", with the symbol `CRYSTAL`. `forge()` returns the new token id.
    Ids start at 1 and are never reused.
  - **Views.**
    - `crystalOf(tokenId)` returns the owner, the three handles, `lastAccrual` and `pendingMana`, the MANA accrued
      since `lastAccrual` and not yet credited. The balance as of now is the decrypted `mana` plus `pendingMana`.
    - `crystalsOf(owner, cursor, count)` returns an owner's crystals among `count` ids from `cursor`, and the next
      cursor (0 at the end), so the app can list a player's crystals without an indexer. Like `balanceOf`, it
      reverts for the zero address.
    - `totalSupply()` is the number of live crystals, and `lastTokenId()` the id of the latest one forged.
    - `currentSeason()`.
    - `potOf(season)` is the handle of a season's pot, which nobody can decrypt.
- **T04.**
  - **Construction.** `Params` gains `levelCost` and `maxLevel`, readable as `LEVEL_COST` and `MAX_LEVEL`. The
    constructor refuses a zero cost, a maximum below 2 or above 15 (the level is squared in a `euint8`), and a cost
    whose highest value, `levelCost × maxLevel²`, does not fit in 64 bits.
  - **`attune`** reverts with `MissingProof` when the proof is empty, and with `ChoiceReused` when the input was
    already used (§2.2).
- **T05.**
  - **Construction.** `Params` gains `minStake`, `maxStake` and `lobbyTimeout`, readable as `MIN_STAKE`, `MAX_STAKE`
    and `LOBBY_TIMEOUT`. The constructor refuses:
    - a zero minimum stake;
    - a minimum above the maximum;
    - a maximum above `type(uint64).max / 2`, since a duel's winner takes the public `2 × stake`, encrypted as a
      `euint64`;
    - a lobby timeout longer than a season, since a crystal waiting in a lobby nobody joins cannot be shattered before
      the timeout. A deployment with a short season (T09) needs a timeout as short. A zero timeout is allowed: the
      creator may cancel at once.
  - **The Arena.** `openLobby` returns the new lobby id and `joinLobby` the new duel id. Both start at 1 and are
    never reused. The creator can join its own lobby with another crystal (`RULES.md` §8 accepts it in Season 0).
  - **Reverts.** `StakeOutOfBounds`; `CrystalWaiting` when a waiting crystal opens a lobby, joins one (its own
    included), is shattered or is transferred; `LobbyNotOpen` when the lobby to join or cancel is not open, or was
    never opened; `TooEarlyToCancel`; `NotOwner`; `UnknownDuel`; `AlreadyPublished`.
  - **Records** sit in their own mapping, which `shatter` leaves alone, so a shattered crystal keeps its record and
    a duel published after a shatter still counts.
  - **Views.**
    - `crystalOf` also returns `openLobby`, `wins` and `losses`.
    - `recordOf(tokenId)` returns the wins and losses, for shattered crystals too.
    - `lobbyOf(lobbyId)` returns the crystal, the stake, `openedAt`, the status (`None`, `Open`, `Cancelled`,
      `Fought`) and the `creatorPaid` handle, granted to Garden alone (§2.2, Handles).
    - `duelOf(duelId)` returns both crystals, the season, the stake, `published` and the `creatorWins` handle.
    - `openLobbies(cursor, count)` and `pendingDuels(cursor, count)` page by id like `crystalsOf`.
    - `lastLobbyId()` and `lastDuelId()`.

### 2.5 Events

`Forged(tokenId, owner)`, `Shattered(tokenId)`, `Attuned(tokenId)`, `LobbyOpened(lobbyId, tokenId, stake)`,
`LobbyCancelled(lobbyId)`, `DuelFought(duelId, lobbyId, creatorCrystal, challengerCrystal, season)`,
`DuelPublished(duelId, winner, loser)`, `SeasonClosed(season, first, second, third)`. `Forged` indexes the token id
and the owner, and `Shattered` and `Attuned` the token id, so the app can filter them. `LobbyOpened` indexes the
lobby and the token, `LobbyCancelled` the lobby, `DuelFought` the duel and both crystals, and `DuelPublished` the
duel, the winner and the loser. `publish` also emits the library's `PublicDecryptionVerified` from Garden, with the
outcome's handle and value, which are public.

### 2.6 HCU budget

Filled in by T02 and kept current. Each number is `lastHCU()` for a single call whose inputs were made in `setUp`.
A forge test is one transaction, so within it a handle carries the depth of the calls that made it and transient
grants survive; `setUp` runs as a transaction of its own, like an earlier transaction on chain.

| Function | HCU per transaction | Depth |
|---|---|---|
| `forge` | 664,096 | 603,032 |
| `shatter` | 295,000 | 295,000 |
| `attune` | 1,420,064 | 909,032 |
| `openLobby` | 466,064 | 466,000 |
| `cancelLobby` | 350,064 | 295,000 |
| `joinLobby` | 2,045,096 | 906,000 |
| `publish` | 0 | 0 |
| `closeSeason` | | |
| transfer | | |

Every function is measured on `Garden` (`packages/garden/test/Hcu.t.sol`). Deploying costs 58,000 HCU, for
`GARDEN_ZERO`.
- **`forge`.** Most of it is the element: `randEuint16` costs 23,000, the scalar `rem` on `euint16` 580,000, and
  the cast to `euint8` 32. The zero for the level and MANA is the scalar `and` and `or` on `euint16` (61,000
  together) plus two casts of 32. It runs beside the `rem`, so it adds nothing to the depth.
- **`shatter`.** It makes two additions in a chain: the accrual's scalar `add` (133,000), then the `add` into the pot
  (162,000). An empty pot starts from `GARDEN_ZERO`, so a season's first shatter costs the same as the others.
- **`attune`.** The longest chain is the cost, then the decision, then the payment:
  - the cost: `mul` on `euint8` (150,000), a cast (32), and the scalar `mul` on `euint64` (365,000), the most
    expensive operation;
  - then `ge` (152,000), one `and` (25,000) and `select` (55,000);
  - then the `sub` from the MANA or the `add` into the pot (162,000 each).

  Beside it run the accrual (133,000), `lt` (52,000), the other `and`, and the level's scalar `add` (84,000) and
  `select`. A rise, a refused rise and a hold run the same operations, at the same cost.

- **`openLobby`.** One chain: the accrual's scalar `add` (133,000), the scalar `ge` (116,000), `select` (55,000) and
  the `sub` (162,000), plus two trivial encryptions of 32.
- **`cancelLobby`.** The accrual (133,000), then the `add` of the refund (162,000). The refund's `select` (55,000)
  runs beside the accrual.
- **`joinLobby`.** The triangle's scalar `rem` is the most expensive operation, 440,000 HCU, and it lies on the
  longest chain: `add`, `rem`, `eq`, three `select` (the outcome, the winner's share, both or the refund), then the
  payout `add`.
  - A duel whose stakes stay runs the same operations at the same cost (`Arena.t.sol`).
  - Joining with the forfeit of the T02 spike cost 2,259,064. Without it:
    - an `and` (25,000) replaces the `xor` (22,000);
    - the outcome takes one `select` fewer (55,000);
    - the two stakes are no longer added together (162,000);
    - the winner's `2 × stake` adds a trivial encryption (32).

    That is 213,968 less, at the same depth.
- **`publish`.** No encrypted operation: checking the KMS signatures costs gas only.

## 3. Toolchain

- **Solidity:** solc 0.8.24, EVM `cancun`, the optimizer on at 200 runs; Foundry 1.7.1, pinned in CI.
  - Every FHE call inlines its checks. At T05, `Garden` is 16,662 bytes with the optimizer, of the 24,576 allowed.
    Without it, it would be 27,824 and could not be deployed, so the optimizer is no longer optional. At T04 the two
    figures were 11,442 and 19,632.
  - Verification on Etherscan (T09) must use the same settings.
- **Contract packages:** `@fhevm/solidity` ^0.13.4, `encrypted-types` ^0.0.4 (which `FHE.sol` imports, so every
  contract needs it to compile) and `@openzeppelin/contracts` ^5.
- **Test packages:** `@fhevm/forge` ^0.13.1 (tests inherit `TestFhevm`) and `forge-std` v1.11.0, the tag that
  README installs, remapped exactly as `forge-std/`. Follow the `@fhevm/forge` README for the installed version, and
  do not mix it with the older standalone `forge-fhevm` template.
- **Client:** `@zama-fhe/sdk` and `@zama-fhe/react-sdk` ^3.8.0. Never import `@fhevm/sdk` (the SDK's internal
  backend) or `@zama-fhe/relayer-sdk` (deprecated). Start from the official `react-wagmi` example at the
  installed version's tag.
- **Runtime:** Node 24 for the whole workspace from T01 (Node 20 reached end of life in April 2026), pnpm 9 from
  `packageManager`. CI and Vercel take the version from `.nvmrc` and the root `engines`. The frozen MVP keeps two
  leftovers:
  - Its MUD indexer asks for `better-sqlite3` 8, which does not build on Node 24, so the root `pnpm.overrides` lifts
    8 to 12. Version 12 refuses the async transactions of MUD's drizzle-orm 0.28.6, so the explorer of `pnpm dev`
    crashes on its first block. Nothing else needs it: the MVP client syncs over RPC, and build and tests never load
    it. No version both ships Node 24 binaries and accepts those transactions, and Alessio chose this over a patch. A
    global pnpm 11 warns that it ignores the `pnpm` field of `package.json`, then hands over to the pinned 9.1.0,
    which reads it, so the override stays in `package.json` while the workspace is on pnpm 9.
  - `@types/node` stays at 20, because version 24 needs a newer TypeScript than the 5.4.2 the MVP pins.
- **Relayer:** the Sepolia relayer is open and needs no API key. Mainnet needs one; that is a later problem.
- **Reference:** Zama's agent skills (`zama-ai/skills`), enabled for the repository in `.claude/settings.json`.

## 4. Client

- **Pages**, in Italian: La Forgia, Santuario, L'Arena, Classifica. The home view is the Monolith: live crystals,
  charges held, the current season and its countdown.
- **Secrets on request.** A player's element, level and MANA are decrypted on a click, after the wallet signs a
  permit, never on page load. Everything decrypted is cleared when the account or chain changes.
- **Inputs.** Encrypted inputs are made for `Garden` and the connected account, and sent unchanged with their proof.
  Every attunement takes a fresh one: `attune` refuses an input it has already accepted.
- **Waiting is a state.** A mined receipt does not mean a result is ready. Every write shows a pending state until
  the new values decrypt, and errors are shown, not swallowed.
- **Publishing.** For a pending duel, the app fetches the public decryption and its proof through the SDK and
  calls `publish`. Any visitor can do it.
- **Reads** go through view functions. There is no indexer in Season 0.
- **Headers.** Vercel serves the app with the COOP and COEP headers that let the FHE backend run multithreaded.
  Check that the wallet connectors still work with them before keeping them.

## 5. Tests

- **Rules.** Every rule in `RULES.md` has a test that names its section.
- **Privacy.**
  - A stranger cannot decrypt any crystal's values, and nobody else can recompute one of its handles in the same
    block (§2.2, Handles).
  - After a transfer, the previous owner cannot decrypt the new level and MANA, even by recomputing the reseal.
  - No event or revert differs between a rise, a refused rise and a hold, or between a duel whose stakes moved and
    one whose stakes stayed.
- **Adversarial.** A forged outcome, a replayed proof and a second publish are rejected. A season cannot be
  closed early or twice. A crystal waiting in a lobby cannot be transferred, shattered or entered twice. A stake
  below or above its bounds is rejected.
- **Ranking.** The same duels give the same top three whatever order their results are published in.
- **Conservation**, fuzzed: the ETH balance equals `CHARGE ×` live crystals, and the MANA in crystals and pots
  equals the MANA accrued, read with `plaintextOf`.
- **Mocks are not production.** The test stack computes in cleartext; T09 plays a full round on Sepolia.

## 6. Deployment

- A Forge script deploys `Garden` to Sepolia with the Season 0 parameters and verifies the source on Etherscan.
  The addresses and the transactions of the full round go in `docs/season0-deployment.md`.
- Alessio deploys, or gives an explicit go-ahead. Private keys never enter the repository.

## 7. Before mainnet (not in Season 0)

- **The Monolith stakes.** The charges go into ETH staking, and MANA becomes the real yield, divided equally.
- **Crossing.** A successor contract names its predecessor at construction. A crystal's owner, and only the
  owner, can carry the crystal across: the old contract burns it, sends its charge and grants the successor access
  to its encrypted values, and the successor accepts crystals only from its predecessor. Without this, an
  immutable contract can only be left by shattering.
- **The rest:** the ranking weakness in `RULES.md` §8, a security audit and a legal review.
