# Phase 8: Deployment Scripting

**Goal:** make `pnpm dev` produce a World a player can actually use.
**Status:** implemented. 135 tests total, 7 of them asserting the deployed state directly.

Closes phase 7 open point 1: the facades were never wired, so a fresh deploy produced a World in
which **minting was impossible** — phase 7 made the ERC-721 the only mint path, and nothing
registered one.

---

## 1. What the script does, and why the order is forced

```
1. resolve the ERC-6551 registry and account implementation
2. deploy CrystalNFT and ManaToken
3. configureForge(registry, implementation, address(nft), salt)
4. setTokenFacades(nft, manaToken)
5. setMintPrice(price)
```

Step 3 **must** follow step 2: the ERC-6551 `tokenContract` is the NFT itself, because accounts are
bound to the contract that owns the token ids. That address cannot exist before the NFT does. This
is also why the script does not use a placeholder there — identity is bound to the real facade.

Steps 4 and 5 could swap, but neither may precede 3: a mint before `ForgeConfig` is set reverts.

The deployer key from `.env` is the namespace owner, which is what all three admin calls require.

---

## 2. The production guard

`configureForge` **freezes on the first mint**, permanently, because the registry / implementation /
token-contract triple decides where every crystal's identity lives. Writing throwaway dev addresses
into it on a real network would bind every crystal ever minted to an implementation that does not
exist, with no migration path.

So:

| Chain | Behaviour |
| --- | --- |
| anvil (31337) | deploys `DevERC6551Registry` + `AtlantysmAccount` and uses them (phase 9 replaced the placeholder implementation with the real one) |
| anything else | **reverts** unless `ERC6551_REGISTRY` and `ERC6551_ACCOUNT_IMPLEMENTATION` are set |

Failing the deploy is the cheap outcome; discovering the mistake after the first mint is the
expensive one. `testDeployRefusesToInventIdentityInputsOffTheDevChain` pins this, and removing the
check makes it fail.

Optional environment variables: `MINT_PRICE` (default `0.01 ether`), `ERC6551_REGISTRY`,
`ERC6551_ACCOUNT_IMPLEMENTATION`.

---

## 3. Obstacle: a Foundry script cannot read MUD tables

The MUD template's `PostDeploy` says *"Specify a store so that you can use tables directly"*. On
current Foundry that is no longer true, and the failure is not obvious:

```
Usage of `address(this)` detected in script contract.
Script contracts are ephemeral and their addresses should not be relied upon.
```

Every generated table accessor contains `if (_storeAddress == address(this))` — the branch that
chooses between local storage and an external call — so **any** table read executes the `ADDRESS`
opcode in the script's frame, which Foundry rejects outright.

Resolved by removing `StoreSwitch.setStoreAddress` and all direct table access from the script, and
reading state through the World's own view functions instead. `CrystalForgeSystem.forgeConfig()` was
added for this: deployment tooling has to ask the World, not the table.

---

## 4. Re-running the script

`mud deploy` against an existing World runs `PostDeploy` again. It therefore:

- **skips identity setup** when the forge is already configured, and does **not** redeploy the
  facades with it. A fresh NFT would not match the frozen `tokenContract`, so every entity it minted
  would be derived against the wrong address.
- **re-applies the mint price** every time, since that is a tunable lever rather than an identity
  input.

---

## 5. A side effect worth knowing about

Two existing tests broke when this landed, and the reason is instructive: they asserted the guards
that protect the *unconfigured* state (`CrystalForge_NotConfigured`,
`CrystalForge_MintPriceNotConfigured`), and after phase 8 that state no longer occurs naturally —
`PostDeploy` configures everything. They now clear the relevant table as namespace owner first, so
the guard is still exercised rather than deleted.

More generally: **every test suite's baseline is now a fully wired World.** `test/PostDeploy.t.sol`
is deliberately the only file that configures nothing, which is what makes it able to catch a
regression in the script — every other suite would still pass against a `PostDeploy` that did
nothing at all.

---

## 6. Open points

1. ~~**Token bound accounts still cannot act.**~~ **Closed in phase 9.** The placeholder was replaced
   by `AtlantysmAccount`, a real ERC-6551 implementation that forwards owner-authorised calls to the
   World. `test/Integration.t.sol` plays the game without pranking a single account.
2. ~~**Nothing deploys the accounts either.**~~ **Closed in phase 9**, in exactly the place predicted:
   `CrystalNFT.mint` calls `registry.createAccount`, so forging and account creation are atomic.
3. **The mint price is a bare default.** `0.01 ether` on a dev chain is arbitrary and unconnected to
   `STARTER_MANA`, which phase 6 already flagged: those two numbers together set the mana issuance
   rate and are still not in a deliberate relationship.
4. **No production deployment has been exercised.** The guard is tested, but the environment-variable
   path (`ERC6551_REGISTRY` set) has only been reasoned about, not run against a real network.
5. **`DevERC6551Registry` ships in `src/`.** It is compiled into every build and deployed on dev
   chains only, but it is not gated by a build flag — nothing stops a future script from wiring it
   somewhere it does not belong.
