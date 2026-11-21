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
| `wins`, `losses` | `uint32`, lifetime | Everyone |

- **Per lobby:** the creator's crystal, `stake` (`uint64`), `openedAt`, `creatorPaid` (`ebool`) and a status.
- **Per duel:** both crystals, the stake, its season, `creatorWins` (`ebool`, publicly decryptable) and a
  `published` flag.
- **Per season:** `pot` (`euint64`), wins and losses per crystal, the id of each crystal's latest counted win, the
  top three and a `closed` flag.

The contract's ETH balance always equals `CHARGE × live crystals`.

### 2.2 Encrypted logic (normative)

Names follow `@fhevm/solidity` 0.13.4; check the installed `FHE.sol` before writing a call. After every operation,
call `FHE.allowThis` on each new handle that is stored, and `FHE.allow(handle, owner)` on each one the owner may
read.

**Accrual.** Plaintext, and run first in every call that touches a crystal's MANA. `SECONDS_PER_MANA` is
`1 days / MANA_PER_DAY`; the constructor requires the division to be exact.

```
units        = (block.timestamp - lastAccrual) / SECONDS_PER_MANA
lastAccrual += units * SECONDS_PER_MANA          // the remainder waits for the next call
mana         = add(mana, units)
```

**Forge** — payable, `msg.value == CHARGE`.

```
element = asEuint8(rem(randEuint16(), 3))        // 65,536 mod 3 = 1: a bias of one part in 65,536
level   = asEuint8(1)                             // public facts: every crystal starts at level 1
mana    = asEuint64(0)                            // ... and with no MANA
```

**Attune** `(tokenId, externalEbool rise, bytes proof)` — owner only.

```
r     = fromExternal(rise, proof)
cost  = mul(asEuint64(mul(level, level)), LEVEL_COST)   // level ≤ 10, so level² fits in euint8
doIt  = and(and(r, ge(mana, cost)), lt(level, MAX_LEVEL))
level = select(doIt, add(level, 1), level)
spent = select(doIt, cost, asEuint64(0))
mana  = sub(mana, spent)
pot[currentSeason] = add(pot[currentSeason], spent)
```

**Open a lobby** `(tokenId, uint64 stake)` — owner only, the crystal not already waiting, `stake > 0`.

```
paid = ge(mana, stake)
mana = sub(mana, select(paid, asEuint64(stake), asEuint64(0)))
lobby.creatorPaid = paid
```

**Cancel** — the creator, after `LOBBY_TIMEOUT`, if nobody joined: `mana = add(mana, select(creatorPaid, stake, 0))`,
then unlock the crystal.

**Join** `(lobbyId, tokenId)` — the owner of a different crystal that is not waiting. The duel is fought here.
`A` is the creator's crystal and `B` the challenger's; accrue both first.

```
paidB   = ge(manaB, stake)
manaB   = sub(manaB, select(paidB, stake, 0))
same    = eq(eA, eB)
aBeatsB = eq(eB, rem(add(eA, 1), 3))              // Fire > Earth > Water > Fire
coin    = randEbool()                             // drawn every time: nothing branches on the inputs
mirror  = select(eq(lA, lB), coin, gt(lA, lB))
normal  = select(same, mirror, aBeatsB)
aWins   = select(xor(paidA, paidB), paidA, normal)  // exactly one side paid: the payer wins
pot     = add(select(paidA, stake, 0), select(paidB, stake, 0))
manaA   = add(manaA, select(aWins, pot, 0))
manaB   = add(manaB, select(aWins, 0, pot))
duel.creatorWins = makePubliclyDecryptable(aWins)
```

Then unlock the creator's crystal.

**Publish** `(duelId, bool creatorWon, bytes proof)` — anyone, once per duel.

```
checkSignatures([duel.creatorWins], abi.encode(creatorWon), proof)
```

Check only the stored handle, never one the caller passes. Then set `published`, update both lifetime records,
and, if the duel's season is still open, its wins and losses and the winner's place in the top three.

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
decrypted.

**Shatter** `(tokenId)` — owner only, the crystal not waiting in a lobby. Accrue, add the crystal's MANA to the
current season's pot, burn the token, and send `CHARGE` to the owner last.

**Transfer** — the ERC-721 `_update` hook. Revert if the crystal is waiting in a lobby. On a transfer between two
accounts (not a mint or a burn), seal the crystal again for the new owner: `level = add(level, 0)` and
`mana = add(mana, 0)` produce new handles; call `allowThis` and `allow(newOwner)` on both, and `allow(newOwner)` on
`element`. A test must show that the previous owner cannot decrypt the new handles.

### 2.3 Rules for every change

1. Encrypted values never steer control flow: no `if`, `require` or `revert` reads one. Compute both sides and
   choose with `FHE.select`.
2. No event field, revert reason or public storage write depends on a secret. Events carry public data only (§2.5).
3. A plaintext becomes encrypted (`asEuintXX`) only when its value is public anyway: constants, stakes, accrual.
4. Only duel outcomes are ever revealed, and only through the publish flow in §2.2.
5. Access to an encrypted value is granted to the contract itself and to the crystal's current owner, and to
   nobody else: not the deployer, not a builder, not the keeper.
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

### 2.5 Events

`Forged(tokenId, owner)`, `Shattered(tokenId)`, `Attuned(tokenId)`, `LobbyOpened(lobbyId, tokenId, stake)`,
`LobbyCancelled(lobbyId)`, `DuelFought(duelId, lobbyId, creatorCrystal, challengerCrystal, season)`,
`DuelPublished(duelId, winner, loser)`, `SeasonClosed(season, first, second, third)`.

### 2.6 HCU budget

Filled in by T02 and kept current. Each number is `lastHCU()` for a single call whose inputs were made in `setUp`.
A forge test is one transaction, so within it a handle carries the depth of the calls that made it and transient
grants survive; `setUp` runs as a transaction of its own, like an earlier transaction on chain.

| Function | HCU per transaction | Depth |
|---|---|---|
| `forge` | | |
| `attune` | | |
| `openLobby` | 466,064 | 466,000 |
| `joinLobby` | 2,259,064 | 906,000 |
| `closeSeason` | | |
| transfer | | |

`openLobby` and `joinLobby` were measured on the T02 spike (`packages/garden/test/spike/`); T05 measures them again
on `Garden`. In `joinLobby` the triangle's scalar `rem` is the most expensive operation, 440,000 HCU, and it lies on
the longest chain: `add`, `rem`, `eq`, three `select`, then the payout `add`.

## 3. Toolchain

- **Solidity:** solc 0.8.24, EVM `cancun`; Foundry 1.7.1, pinned in CI.
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
- **Inputs.** Encrypted inputs are made for `Garden` and the connected account, and sent unchanged.
- **Waiting is a state.** A mined receipt does not mean a result is ready. Every write shows a pending state until
  the new values decrypt, and errors are shown, not swallowed.
- **Publishing.** For a pending duel, the app fetches the public decryption and its proof through the SDK and
  calls `publish`. Any visitor can do it.
- **Reads** go through view functions. There is no indexer in Season 0.
- **Headers.** Vercel serves the app with the COOP and COEP headers that let the FHE backend run multithreaded.
  Check that the wallet connectors still work with them before keeping them.

## 5. Tests

- **Rules.** Every rule in `RULES.md` has a test that names its section.
- **Privacy.** A stranger cannot decrypt any crystal's values. After a transfer, the previous owner cannot decrypt
  the new level and MANA. No event or revert differs between a rise, a refused rise and a hold, or between a
  forfeit and a defeat.
- **Adversarial.** A forged outcome, a replayed proof and a second publish are rejected. A season cannot be
  closed early or twice. A crystal waiting in a lobby cannot be transferred, shattered or entered twice.
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
