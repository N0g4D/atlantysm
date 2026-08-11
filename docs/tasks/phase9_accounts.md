# Phase 9: ERC-6551 Deployment & Execution

**Goal:** let a human play. Give every crystal a body it can act through, instead of an address only
a test cheat code could occupy.
**Status:** implemented. 147 tests total, 12 of them in `test/Integration.t.sol`.

Closes phase 8 open points 1 and 2, and phase 4 open point 4 — all three variants of the same gap.

---

## 1. What was actually missing

Every System in this game resolves an actor as `bytes32(uint256(uint160(_msgSender())))` and then
requires a crystal to exist at that entity. That is what makes a crystal — not its owner — the thing
that fights, funds itself and levels up.

Up to phase 8 the project passed 135 tests and was **still unplayable by a human**, because nothing
could call as that address. Every test reached the crystal's identity with `vm.prank(account)`, which
is a cheat no player has. The invariant was correct and unreachable at the same time.

Phase 9 changes no System. It gives the address a body, and the invariant is simply satisfied.

---

## 2. The three pieces

| Piece | Role |
| --- | --- |
| `AtlantysmAccount` | ERC-6551 implementation; forwards owner-authorised calls to the World |
| `CrystalNFT._deployAccount` | calls `registry.createAccount` inside `mint`, so forging and body are atomic |
| `PostDeploy` | wires the real implementation instead of the phase-8 placeholder |

### How a human plays

```solidity
account.callSystem(world, abi.encodeCall(IProgressionSystem.app__claimStarterMana, ()));
```

Alice calls the account; the account calls the World; MUD appends **the account** as `_msgSender()`.
Every identity check downstream resolves to the crystal. `callSystem` is deliberately sugar over
`executeCall(world, 0, data)` — it grants no extra authority, it just makes the intended usage
obvious at the call site.

### Authority is derived, never stored

```
MUD CrystalOwner → CrystalNFT.ownerOf → AtlantysmAccount.owner → who may execute
```

There is no access list and no second source of truth. Selling the crystal hands over its account in
the same transaction that moves the token, because both ends read the same table.
`testAuthorityFollowsTheNftWhenItIsSold` pins the whole chain: after a transfer the seller is locked
out and the buyer is in, with the crystal's identity unchanged underneath.

---

## 3. Decisions worth recording

**Where `CrystalNFT` gets the ERC-6551 inputs.** They cannot be constructor immutables: `configureForge`
needs the NFT's own address as its `tokenContract`, so the config necessarily comes into existence
*after* the NFT. The contract therefore caches them on the first mint. That is sound for a specific
reason rather than by luck — `configureForge` freezes the moment the first crystal is minted, so the
values read during that very mint are final. The alternative, reading `world.forgeConfig()` on every
mint, would pay a World hop plus three table slots forever to fetch a value that provably cannot move.

**Only `operation == 0` (CALL).** An account that can `delegatecall` can be made to rewrite its own
behaviour, which would break the one guarantee the identity model rests on. `execute` rejects
anything else.

**`state` is bumped before the call, not after.** Checks-effects-interactions: a re-entrant execution
must observe a counter that has already moved, so a signer that pinned `state` cannot have its intent
replayed inside its own call.

**`owner()` reverts for a foreign-chain token** rather than returning a misleading answer. The
`ownerOf` call would otherwise resolve against whatever contract happens to sit at the same address
on *this* chain — a different token entirely.

**Reverts bubble verbatim.** `_execute` re-raises the callee's revert data unchanged, so a System's
custom error survives the hop and stays decodable. Without it every failure a player saw would be an
opaque blob. `testSystemRevertsSurviveTheAccountHopDecodable` pins this.

---

## 4. The account is powerful but not privileged

An ERC-6551 account can call anything, which is the point of one and also a reasonable worry. It
confers no standing inside the game:

- the facade-only gates (`mintCrystal`, `transferCrystal`, `transferMana`) reject it like any other
  address — `testTheAccountCannotBypassTheFacadeOnlyGates` proves a crystal cannot mint itself
  siblings;
- namespace-owner operations are out of reach entirely;
- it holds no game state: mana lives in `ManaBalance` keyed by its address, not in its ETH balance.

---

## 5. What the integration test is for

`test/Integration.t.sol` has one rule: **it never pranks a token bound account.** The only addresses
pranked are the EOAs Alice and Bob. Verified mechanically — the only two matches for `vm.prank(account`
in the file are inside comments.

That rule is what makes it meaningful. Every other suite would still pass against a build where
accounts were never deployed; this one would not.

Mutation-checked: removing the auto-deploy (22 failures), the owner check (2), the `token()` code
offset (20) and the `state` bump (1) each fail the suite.

---

## 6. Open points

1. **Nothing funds the account with ETH.** Mana is keyed by address so it needs no custody, but an
   account with a zero ETH balance cannot pay for anything it might later want to buy on its own
   behalf. Today every transaction is paid for by the owner's EOA, which is fine — it is worth
   knowing it is a choice and not an accident.
2. **No transfer lock during a match.** `ArenaSystem` security note 6 becomes concrete now: selling a
   crystal mid-match hands the buyer the ability to reveal a move the seller committed. Escrowed
   wagers cannot be pulled back out, but the upside moves with the token.
3. **The account implementation is not upgradeable, by design.** Changing it changes the derived
   address for future crystals, which is exactly why `ForgeConfig` freezes. A bug in
   `AtlantysmAccount` could not be patched for already-minted crystals — only a new deployment would
   pick up a fix. This is the standard ERC-6551 trade-off and deserves an explicit decision before
   mainnet.
4. **Gas cost of minting rose.** Each mint now deploys a 173-byte proxy on top of the MUD writes.
   Unmeasured; worth benchmarking before setting a real mint price.
5. **`isValidSignature` is untested.** ERC-1271 support is implemented and compiles, but no test
   exercises a signature path — it is asserted by construction only.
