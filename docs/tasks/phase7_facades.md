# Phase 7: ERC-721 and ERC-20 Facades

**Goal:** let standard wallets see crystals and mana, without the token contracts becoming a second
source of truth.
**Status:** implemented. 127 tests total, 23 of them on the facades.

---

## 1. The flow, and why it points this way

The phase brief left the direction open ("stabilisci tu il flow migliore"). It resolved to:

```
user → CrystalNFT.mint{value}(to) → World → CrystalForgeSystem  (writes MUD)
                                  ← tokenId
     → CrystalNFT emits Transfer(0, to, tokenId)
```

**MUD is the source of truth; the facades are projections, event emitters, and the only write entry
points.** The dependency points one way — facade → World → System — and **no System ever calls a
token contract**. Two reasons, in order of importance:

1. **Reentrancy.** A System calling a facade would be a System making an external call into a
   contract the namespace owner can replace at will. With the arrow this way round, the
   replaceable code is always the OUTER frame: by the time it regains control, every table write has
   settled.
2. **Single mint path.** `CrystalForgeSystem.mintCrystal` now rejects every caller but the NFT. That
   is what makes ownership single-sourced in practice: a crystal that exists without a `Transfer`
   announcing it is *unreachable*, not merely discouraged. The alternative (MUD mints, then calls the
   facade to emit) would have needed the System to trust a replaceable address AND would have left
   the event emission failable independently of the state write.

`CrystalOwner` is therefore the permanent authoritative ledger. Phase 4 had flagged it as a stopgap
to be retired when the facade arrived; the resolution went the other way — the facade holds no
ownership state at all, so the two-writers divergence that note warned about never materialised.

---

## 2. What lives where

| | ERC-721 | ERC-20 |
| --- | --- | --- |
| Ownership / balances | MUD `CrystalOwner`, `CrystalBalance` | MUD `ManaBalance` |
| Supply | — | MUD `ManaSupply` |
| Approvals / allowances | **facade storage** | **facade storage** |

Approvals stay in the facades on purpose: no System asks "who may transfer this", so putting them in
a table would mean paying MUD writes for state the game never reads. `TokenBridgeSystem` compensates
by re-checking the one fact a facade cannot be trusted on — that `from` really is the current owner.
That check is load-bearing: removing it makes `testTheBridgeRejectsAWrongFromEvenFromTheFacade` fail.

OpenZeppelin v5 is what makes a stateless facade possible: `_ownerOf`, `balanceOf` and `_update` are
virtual, and `_update` is documented as the single place ownership changes. `ERC20._update` is the
equivalent seam.

### Derived counters

`CrystalBalance` and `ManaSupply` exist only because `balanceOf(owner)` and `totalSupply()` cannot be
computed by iteration on-chain. They are **derived state maintained by convention**, and that is a
standing hazard: any System that writes `CrystalOwner`, or issues/burns mana, must update them in the
same call. This bit during implementation — seeding `ManaBalance` directly in a test left
`ManaSupply` at zero and the next `levelUp` underflowed.

### Identity was de-duplicated

`TokenBridgeSystem` needs the same `tokenId → account → entity` mapping the forge performs at mint.
Rather than copy the ERC-6551 CREATE2 derivation, it was extracted into `CrystalIdentityLib` and both
Systems now route through it. Two independent copies of that derivation would not fail loudly — they
would key transfers against entities that minting had put somewhere else.

---

## 3. Obstacles hit, and how each was resolved

**MUD table libraries have no `IStore` overloads in 2.2.23.** The generated accessors go through
`StoreSwitch`, which resolves to `msg.sender` outside a System — unusable from a facade. Resolved by
having the facades read through **view functions on `TokenBridgeSystem`** instead. That turned out to
be the better boundary anyway: the facades depend on `IWorld`, not on table layouts, and the
existence checks and identity derivation stay in one place.

**Mana can be held by an address with no crystal.** `ManaBalance` is keyed by entity, and an EOA's
entity is simply an address with nothing standing at it. Such an address can hold and move mana —
otherwise this would not be a real ERC-20 — but it can never USE it: `createLobby`,
`claimStarterMana` and `levelUp` each independently require a crystal at the caller's entity. The
identity model is enforced where it decides outcomes, not at the token layer, so wrapping mana never
becomes a way around it. Covered by
`testManaHeldByANonCrystalAddressCannotBeUsedInGame`.

**Crystals cannot be burned.** Nothing deletes `CrystalData`, so a transfer to `address(0)` would
strand the entity's mana and match history at an unreachable address. Rejected at the facade. Note
OpenZeppelin rejects it first, so the guard in `_update` is defence in depth rather than the active
check.

**Minting entropy lost an input.** `_msgSender()` inside the forge is now always the NFT, so the
minter's address no longer contributes to the token id preimage. Uniqueness never rested on it — the
monotonic nonce carries that — but the derivation is one input poorer.

---

## 4. The limit worth reading before trusting the event log

**ERC-20 `Transfer` events cover holder-to-holder movement only.** They are NOT emitted for faucet
issuance, level-up burns, or arena settlement.

This is structural, not an oversight. Solidity events can only be emitted by the contract that
declares them, but those balance changes happen inside MUD Systems called **directly by a crystal's
account** — and they must be, because each is gated on the caller's identity. Routing them through
`ManaToken` would make `_msgSender()` the token rather than the crystal and break the very check
that protects them.

Consequences, stated plainly:

- `balanceOf` and `totalSupply` are **always** correct — they read straight from MUD.
- An indexer that reconstructs balances from `Transfer` events alone **will drift**. The canonical
  stream is MUD's own `Store_SetRecord` / `Store_SpliceStaticData` on `ManaBalance`.
- The framework-native fix, if event-completeness is ever required, is MUD's delegation mechanism
  (`world.callFrom`): a crystal account delegates to the token, which then calls the System on its
  behalf, preserving `_msgSender()` while regaining the ability to emit. That carries its own trust
  implications and was left out of this phase.

The ERC-721 side does not have this problem, precisely because minting was routed through the facade.

---

## 5. Open points

1. ~~**The facades are not wired by the deploy script.**~~ **Closed in phase 8.** `PostDeploy.s.sol`
   now deploys both facades, configures the forge against the real NFT address, registers them and
   sets a mint price. `test/PostDeploy.t.sol` plays the game end to end using only the state the
   script leaves. See `phase8_deployment.md`.
2. **`tokenURI` is unimplemented.** Metadata should eventually project `CrystalData` — level in
   particular — but that needs a renderer, not just a facade.
3. **Replacing a facade silently changes who may mint.** `setTokenFacades` is not frozen, which is
   right for replaceable infrastructure, but the NFT address IS the mint authorisation. Swapping it
   is a privileged action with more reach than its name suggests.
4. **Derived counters have no invariant check on-chain.** `CrystalBalance` and `ManaSupply` are
   asserted consistent by tests, not by the contracts. A future System that forgets to maintain them
   would desync silently.
5. **No ERC-165 / metadata extensions beyond OZ defaults**, and no `ERC721Enumerable`. Enumeration
   would need yet another derived index.
