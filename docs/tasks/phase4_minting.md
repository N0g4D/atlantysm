# Phase 4: Minting & Crystal Identity

**Goal:** Forge new crystals and give each one a permanent identity inside the MUD World.
**Status:** implemented in `CrystalForgeSystem.sol`, 17 dedicated tests.

---

## 1. What was built

| Artefact | Purpose |
| --- | --- |
| `CrystalForgeSystem.mintCrystal(address to)` | Forge a crystal at level 1, assign it to `to` |
| `CrystalForgeSystem.configureForge(...)` | Namespace-owner-only ERC-6551 setup, frozen by the first mint |
| `CrystalForgeSystem.crystalAccountOf/crystalEntityOf` | Public derivation, so no consumer re-implements it |
| `CrystalOwner` table | Provisional ownership ledger, entity → owner |
| `ForgeConfig` table | ERC-6551 registry / implementation / token contract / salt |
| `ForgeNonce` table | Monotonic counter, used **only** as entropy in the token id preimage |

---

## 2. Identity (ratified)

An entity is **always** `bytes32(uint256(uint160(tokenBoundAccount)))`.

This is forced, not chosen. `ArenaSystem` resolves a fighter as
`bytes32(uint256(uint160(_msgSender())))`, so an entity must be an *address* — only an address can
call — and it must be the crystal's ERC-6551 account, because the crystal is what fights.

**A human forges, a crystal fights.** `to` is the owner and may be an EOA; it is never the entity.
`testOwnerCannotFightOnTheCrystalsBehalf` pins this: the owner calling `createLobby` is rejected as
an unknown crystal.

**Why minting is gated on config.** The entity key is permanent and load-bearing for `CrystalData`,
`ManaBalance` and `ArenaLobby`. Deriving it from placeholder addresses would strand every early
crystal at an address that can never be its account, with no migration path. So `mintCrystal`
reverts with `CrystalForge_NotConfigured` until the real ERC-6551 inputs are known, and
`configureForge` reverts with `CrystalForge_AlreadyMinted` once any crystal exists — reconfiguring
later would re-derive every account and orphan all of them at once.

Account derivation follows the final ERC-6551 spec (registry v0.3.1):

```
creationCode = ERC1167_header ++ implementation ++ ERC1167_footer
               ++ abi.encode(salt, chainId, tokenContract, tokenId)
account      = CREATE2(registry, salt, keccak256(creationCode))
```

The account need not be deployed for this to hold — CREATE2 makes the address deterministic, which
is exactly what lets minting run ahead of the registry.

---

## 3. Token id derivation

```
tokenId = uint256(keccak256(abi.encodePacked(block.timestamp, _msgSender(), to, nonce)))
```

Two things worth stating explicitly:

- **`_msgSender()`, not `msg.sender`.** Inside a namespaced System `msg.sender` is the World, which
  is identical on every call — it would contribute zero entropy and would not identify the minter.
- **The nonce is not decoration.** Without it, two mints in the same block from the same sender to
  the same recipient share every other input and derive an identical id. That is reachable by one
  batched transaction, not by a hash collision. The nonce is an entropy input only; the id itself
  stays a hash.

**What this does not provide.** It is not unpredictable to a block proposer: all four inputs are
known to whoever builds the block and `block.timestamp` is theirs to nudge, so a validator can grind
for a token id — and therefore for an account address — that it likes. That is tolerable **only**
because a token id currently confers no advantage: every crystal is born at level 1 and nothing in
`ArenaSystem` reads the id. **The moment an id carries rarity, traits or ordering, this must be
replaced with commit-reveal or a VRF.**

### On MUD's own answer

MUD ships `getUniqueEntity()` (`@latticexyz/world-modules`), and it is **a monotonic counter**:
read, `+1`, write. It was not used, because the phase constraint explicitly rejected a progressive
counter for unpredictability.

The stated reason for that rejection — *avoiding collisions* — is however inverted, and worth
recording: a counter has **zero** collision risk by construction, whereas a hash has a non-zero
(negligible, ~2^-256) one. The real and valid argument against a counter is **predictability**, not
collisions. The design here ends up using a counter anyway, but as an *entropy input* rather than as
the id, which keeps uniqueness by construction while removing trivial enumerability.

---

## 4. Open points

1. **Minting is permissionless and free.** Anyone may mint, for anyone, without limit or cost beyond
   gas. This matched the phase specification and was deliberately not fixed here, but it is an open
   economic hole: crystals are the entry point to the arena, so an unbounded free supply undermines
   any scarcity the game later relies on. Gating (payment, allowlist, per-address cap) belongs to the
   phase that defines the economy.
2. **`CrystalOwner` must be retired or demoted** when the ERC-721 facade lands. See §2.
3. **A fresh crystal has no mana.** Minting writes `CrystalData` only, and `createLobby` needs a
   funded `ManaBalance`, so a new crystal cannot enter the arena until some future System
   distributes mana.
4. **Nothing deploys the token bound account.** The entity is usable as an identity from the address
   alone, but for a crystal to actually *call* the World, its account must exist on-chain. Whoever
   owns the ERC-721 will need to invoke the registry's `createAccount` — a step the game currently
   never performs.
5. **Levels never change.** `CrystalData.level` is written once at mint and no System raises it, so
   the `ADVANTAGE_MULTIPLIER` mechanic in `ArenaSystem` currently only ever sees level 1 on both
   sides. Progression needs its own phase.
