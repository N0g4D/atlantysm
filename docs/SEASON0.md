# Season 0 — Technical design

> Binding for Season 0. The game itself is specified in [`RULES.md`](RULES.md), and the work is ordered in
> [`TASKS.md`](TASKS.md). When this document and the code disagree, fix one of them in the same pull request.

## 1. Shape of the system

| Path | What it is |
|---|---|
| `packages/garden` | Foundry project. `Garden.sol` implements every rule of `RULES.md` and holds every encrypted value. |
| `packages/garden/script` | The Sepolia deployment script and the keeper, which publishes duels and closes seasons. A result counts for its season only if published within `SEASON_CLOSE_DELAY` of the season's end, so the keeper publishes a season's duels before then. |
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
- **What Garden trusts.** Zama's protocol: its host contracts on Sepolia (the ACL, the FHE executor, the input
  verifier, the HCU limiter and the KMS verifier), all upgradeable proxies, and the coprocessors, the Gateway and the
  threshold network behind them.
  - Zama can pause the ACL or put an address on its deny list. While the ACL is paused, or Garden is denied, every call
    that computes on an encrypted value reverts: `forge`, `shatter`, `attune`, the Arena, `closeSeason` and transfers.
    Only `publish`, approvals and views, which compute on nothing, still run, and no charge comes back until Zama lifts
    it. A denied player blocks nothing: Garden can still grant to it.
  - Zama can lower the HCU caps. A close needs 4,773,000 per transaction and 1,728,000 deep, a join 2,045,096 and
    906,000, a shatter 295,000 (§2.6).
  - The ACL decides who may decrypt what, and the coprocessors and the Gateway carry its grants to the threshold
    network, which holds the keys. Whoever can upgrade or run them is trusted with the secrets too.

  `RULES.md` §3 assumes the protocol runs as it is (T08's review, F2).

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
  top three and a `closed` flag. Seasons are numbered from 1, and season 1 starts at the deployment. Closing a season
  pays out its pot and empties it.
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

**Accrual.** Plaintext, and run first in every call that changes a crystal's balance or moves MANA out of it. A transfer
seals the balance again without changing it, so it leaves the accrual for the crystal's next action (Transfer, below).
`SECONDS_PER_MANA` is `1 days / MANA_PER_DAY`; the constructor requires the division to be exact.

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

The duel records the season in progress, which it counts for if published within `SEASON_CLOSE_DELAY` of that
season's end (*Publish*, below).

**Publish** `(duelId, bool creatorWon, bytes proof)` — anyone, once per duel.

```
checkSignatures([duel.creatorWins], abi.encode(creatorWon), proof)
```

Check only the stored handle, never one the caller passes. Set `published` before the check, which reverts the whole
call if it fails. Then update both lifetime records, also for a crystal shattered since the duel. If the result comes
within `SEASON_CLOSE_DELAY` of the end of the duel's season (`block.timestamp < seasonEnd + SEASON_CLOSE_DELAY`, the
season in progress included), also count its win and loss for that season and place the winner in the top three.
Later, it counts only in the records, whether or not anyone has closed the season (`RULES.md` §8 as amended in #15).
A season can be closed only from that same moment, so a result that counts always comes before any close: the
ranking is final once the season can be closed, whoever closes it and whenever. `publish` does not read `closed`.

The ranking key is the season's wins, then the latest counted win's duel id, lower first. The latest counted win is
the highest duel id among the crystal's counted wins, not the one published last. Duel ids grow as duels are fought,
so this is "reached the score first" in `RULES.md` §8, whatever order results are published in.
- **No ties.** Each duel has one winner, so no two crystals share their latest counted win.
- **Who is ranked.** A crystal with no win counted is not ranked, so a season can end with empty places. A shattered
  crystal keeps its place.
- **Insertion is exact.** A crystal's key changes only when it wins, and then it improves. So the winner moves up past
  every crystal it is now ahead of, coming in through the first empty place or in place of the third, and the top
  three stay exact without scanning every crystal.
- **No tie-break on losses.** It would break insertion: a ranked crystal that lost could fall below one nobody tracks.

**Close a season** `(season)` — anyone, once, from `SEASON_CLOSE_DELAY` after the season ends, when its ranking has
become final (*Publish*, above). Mark the season closed and empty its pot before any encrypted operation. Nothing adds
to a past season's pot, so the pot read then is all there is.

```
rest = pot                                        // from GARDEN_ZERO if nobody paid into it
for each of the top three that still exists:
    share = div(mul(pot, pct), 100)
    mana  = add(accrue(mana), share)              // accrual first, as in every call that changes a balance
    rest  = sub(rest, share)
pot[currentSeason] = add(pot[currentSeason], rest)
```

- **The rest.** The shares of empty places and shattered crystals stay in `rest`, with what rounding leaves. It goes
  to the season in progress, which cannot be closed yet, rather than to `season + 1`, which may already be closed if
  this call comes late.
- **What the timing still decides.** The ranking is final before any close, so whoever closes pays the same places the
  same shares. Two things depend on when the close comes: which season in progress receives `rest`, and whether a
  winner is still alive to take its share. A winner's owner who shatters it before the close leaves its share in
  `rest`.
- **No wrap.** `pot × pct` fits in 64 bits while the pot holds less than 2^64 / 100 MANA. A pot holds at most the
  MANA ever accrued: at one MANA a second, the fastest rate the constructor allows, a million crystals would take
  5,800 years to accrue that much. The shares are floors of fractions that add up to one, so together they never
  exceed the pot, and `rest` never wraps.
- **Never decrypted.** The pot is not revealed, and neither are the shares. Each winner can still work out the pot
  from its own share, because the split is fixed; `RULES.md` §8 accepts this. Shares round down, so it knows the pot
  to within a few MANA: the first place to within one, the third to within four.
- **Who can recompute.** Every share descends from the closed season's pot, which only Garden holds. So nobody else
  can recompute a winner's new balance or the new pot. Each winner's new balance is granted to Garden and its owner,
  the new pot to Garden alone, and the shares and `rest` to nobody.
- **Branches.** Only on public data: which places are filled, and whether their crystals still exist. A close with
  fewer winners runs fewer operations, and one with a full pot looks the same from outside as one with an empty pot.

**Shatter** `(tokenId)` — owner only, the crystal not waiting in a lobby. Accrue, add the crystal's MANA to the
current season's pot (an empty pot starts from `GARDEN_ZERO`), burn the token, and send `CHARGE` to the owner last.

**Transfer** — the ERC-721 `_update` hook, which every mint, burn and transfer passes through. Revert with
`CrystalWaiting` if the crystal is waiting in a lobby. Only a transfer can meet one: `forge` mints a crystal before it
can wait, and `shatter` refuses a waiting crystal and clears it before burning it. Revert with `ERC721InvalidReceiver`
if the crystal would go to Garden itself, which could never shatter it, so its charge would never come back
(`RULES.md` §3, invariant 1); `safeTransferFrom` refuses Garden with the same error anyway, since Garden takes no
ERC-721. Then the ERC-721 checks the caller's approval and moves the token. Only after that, on a transfer between two
accounts (not a mint or a burn), seal the crystal again for the new owner:

```
level = or(level, asEuint8(GARDEN_ZERO))
mana  = or(mana, GARDEN_ZERO)
```

- **New handles, same values.** Call `allowThis` and `allow(newOwner)` on both, and `allow(newOwner)` on `element`,
  which keeps its handle: every previous owner keeps knowing it (`RULES.md` §4).
- **A zero only Garden holds.** A plaintext zero would not do, nor any zero anyone can encrypt, nor one made from a
  handle the previous owner holds, such as `and(level, 0)` or `and(element, 0)`. She still holds the old handles and the
  element, so she could recompute any of these in the transfer's block, then the new handles, and grant them to herself.
  She is not allowed on `GARDEN_ZERO`, which descends from a random draw, nor on its cast, which only Garden holds, and
  only for the transaction.
- **`or`, not `add`.** Both keep the value, and `or` costs a quarter as much (§2.6).
- **No accrual.** The reseal leaves the balance as it is. So the MANA accrued since `lastAccrual` stays pending, in
  public, and goes with the crystal: the new owner is credited it at the crystal's next action.
- **To oneself.** A transfer to the same account is sealed again too. It loses nothing, and keeps the condition simple.
- **The receiver.** `safeTransferFrom` calls the receiver after the hook, so a contract that takes a crystal can already
  use its level and MANA when it is called.
- **The test.** `Privacy.t.sol` shows that the previous owner cannot decrypt the new handles. A contract of hers
  recomputes the reseal in the transfer's block with the zeros anyone can make, and gets other handles. Walked back
  through the executor's events, each new handle descends from a handle she can neither use nor make again, so no other
  way would work either. Another test shows that `GARDEN_ZERO` is granted to Garden alone, not to its deployer.

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
- **T06.**
  - **Construction.** `Params` gains `seasonCloseDelay` and `prizeShares` (percent, first place first), readable as
    `SEASON_CLOSE_DELAY`, `FIRST_SHARE`, `SECOND_SHARE` and `THIRD_SHARE`. The constructor refuses:
    - shares that do not add up to 100. The centre goes to the top three in full, and past 100 a close would pay out
      more than the pot holds;
    - a place that takes more than the one above it;
    - a close delay longer than a season, which would hold a prize back past the end of the next season.

    A zero delay is accepted, but then a result counts only if it comes before the season ends, and a season's last
    duels cannot be decrypted and published by then: they count only in the records. A deployment needs a delay that
    covers both (T09).
  - **Seasons.** `closeSeason(season)` emits `SeasonClosed`. It reverts with:
    - `UnknownSeason` for season 0;
    - `TooEarlyToClose` for the season in progress, a later one, or one that ended less than `SEASON_CLOSE_DELAY` ago.
      The check subtracts, so no season number can overflow;
    - `AlreadyClosed`.
  - **Views.**
    - `rankingOf(season)` returns the top three, best first, their wins in the season, and whether the season is
      closed. An empty place is 0. A crystal shattered since keeps its place; whether its share was paid shows only
      in whether its `Shattered` event came before `SeasonClosed`.
    - `scoreOf(season, tokenId)` returns a crystal's wins and losses counted in the season, and `lastWin`, the id of
      the latest duel among those wins, which breaks ties.
    - `potOf(season)` returns 0 again once the season is closed.
- **T07.**
  - **Transfers.** `transferFrom` and both `safeTransferFrom` work as for any ERC-721, by the owner, an approved account
    or an operator, and seal the crystal again for the new owner (§2.2). A waiting crystal still reverts with
    `CrystalWaiting`, and a transfer to Garden itself with `ERC721InvalidReceiver`. `TransfersNotOpen`, which refused
    every transfer until the reseal existed, is gone.
  - **Views.** `crystalOf` returns new level and MANA handles after a transfer, and the same element handle. A transfer
    leaves `lastAccrual` and `pendingMana` as they were.

### 2.5 Events

`Forged(tokenId, owner)`, `Shattered(tokenId)`, `Attuned(tokenId)`, `LobbyOpened(lobbyId, tokenId, stake)`,
`LobbyCancelled(lobbyId)`, `DuelFought(duelId, lobbyId, creatorCrystal, challengerCrystal, season)`,
`DuelPublished(duelId, winner, loser)`, `SeasonClosed(season, first, second, third)`. `Forged` indexes the token id
and the owner, and `Shattered` and `Attuned` the token id, so the app can filter them. `LobbyOpened` indexes the
lobby and the token, `LobbyCancelled` the lobby, `DuelFought` the duel and both crystals, `DuelPublished` the
duel, the winner and the loser, and `SeasonClosed` the season. `SeasonClosed` gives 0 for an empty place, and lists a
crystal shattered before the close in its place, although its share stayed in the centre. It carries neither the pot
nor the shares. `publish` also emits the library's `PublicDecryptionVerified` from Garden, with the
outcome's handle and value, which are public. A transfer emits only the ERC-721 `Transfer`.

### 2.6 HCU budget

Filled in by T02 and kept current. Each number is `lastHCU()` for a single call whose inputs were made in `setUp`.
A forge test is one transaction, so within it a handle carries the depth of the calls that made it and transient
grants survive; `setUp` runs as a transaction of its own, like an earlier transaction on chain. Since T06, `setUp`
builds more than one transaction may hold, so it lifts the caps. The meter still runs, and every test compares its one
call with half of each cap, which is stricter than the cap itself. Each test also pins its row of the table, so a
change that costs more or less fails until the table follows.

| Function | HCU per transaction | Depth |
|---|---|---|
| `forge` | 664,096 | 603,032 |
| `shatter` | 295,000 | 295,000 |
| `attune` | 1,420,064 | 909,032 |
| `openLobby` | 466,064 | 466,000 |
| `cancelLobby` | 350,064 | 295,000 |
| `joinLobby` | 2,045,096 | 906,000 |
| `publish` | 0 | 0 |
| `closeSeason` | 4,773,000 | 1,728,000 |
| `transferFrom`, both `safeTransferFrom` | 64,032 | 34,000 |
| `approve`, `setApprovalForAll` | 0 | 0 |

Every external function that can change state is measured on `Garden` (`packages/garden/test/Hcu.t.sol`). Deploying
costs 58,000 HCU, for `GARDEN_ZERO`.
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
- **`publish`.** No encrypted operation: checking the KMS signatures costs gas only. Since T06 it also counts the
  result for its season and places the winner in the top three, in plaintext. `Hcu.t.sol` measures both a result
  that counts for its season and one that counts only in the records.
- **`closeSeason`.** Measured with three living winners, the most a close can do. Fewer winners run fewer operations,
  and what the pot holds changes nothing (`Seasons.t.sol`).
  - Each share is a scalar `mul` (365,000) and then a scalar `div` (715,000) on `euint64`: 1,080,000, the longest
    step of the call. It is added to the winner's balance (162,000) after the accrual (133,000), and taken from the
    rest with a `sub` (162,000). Each winner costs 1,537,000, three cost 4,611,000, and the `add` of the rest into the
    season in progress 162,000 more.
  - The longest chain is a share, then the three `sub`s from the rest, then that `add`: 1,728,000.
  - Each share computed in `euint128`, where it could never wrap, would cost 1,921,064 instead of 1,080,000, and the
    depth would come to 2,569,064, over half of the cap.
  - A transaction can hold at most four closes, and each one after the first deepens the chain by 162,000, through
    the pot of the season in progress. The keeper (T17) closes one season per transaction.
  - `FHE.sum` would add the shares for less than two `add`s, but it arrived only in a recent protocol release
    (Zama's changelog). The close keeps to long-supported operations, so that it works on Sepolia.
- **Transfer.** The reseal: for the level, the cast of `GARDEN_ZERO` to `euint8` (32) and the `or` on `euint8`
  (30,000); beside it, for the MANA, the `or` on `euint64` (34,000), which is the depth. `transferFrom` and both
  `safeTransferFrom` run the same hook, and `Hcu.t.sol` measures all three: the receiver's check comes after the hook
  and runs no encrypted operation. What the crystal holds changes nothing.
  - With `add`, as §2.2 first had it, the same reseal would cost 250,032 at a depth of 162,000: 88,000 on `euint8` and
    162,000 on `euint64`.
  - Accruing first would add a scalar `add` (133,000) to the MANA's chain, and change nothing anyone can read.
  - A transaction can hold 312 transfers. A crystal passed from hand to hand within one transaction deepens its chain by
    34,000 at each transfer.
- **Approvals.** `approve` and `setApprovalForAll` change no encrypted value, so they cost no HCU. The account they
  approve is granted nothing until it moves the crystal to itself (`RULES.md` §4).

## 3. Toolchain

- **Solidity:** solc 0.8.24, EVM `cancun`, the optimizer on at 200 runs; Foundry 1.7.1, pinned in CI.
  - Every FHE call inlines its checks. At T08, as at T07, `Garden` is 19,506 bytes with the optimizer, of the 24,576
    allowed, so 5,070 are left; its initcode is 23,298 of 49,152. Without the optimizer it would be 32,155 and could not
    be deployed, so the optimizer is not optional. At T06 the two figures were 19,262 and 31,805, at T05 16,662 and
    27,824, and at T04 11,442 and 19,632.
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
  calls `publish`. Any visitor can do it. A result counts for its season only if published within
  `SEASON_CLOSE_DELAY` of the season's end, so Classifica shows that deadline next to the countdown, and marks a past
  season's pending result as counting only in the records once the deadline has passed.
- **Reads** go through view functions. There is no indexer in Season 0.
- **Headers.** Vercel serves the app with the COOP and COEP headers that let the FHE backend run multithreaded.
  Check that the wallet connectors still work with them before keeping them.

## 5. Tests

- **Rules.** Every rule in `RULES.md` has a test that names its section.
- **Privacy.**
  - A stranger cannot decrypt any crystal's values, and nobody else can recompute one of its handles in the same
    block (§2.2, Handles).
  - After a transfer, the previous owner cannot decrypt the new level and MANA, even by recomputing the reseal: walked
    back through the executor's events, the new handles descend from a handle she can neither use nor make again.
  - `GARDEN_ZERO` is granted to Garden alone.
  - Fuzzed over random sequences, transfers included, read from the ACL: each live crystal's level and MANA are granted
    to its owner and to no other player, and its element to every player that has ever owned it. None of them is
    publicly decryptable, and no stored pot is either, or granted to a player. The players publish and close, so a
    lasting grant to whoever does would show.
  - A grant for one transaction is enough to leak a handle: whoever holds it may allow it to anyone, for good. The
    invariants run in a later transaction, so the tests check within the call's own: publishing grants nothing and
    makes nothing else public, whether the result counts for its season or only in the records, and neither the
    publisher, the shatterer, the attuner nor the closer may then use a pot or `GARDEN_ZERO`, nor the publisher any of
    the duel's handles.
  - No event or revert differs between a rise, a refused rise and a hold, or between a duel whose stakes moved and
    one whose stakes stayed.
  - Closing a season grants each winner's new balance to its owner only, and nobody can decrypt a pot. A close looks
    the same from outside whatever the pot holds.
- **Adversarial.** A forged outcome, a replayed proof and a second publish are rejected. A season cannot be
  closed early or twice. A crystal waiting in a lobby cannot be transferred, shattered or entered twice. A stake
  below or above its bounds is rejected. An owner that reenters while a charge comes back can neither shatter again
  nor sell the crystal it is shattering, which is burned before the charge leaves.
- **Ranking.** The same duels give the same top three whatever order their results are published in, and after each
  result the top three are exact for the results counted so far.
- **Conservation**, fuzzed: the ETH balance equals `CHARGE ×` live crystals, and the MANA in crystals and pots
  equals the MANA accrued, read with `plaintextOf`.
- **Nobody can change Garden** (`RULES.md` §3, invariant 4). Its external functions, read from the build's artifact, are
  exactly the game's of §2.4, its views and parameters, ERC-721's, and `confidentialProtocolId()` from
  `ZamaEthereumConfig`. Its runtime code holds no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`. A new function fails the
  test until the list and §2.4 follow it.
- **Mocks are not production.** The test stack computes in cleartext; T09 plays a full round on Sepolia.

## 6. Deployment

- A Forge script deploys `Garden` to Sepolia with the Season 0 parameters and verifies the source on Etherscan.
  The addresses and the transactions of the full round go in `docs/season0-deployment.md`.
- Alessio deploys, or gives an explicit go-ahead. Private keys never enter the repository.
- **What the tests cannot show** (T08's review, F5). The HCU in §2.6 comes from the test stack's own host contracts
  (`@fhevm/forge` 0.13.1: FHEVMExecutor v0.5.0, HCULimit v0.3.0, ACL v0.4.0). On Sepolia, T09 checks:
  - the versions the host contracts report (`getVersion()`);
  - the per-block HCU cap that every application outside its whitelist shares (`getGlobalHCUCapPerBlock()`,
    `isBlockHCUWhitelisted`). Zama's test library says the deployed hosts set it at its ceiling. A lower cap could make
    a join or a close fail in a busy block, but never `publish`, which costs no HCU;
  - a transfer in the scripted round, so that the reseal, the cast of `GARDEN_ZERO` and the `or`, runs on the real
    coprocessor at least once.

## 7. Before mainnet (not in Season 0)

- **The Monolith stakes.** The charges go into ETH staking, and MANA becomes the real yield, divided equally.
- **Crossing.** A successor contract names its predecessor at construction. A crystal's owner, and only the
  owner, can carry the crystal across: the old contract burns it, sends its charge and grants the successor access
  to its encrypted values, and the successor accepts crystals only from its predecessor. Without this, an
  immutable contract can only be left by shattering.
- **The rest:** the ranking weakness in `RULES.md` §8, a security audit and a legal review.
