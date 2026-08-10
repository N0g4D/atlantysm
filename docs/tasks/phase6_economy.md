# Phase 6: Economy, Sybil Protection & Balancing

**Goal:** stop the free crystal printer (and through it, the free mana printer), and replace the
linear level ladder with a quadratic one.
**Status:** implemented. 104 tests total, 29 on the forge and 23 on progression.

Closes phase 5 open points 1 (free faucet behind a free mint) and 2 (linear cost against linear
damage).

---

## 1. The finding that shaped this phase: ETH never reaches a System

This is the single most important thing in this document, because it invalidates the obvious
implementation of `withdrawETH()`.

In `SystemCall.sol`, MUD does this on every call carrying value:

```solidity
if (value > 0) {
  ...
  Balances._set(namespaceId, currentBalance + value);   // credited INSIDE the World
}
...
WorldContextProviderLib.callWithContext({ ..., msgValue: value, ... })
```

and `callWithContext` performs:

```solidity
target.call{ value: 0 }(appendContext(callData, msgSender, msgValue))
```

So:

| | Where it lives |
| --- | --- |
| The ETH itself | the **World** contract |
| The accounting | `Balances[namespaceId]`, a World table |
| `msg.value` inside the System | **always 0** |
| The real paid amount | `_msgValue()`, read from appended calldata context |

**Consequences, all binding on future work:**

1. A payment check must read **`_msgValue()`**. Reading `msg.value` would compare against 0 and
   accept every payment.
2. The System function must be declared **`payable`** even though it receives nothing. Worldgen
   mirrors mutability onto `IWorld.app__mintCrystal`; without `payable` there, the World rejects the
   transaction before any System code runs. (Verified in the generated
   `ICrystalForgeSystem.sol`: `function app__mintCrystal(address to) external payable ...`.)
3. **`withdrawETH()` was not implemented, and should not be.** A System-side withdrawal over
   `address(this).balance` would compile, run, revert nothing and transfer exactly zero. MUD already
   ships the correct mechanism:

   ```solidity
   IWorld.transferBalanceToAddress(namespaceId, to, amount)
   ```

   It is gated on `AccessControl._requireAccess(fromNamespaceId, _msgSender())`, checks the balance,
   and is written checks-effects-interactions. Duplicating it behind a project-level wrapper would
   add a second privileged path that can drain the namespace balance, for no capability gain.
   `CrystalForgeSystem.mintRevenue()` exposes the collectable amount so the figure is still readable
   from the project's own surface; tests cover admin withdrawal, non-admin rejection and
   over-withdrawal.

---

## 2. The mint gate

`mintCrystal` is now `payable` and requires `_msgValue() == MintPrice.price`, **exactly**.

- **Underpayment reverts.** Obvious.
- **Overpayment reverts too** — no change is returned. Refunding would mean sending ETH back
  mid-mint, which is a reentrancy surface bought for nothing: the price is readable via `mintPrice()`
  before the call.
- **An unset price blocks minting entirely.** `MintPrice` carries an explicit `configured` flag
  rather than treating `0` as free. A never-written MUD record reads back as zero, so without the
  sentinel a deployment that simply forgot to price the forge would mint for free and look perfectly
  healthy. A genuinely free mint stays expressible as `configured = true, price = 0`.
- **The price does not freeze**, unlike `ForgeConfig`. That asymmetry is deliberate: identity
  derivation is permanent and must never move, whereas a price is an economic lever.

Sybil resistance is now *priced*, not forbidden: N crystals still yield N starter grants, but they
cost N × `MintPrice`. Setting that price is what sets the mana issuance rate.

---

## 3. The quadratic ladder

```
cost(level) = 50 ether × level²
```

Damage in `ArenaSystem` scales **linearly** with level. Under the old linear cost, power was exactly
proportional to spend — no diminishing return, so an old crystal accumulated an unbounded permanent
edge (phase 5 open point 2). Squaring the cost while damage stays linear makes each additional point
of power cost strictly more than the last.

| Level | Cost of next |
| --- | --- |
| 1 | 50 |
| 2 | 200 |
| 3 | 450 |
| 4 | 800 |
| 5 | 1 250 |

### Does the uint128 ceiling now bind? No — MAX_LEVEL stays 255

The concern was that a quadratic curve might make high levels unpayable within a `uint128`
`ManaBalance`. Checked, with the numbers:

| | Value |
| --- | --- |
| Dearest single step (254 → 255) | `50e18 × 254²` = **3.2258e24** wei |
| Full climb, level 1 → 255 | `50e18 × 5 494 655` = **2.7473e26** wei |
| `uint128` ceiling | **3.4028e38** wei |

A crystal only ever has to hold **one step at a time**, and the dearest step leaves roughly 10¹⁴×
headroom. So the whole `uint8` range stays physically reachable and **`MAX_LEVEL` did not need to
change**. `testTheQuadraticCurveNeverOutgrowsTheUint128Ceiling` proves it by actually paying the
254 → 255 step.

`_levelUpCost` computes in `uint256` and bound-checks before narrowing to `uint128`. That check is
provably unreachable at the current constants; it is kept because it stops being unreachable the
moment `BASE` grows or the level type widens — at which point a silent truncation would quietly make
high levels **cheap** rather than expensive.

---

## 4. Open points

1. **The economy is still uncalibrated.** `MintPrice` (ETH in) and `STARTER_MANA` (mana out) together
   set the issuance rate, and nothing ties them to each other or to the level ladder. The numbers
   here are placeholders that now *exist*, not numbers that have been reasoned about.
2. **No decay and no de-levelling.** Progression is still monotonic. Quadratic cost slows a runaway
   crystal but does not reverse one, so a sufficiently invested crystal keeps its edge forever.
3. **Mint revenue has no destination policy.** It accrues to the namespace balance and an admin can
   withdraw it, but nothing routes it back into the game (prize pools, buy-backs, burns). Right now
   the ETH leaves the system entirely.
4. **The faucet is still one grant per crystal, not per human.** That is now *priced* rather than
   free, which is the intended fix, but it is not identity-based sybil resistance — it is a cost
   floor. If the mana value of a grant ever exceeds the mint price, farming becomes profitable again.
   These two numbers must be kept in a deliberate relationship.
