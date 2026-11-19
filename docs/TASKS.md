# Atlantysm — backlog

The single list of what stands between the code-freeze MVP and a finished game. Phase reports under
`docs/tasks/` record what was built and why; this file records what is left, in the order it should
happen.

**How to use it.** One item is one branch and one pull request. The PR that closes an item ticks
it here and adds the PR number. A decision that changes the plan goes in the log at the bottom, with
its date, in the same PR that acts on it.

Legend: `[ ]` to do · `[~]` in review · `[x]` merged · **(owner)** needs the deployer key, Vercel or
funds, so it cannot be done from a pull request.

---

## Where things stand — 2026-11-19

- **Built:** the full loop of phases 1–13 — forge, faucet, ascension, arena, settlement — with 147
  contract tests, and a React client that plays it end to end on a local chain.
- **Deployed:** World `0x99b50Db22170c336998cc6D552Ea353B3f800207` on Sepolia since 2026-08-25
  (block 11564183); client on Vercel.
- **Never played live.** On this date the World holds 0 ETH and has received no transaction since
  the deploy. Every mint leaves its price in the World, so no crystal has been forged on Sepolia:
  the loop has been exercised locally only.
- **Looks broken to a first visitor.** The client shows an empty state — `Prezzo: non configurato`,
  forge disabled — until it has replayed every block since the deploy. See M1.
- **Quiet since August.** No CI, no issues, no tags before this backlog.

---

## M0 — A base that can be trusted

- [~] **Local deploy works with the documented `.env`.** `.env.example` pre-fills the canonical
  ERC-6551 registry, which is empty on anvil; `PostDeploy` trusted it and every mint reverted
  (16 of 147 tests failed on a fresh clone). — PR #1
- [~] **CI on every push and PR**: frozen install, the documented `.env`, build, drift check on
  committed ABIs and codegen, tests. — PR #1
- [~] **This backlog, `CLAUDE.md` and a `LICENSE` file.** — PR #2

## M1 — A live demo that works for a stranger

The acceptance test is a person who has never seen the project opening the link, and two of them
finishing a match.

- [ ] **Show the sync, and gate the UI on it.** `syncToRecs` withholds every component update until
  the initial sync reaches the chain head (`skipUpdateStream` until `SyncStep.LIVE`), so panels
  render empty and say nothing. Read `components.SyncProgress`, show progress, and do not offer
  actions before `live`.
- [ ] **Tell "unknown" from "not configured".** `useMintPrice` returns `undefined` both while
  syncing and when the price really is unset, and the forge prints `non configurato` for both.
- [ ] **Bound the replay.** The client replays every `Store_*` log from the deploy block, 1,000
  blocks per request. Sepolia adds about 7,200 blocks a day: roughly 620 sequential requests today
  and seven more each day, against a rate-limited public endpoint. `fetchLogs` retries a throttled
  request three times and then gives up, which leaves the page empty for good. Options, to be
  decided:
  1. a MUD indexer (`indexerUrl`) — MUD's chain configs carry one for Garnet, Pyrope and Redstone,
     none for Sepolia;
  2. a snapshot of the Store logs shipped with the client (`initialBlockLogs`) and refreshed by a
     scheduled job, which keeps the "no backend" property;
  3. redeploying resets the start block, but only postpones the problem.
- [ ] **A failure state.** `setup()` is awaited before React mounts and nothing catches a throw:
  a dead RPC is a blank page. Add an error boundary and a readable message.
- [ ] **Fix the funding hint on Sepolia.** With zero ETH the forge says to use "top up" in the MUD
  Dev Tools, which are only mounted in development builds. In production say how to fund the
  burner instead.
- [ ] **Dedicated RPC on Vercel** — `VITE_SEPOLIA_RPC_HTTP`. Check the provider's `eth_getLogs`
  block-range limit first: some free tiers cap a request at a handful of blocks, which would make
  the replay far worse, not better. **(owner)**
- [ ] **Play one full match on Sepolia** with two funded wallets — mint, faucet, level up, create,
  join, reveal, resolve — and record the transaction hashes here. **(owner, with support)**

## M2 — The open points ratified at code freeze

- [ ] **Commit secrets that survive a cleared browser.** Derive the salt from the wallet key and
  the public match data instead of drawing it at random; `localStorage` becomes a cache. A lost
  move is then recoverable too: with the salt known there are only three candidates to hash
  against the on-chain commitment.
- [ ] **Client tests** (vitest). First target is `lib/commit.ts`: the two encodings are the part
  that fails silently, so pin them against vectors produced by the contract itself.
- [ ] **Loading and error boundary** — delivered by M1.

## M3 — Rules and contracts

The Sepolia World holds no player state, so until someone mints, even a table schema change costs
a fresh World and nothing else. Once players hold crystals a fresh World would erase them, and new
fields have to arrive as new tables.

- [ ] **Combat rule. — decision pending.** Today damage is `level`, doubled with the elemental
  advantage, and the challenger's level is public: a crystal at twice the level can never lose, and
  the joiner is the one who picks the match. Candidates:
  - *the advantage wins ties* — fixes 2 v 1, leaves 3 v 1 a certain win;
  - *×3 with that tie-break* — moves the certain win to "more than three times the level";
  - *the element always decides, level breaks same-element ties* — no gap is ever a certain win,
    nothing changes between close levels, and it is what the Arena panel already tells players.
    **Recommended.**
- [ ] **Optional level cap on a lobby**, set by the challenger. Even without certain wins the
  higher level keeps a 2-in-3 edge, and only the joiner chooses. Needs a new field on a fresh
  World, or a new table on a live one.
- [ ] **Transfer lock during a match** — `ArenaSystem` note 6, phase 9 open point 2.
- [ ] **`tokenURI`** projecting `CrystalData` — phase 7 open point 2.
- [ ] **ERC-1271 tests** for `isValidSignature` — phase 9 open point 5.
- [ ] **Invariant tests** on the derived counters `CrystalBalance` and `ManaSupply` — phase 7 open
  point 4.
- [ ] **Gas benchmark of a mint** — phase 9 open point 4.

## M4 — Visual redesign

- [ ] **Art direction first**: two or three directions for the main screen as mockups, chosen
  before any client code changes.
- [ ] **Design system**, then the screens: forge, sanctuary, arena, the crystal itself, element
  iconography, the sync / empty / error states from M1, and a phone layout.
- [ ] **Confirm the rights to `docs/assets/banner.jpg`**, or replace it with original art. The
  redesign should not be built on an image the project may not own.

## M5 — A real launch (only if wanted)

- [ ] Real wallets instead of a burner key in `localStorage`.
- [ ] Economy calibration: `MintPrice`, `STARTER_MANA` and the level ladder are still placeholders
  with no stated relationship — phase 6 open points 1, 3 and 4.
- [ ] Namespace owner on a multisig; it can replace the facades, and the NFT facade is the mint
  authorisation.
- [ ] External review of the contracts.
- [ ] Target chain, and with it the indexer question from M1.

## M6 — V2

- [ ] Crysm integration — see the roadmap in the README.

## Maintenance

- [ ] Node 20 reached end of life in April 2026 and the workspace still pins it (`engines`,
  `.nvmrc`, Vercel). Plan the move together with pnpm and Vite.
- [ ] `agent/skills/` and `.agents/skills/` carry two diverging copies of the same Tavily skills.
- [ ] `lib/commit.ts` points at `b.txt`, a phase report that is gitignored; `usePrimaryCrystal` is
  unused since the crystal selector landed.

---

## Decision log

- **2026-11-19** — Development resumes from this backlog, in milestone order. The combat rule and
  the art direction are the two decisions still open.
