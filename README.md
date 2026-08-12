# Atlantysm

> A greenhouse the size of a city. Palms lean over neoclassical colonnades, escalators drift
> between mezzanines of glass, and the afternoon light falls pale blue on tiled floors. At the
> centre, suspended and silent, an Ethereum monolith. Around it, at small white tables, people play —
> cards laid out, tokens counted, a cat asleep between the chairs. Nobody is fighting for territory
> here. They came to test their crystals against one another, and the garden simply keeps the score.

![Atlantysm Concept](./docs/assets/banner.jpg)

Atlantysm is a techno-fantasy world where Magic Crystals are not items in an inventory. They are
autonomous entities: each one owns a wallet, holds its own energy, and steps into the arena on its
own behalf. You do not *play as* a crystal. You **instruct** one.

---

## What Atlantysm Is

Atlantysm is a **Fully On-Chain Game (FOCG)** built on **MUD v2**. There is no game server, no
authoritative backend, and no off-chain simulation reconciled after the fact. The entire game
state — identity, energy, progression, matches, and their outcomes — lives in MUD tables inside a
single `World` contract, and every rule that changes it is a `System`.

The client is a projection. Close it, replace it, or write your own: the game is unaffected.

```
                         ┌─────────────────────────────────┐
   React client ────────▶│           MUD World             │
   (a view, not a truth) │  tables = state, systems = rules│
                         └─────────────────────────────────┘
                                ▲                  ▲
                                │                  │
                   ERC-721 / ERC-20 facades   ERC-6551 accounts
                   (project state outward)    (the players themselves)
```

**Architecture at a glance**

| Layer | Contracts |
| --- | --- |
| Systems (rules) | `CrystalForgeSystem` · `ProgressionSystem` · `ArenaSystem` · `TokenBridgeSystem` |
| Tables (state) | 12 tables, incl. `CrystalData` · `ManaBalance` · `ArenaLobby` · `MatchCommitment` |
| Identity | `AtlantysmAccount` (ERC-6551) · `CrystalIdentityLib` |
| Facades | `CrystalNFT` (ERC-721) · `ManaToken` (ERC-20) |

---

## Core Features — The Engineering

### 1. Token Bound Accounts (ERC-6551): the NFT *is* the player

Every System resolves an actor with a single line:

```solidity
bytes32 entity = bytes32(uint256(uint160(_msgSender())));
```

That line fixes the identity model for the whole game. An entity must be an **address**, because
only an address can call — and it must be the crystal's **ERC-6551 token bound account**, because
the crystal is the thing that acts. Two simpler models are ruled out by construction:

- the entity **cannot be the owner's address** — ownership is transferable and one human may hold
  many crystals, so an owner-keyed model would cap every wallet at one crystal and drag a crystal's
  entire history along with each sale;
- the entity **cannot be a hash of the `tokenId`** — nothing can ever call as such a value, so the
  crystal could be minted but never play.

`CrystalNFT.mint` therefore deploys the account in the same transaction that forges the token. The
human then *instructs* the crystal:

```solidity
account.callSystem(world, abi.encodeCall(IProgressionSystem.app__claimStarterMana, ()));
```

`msg.sender` at the World is the account; MUD appends it as trusted `_msgSender()` context; every
identity check downstream resolves to the crystal, not to the person behind it.

**Authority is derived, never stored:**

```
MUD CrystalOwner ──▶ CrystalNFT.ownerOf ──▶ AtlantysmAccount.owner ──▶ who may execute
```

There is no access list to keep in sync. Selling a crystal hands over its account in the very
transaction that moves the token, because both ends read the same table.

### 2. Facade Architecture (ERC-721 / ERC-20): tokens project state, they do not hold it

`CrystalNFT` and `ManaToken` hold **no ownership or balance state of their own**. `ownerOf`,
`balanceOf` and `totalSupply` read back from MUD; every write is delegated to `TokenBridgeSystem`,
which accepts calls from exactly two registered addresses and no others.

The dependency points **one way — facade → World → System**. No System ever calls a token contract.
That is a security property rather than a layering preference: a System calling outward would hand
a reentrancy lever to whoever controls a replaceable facade address, whereas with the arrow this way
round the replaceable code is always the *outer* frame, and every table write has settled before it
regains control.

Because minting is routed through the facade, MUD state and the ERC-721 `Transfer` log **cannot
drift** — a crystal that exists without an event announcing it is unreachable, not merely
discouraged.

> **Known limit, stated plainly.** ERC-20 `Transfer` events cover holder-to-holder movement only.
> Faucet issuance, level-up burns and arena settlement change balances inside Systems called
> directly by a crystal's account — they must be, since each is identity-gated — and a contract
> cannot emit an event for a state change that happens elsewhere. `balanceOf` and `totalSupply` are
> always correct; an indexer rebuilding balances from `Transfer` events alone will drift. The
> canonical stream is MUD's own `Store_*` events.

### 3. Deterministic Commit–Reveal: elemental combat without a trusted referee

Moves are committed before a match begins and opened only afterwards, so no participant can compute
the outcome before deciding to join. Nothing block-derived is read at any point — no `blockhash`, no
`prevrandao`, no timestamp in the damage formula.

```
lobbyId    = keccak256(abi.encode(challengerEntity, lobbySalt))            // ABI-encoded, 64 bytes
commitment = keccak256(abi.encodePacked(lobbyId, playerEntity, move, salt)) // packed, 97 bytes
```

The two encodings **differ**, and confusing them fails silently: the contract only ever sees a hash,
so a wrong commitment is not rejected at commit time — it is rejected an hour later, when the reveal
is refused and the match is lost by timeout with the wager already escrowed. The client's viem
implementation was therefore cross-checked against `cast` on identical inputs before any UI was
built on it; both hashes matched and the packed preimage measured exactly 97 bytes, confirming that
the move packs as a **single byte** (a Solidity enum is a `uint8` — encoding it as `uint256` would
shift the salt by 31 bytes).

Binding `lobbyId` and `playerEntity` into the hash means a commitment cannot be replayed in another
match, nor worn by another player. It does **not** make a weak salt safe: both bound values are
public, so the salt is what hides the move.

**The elemental triangle** is a strict cycle — every element beats exactly one and loses to exactly
one, so none is dominant:

| Move | Beats | Loses to |
| --- | --- | --- |
| 🜄 Water | Fire | Earth |
| 🜂 Fire | Earth | Water |
| 🜃 Earth | Water | Fire |

Damage is `level`, doubled for the side holding the elemental advantage. Equal damage is a draw and
refunds both sides. A player who refuses to reveal does not strand the pot: once the one-hour window
closes, `claimTimeout` awards everything to whoever *did* reveal, so withholding a reveal never
beats revealing.

### 4. A Deflationary Economy

| Lever | Mechanism | Value |
| --- | --- | --- |
| Sybil gate | Exact ETH payment to mint | `0.01 ether` (configurable, never frozen) |
| Issuance | Starter mana faucet, once per crystal for life | `100 MANA` |
| Sink | Level-up cost, **quadratic**, burned | `50 × level² MANA` |
| Settlement | Arena payouts | strictly zero-sum |

Minting is permissionless but **priced**: sybil resistance is a cost floor, not a prohibition. The
faucet is bounded per *crystal*, so the mint price is what ultimately bounds mana issuance.

The level ladder is quadratic while combat damage stays **linear** in level. That asymmetry is the
point: under a linear price, power was exactly proportional to spend and an old crystal accumulated
an unbounded permanent edge. Squaring the cost makes each additional point of power cost strictly
more than the last.

Payment must be **exact** — overpaying reverts too. Returning change would mean sending ETH back
mid-mint, a reentrancy surface bought for nothing when the price is readable before the call.

---

## The Game Loop

| # | Step | What happens |
| --- | --- | --- |
| **1** | **The Forge** 🔥 | Pay the mint price in ETH. A crystal is born at level 1 and its ERC-6551 account is deployed in the same transaction. |
| **2** | **The Sanctuary — Faucet** 💧 | The crystal draws its one and only starter grant of 100 MANA, calling the World *as itself*. |
| **3** | **The Sanctuary — Ascension** 📈 | Burn `50 × level²` MANA to raise the level. Higher level means higher damage — and a strictly steeper next step. |
| **4** | **The Arena** ⚔️ | Stake mana, commit a hidden element, wait for a challenger, reveal, settle. The winner takes the pot; a draw refunds both. |

---

## Tech Stack

| Domain | Choice |
| --- | --- |
| On-chain framework | **MUD v2** (`2.2.23`) — ECS, tables & systems |
| Contracts | **Solidity `^0.8.24`**, **OpenZeppelin 5** |
| Toolchain & tests | **Foundry** (`forge`) — 147 tests across 6 suites |
| Client | **React 18** + **Vite** |
| Chain access | **viem** |
| Styling | **Tailwind CSS 3** — a custom *Soft Brutalism* system: flat fills, 2px `ink` outlines, hard offset shadows, no blur, no UI library |
| Standards | ERC-721 · ERC-20 · ERC-6551 · ERC-1271 · ERC-165 |

---

## Getting Started

Requires **Node 20**, **pnpm 9**, and **Foundry**.

```bash
pnpm install     # install the workspace (contracts + client)
pnpm dev         # mprocs: anvil, contract deploy + watch, client, and the MUD explorer
```

Open <http://localhost:3000>. The client uses a **burner wallet** generated in your browser, so
there is no connect flow — but it starts with zero ETH, and minting costs real ETH. Fund it with
**“top up”** in the MUD Dev Tools panel (bottom right) before forging your first crystal.

```bash
pnpm test        # 147 contract tests (deploys a World, then runs forge test) + client typecheck
pnpm build       # contracts codegen + client production bundle
```

> The `banner.jpg` referenced above is a placeholder — drop the concept art at
> `docs/assets/banner.jpg` and it renders.

---

## Project Status

The MVP is in **code freeze**. The full loop — forge → faucet → ascension → arena → settlement — has
been played end to end in a browser against a live chain, with no test-only shortcuts.

Ratified as non-blocking, and worth knowing before extending the client:

- **Commit secrets live in `localStorage` only.** Clearing site data or switching device means a
  move can no longer be revealed, and the match is lost by timeout. An export/import path, or
  deterministic derivation from a wallet signature, is the natural fix.
- **No loading or error boundary in the client.** The page is blank until the MUD sync completes.
- **No client-side test suite.** All 147 tests cover the contracts; client verification so far has
  been manual.

---

## Roadmap — V2

**Crysm integration.** The next chapter opens Atlantysm to **Crysm**, an external power-app that
extends what a crystal *is* beyond level and energy — resonance, affinity, lineage, and traits that
outlive a single match.

The ECS architecture is what makes this additive rather than disruptive. New parameters arrive as
**new MUD tables** keyed by the same entity, and new `System` contracts to move them. Nothing
already deployed has to change:

```ts
// mud.config.ts — V2 sketch
CrystalResonance: {
  schema: { id: "bytes32", affinity: "uint16", attunement: "uint8" },
  key: ["id"],
},
```

> Because a crystal's identity is its ERC-6551 account — a permanent address, not a row that can be
> re-keyed — any future table, System, or external application can attach state to an existing
> crystal without migrating a single record. The entity is the join key across the whole ecosystem.

Also on the horizon: transfer locks during active matches, an on-chain record of historical levels,
richer `tokenURI` metadata projecting live `CrystalData`, and calibrated economic parameters.

---

<p align="center"><em>Atlantysm — fully on-chain, MUD v2.</em></p>
