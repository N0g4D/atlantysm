# Deploying Atlantysm — Sepolia + Vercel

Contracts to Ethereum Sepolia, client to Vercel. Written for the hackathon build.

Everything below was verified against this repo's toolchain (Foundry 1.7.1, MUD 2.2.23, Vite 4.5,
Node 20) rather than recalled — where a step exists to avoid a specific failure, the failure is
named.

---

## 0. Before you start

**Node 20 is mandatory.** `pnpm` refuses anything else (`engines: node ^20`), and this machine
defaults to a newer version. Every command below assumes you have run:

```bash
export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"; nvm use 20
```

You also need Sepolia ETH on the deployer account — the World, four Systems, two token facades and
the account implementation are a lot of bytecode. **0.2–0.5 SepoliaETH** is a comfortable margin.

---

## 1. The one decision you cannot take back

`configureForge` **freezes on the first mint**, permanently. It stores the ERC-6551 registry, the
account implementation and the token contract, and every crystal's identity — its entity key, and
therefore its `CrystalData`, `ManaBalance` and match history — derives from those three addresses.

Get them wrong and there is no migration: the crystals exist at addresses nothing can ever call
from. This is why `PostDeploy` **reverts** on any chain other than anvil unless you supply the
identity inputs explicitly, instead of quietly inventing them.

So: deploy the account implementation *first*, as its own step, and paste the address in. That is
the whole reason step 3 exists.

---

## 2. Set up the environment file

```bash
cd packages/contracts
cp .env.example .env
```

Then edit `packages/contracts/.env`:

| Variable | Value |
| --- | --- |
| `PRIVATE_KEY` | Your funded Sepolia deployer. **Replace the anvil default.** |
| `ERC6551_REGISTRY` | `0x000000006551c19487814612e58FE06813775758` — already filled in |
| `ERC6551_ACCOUNT_IMPLEMENTATION` | Blank for now; step 3 fills it |
| `MINT_PRICE` | Optional, wei. Defaults to `0.01 ether` |

`.env` is gitignored, `.env.example` is not. Both the MUD CLI (`dotenv.config()`) and Foundry read
this file, so one copy serves `mud deploy` and `forge script` alike.

> **`packages/contracts/.env` used to be committed** — it shipped with the MUD template, carrying
> the anvil key and a comment reading *"Please do not commit changes to this file!"*. Since
> gitignore does not apply to already-tracked files, that comment was the only thing standing
> between a funded Sepolia key and a public repo. It is untracked as of this change, so a **fresh
> clone has no `.env` at all** and `cp .env.example .env` is now required for local development
> too, not just for Sepolia.

> **The registry address is not a guess.** It is the canonical ERC-6551 v0.3.1 registry, confirmed
> deployed on Sepolia, and its function selectors match `src/accounts/IERC6551.sol` exactly
> (`createAccount` `0x8a54c52f`, `account` `0x246a0021`). Use the canonical deployment and not a
> copy of your own: account addresses are CREATE2-derived *from the registry*, so a different
> registry means different addresses for the same crystals.

> **Never put `RPC_URL` in `.env`.** MUD resolves the endpoint as
> `FOUNDRY_ETH_RPC_URL || RPC_HTTP_URL || RPC_URL || <profile>.eth_rpc_url || 127.0.0.1:8545`,
> so `RPC_URL` outranks every profile — including no profile at all. Left in the file, it makes
> `pnpm deploy:local` deploy to **Sepolia** without warning you. Pass it inline instead, on the one
> command that needs it.

---

## 3. Deploy the account implementation

`AtlantysmAccount` is *our* ERC-6551 implementation, so unlike the registry there is no canonical
address — you deploy it once and reuse it.

```bash
cd packages/contracts

forge create src/accounts/AtlantysmAccount.sol:AtlantysmAccount \
  --rpc-url https://ethereum-sepolia-rpc.publicnode.com \
  --private-key $PRIVATE_KEY \
  --broadcast
```

`--broadcast` is required: since Foundry 1.0 `forge create` dry-runs without it and prints an
address that was never deployed. The contract takes no constructor arguments.

Copy the `Deployed to:` address into `.env`:

```
ERC6551_ACCOUNT_IMPLEMENTATION=0x...
```

---

## 4. Deploy the World

```bash
# from the repo root
pnpm --filter contracts deploy:sepolia
```

With your own RPC key (recommended — see step 7 on why):

```bash
RPC_URL="https://eth-sepolia.g.alchemy.com/v2/<KEY>" pnpm --filter contracts deploy:sepolia
```

This runs `mud deploy --profile=sepolia`, which deploys the World, registers namespace, tables and
Systems, then runs `PostDeploy`, which:

1. deploys `CrystalNFT` and `ManaToken`,
2. calls `configureForge(registry, implementation, address(nft), salt)` — **the freeze point**,
3. calls `setTokenFacades(nft, manaToken)`,
4. calls `setMintPrice(price)`.

Read the log. It prints the registry, implementation, `CrystalNFT` and `ManaToken` addresses —
save them, since the NFT address is what a wallet or explorer needs.

**If it reverts with `PostDeploy_MissingIdentityConfig`:** one of the two identity variables is
empty. That is the guard from step 1 doing its job, not a bug.

---

## 5. Commit the world address

`mud deploy` writes `packages/contracts/worlds.json`. On a non-local chain it records the deploy
block as well as the address:

```json
{
  "31337": { "address": "0x..." },
  "11155111": { "address": "0x...", "blockNumber": 1234567 }
}
```

```bash
git add packages/contracts/worlds.json && git commit -m "chore: sepolia world address"
```

**This commit is what points the client at the World** — the address is not a Vercel environment
variable, so a redeploy that moves it is a visible diff instead of a silent console change.

`blockNumber` matters just as much: the client replays `Store_*` logs from it, and without it the
sync would start at block 0 and crawl through the entire chain history. MUD omits it for local
chains only.

---

## 6. Refresh the committed ABIs — only if you changed Solidity

The client imports three ABIs from `packages/contracts/abi/`, which is **committed**, because
Foundry's `out/` is gitignored and would not exist on a Vercel checkout.

`pnpm --filter contracts build` regenerates them. If you changed a System's signature, commit the
result together with the Solidity:

```bash
pnpm --filter contracts build
git add packages/contracts/abi && git commit -m "chore: refresh client ABIs"
```

Skip this if you only deployed — a deploy does not change an ABI.

---

## 7. Deploy the client to Vercel

`vercel.json` at the repo root already carries the build configuration, so importing the repo is
usually enough. If Vercel asks, or the detected defaults differ:

| Setting | Value |
| --- | --- |
| Framework preset | Other |
| Root directory | *(repo root — leave empty)* |
| Install command | `pnpm install --frozen-lockfile` |
| Build command | `pnpm --filter client build` |
| Output directory | `packages/client/dist` |

Set these environment variables in **Project Settings → Environment Variables**:

| Variable | Value |
| --- | --- |
| `VITE_CHAIN_ID` | `11155111` |
| `VITE_SEPOLIA_RPC_HTTP` | `https://eth-sepolia.g.alchemy.com/v2/<KEY>` |

`VITE_CHAIN_ID` overrides the `31337` in the committed `packages/client/.env`: Vite applies real
environment variables *over* `.env` file contents.

**Get a dedicated RPC key.** This is the difference between a demo that loads and one that does
not. On every page load the client replays each `Store_*` log from the World's deploy block, which
is a burst of `eth_getLogs` — exactly what a shared public endpoint throttles. The baked-in default
(`ethereum-sepolia-rpc.publicnode.com`) works, but it is a fallback, not a plan.

Leave `VITE_SEPOLIA_RPC_WS` **unset** unless you have a socket endpoint you have actually tested.
viem's WebSocket transport throws when it cannot resolve a url, and viem's `fallback` does not
fail over to HTTP for that particular error, so a wrong value is a blank page rather than a slow
one.

---

## 8. Playing it

The client uses a **burner wallet** generated in the browser — there is no connect flow, and on
Sepolia there is no "top up" button either, unlike local anvil. A fresh visitor therefore lands
with zero ETH and cannot even mint.

**For a demo, hand out pre-funded links.** From the repo root:

```bash
cp .env.example .env          # then set MASTER_PRIVATE_KEY to your funded wallet
# edit VERCEL_DOMAIN at the top of scripts/generatePromoLinks.ts

pnpm promo:links --dry-run    # generate 50 links, spend nothing — check the domain is right
pnpm promo:links              # generate + fund: 50 × 0.02 ETH ≈ 1.0 ETH
```

`promo_links.txt` then holds 50 URLs of the form `https://<domain>/?burner=0x<key>`. Give one to
each visitor: they open it and are already holding 0.02 ETH — enough for the 0.01 mint plus gas for
the rest of the loop. The client adopts the key, then **strips it from the address bar**.

> **Each link is a bearer secret.** Whoever sees the URL owns that wallet. That is fine here —
> disposable, testnet, ~$0 — but `promo_links.txt` is gitignored and should be treated like a bag
> of cash. Do not paste the links into a shared channel.

To fund a single wallet by hand instead: open the site, copy the burner address from the navbar,
and send it Sepolia ETH from your own wallet.

Then: Forge → faucet → level up → arena.

> **Tell your demo audience not to clear site data.** Commit-reveal secrets live only in
> `localStorage`, per-browser and per-origin. Clearing it, or switching device mid-match, means the
> move can never be revealed: the match is lost by timeout with the wager already escrowed. This is
> the top open point at code freeze and it is unchanged by this deployment.

---

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `PostDeploy_MissingIdentityConfig(11155111)` | `ERC6551_REGISTRY` or `ERC6551_ACCOUNT_IMPLEMENTATION` empty in `.env`. See step 1. |
| `Missing PRIVATE_KEY environment variable` | `.env` not created, or you ran from outside `packages/contracts`. |
| `pnpm deploy:local` hits Sepolia | `RPC_URL` is set in `.env` or your shell. It outranks the profile. See step 2. |
| Vercel build: cannot resolve `contracts/abi/...` | `packages/contracts/abi/` was not committed. Run step 6. |
| Site blank, console `UrlRequiredError` | `VITE_SEPOLIA_RPC_WS` points at a dead endpoint. Unset it. |
| Site blank, no console error | Sync still running. Expected on first load — there is no loading state (known open point). |
| `No world address found for chain 11155111` | `worlds.json` was not committed after the deploy. See step 5. |
| Sync crawls, RPC 429s | Public RPC rate limit. Set `VITE_SEPOLIA_RPC_HTTP`. |
| `promo_links.txt already exists` | Refusing to strand keys that may hold ETH. Move it aside, or `--force`. |
| `RPC_URL is not Sepolia` | The endpoint reports another chain. The script refuses to send 1 ETH on it. |
| Promo link opens with the wrong wallet | The key was malformed and ignored; check the console for `[atlantysm]`. |
