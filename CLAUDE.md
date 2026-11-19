# Atlantysm

A fully on-chain game on MUD v2. Crystals are ERC-721 tokens whose ERC-6551 accounts are the
players: every System resolves the actor from `_msgSender()`, and that sender is the crystal's
account, never its owner. The React client is a view over the World and nothing more.

## Read before changing anything

- `docs/architecture.md` — the binding rules: identity model, facade direction, ETH versus mana,
  how MUD packs tables, and the coding guidelines for agents.
- `docs/TASKS.md` — the backlog. Work comes from there, and the PR that closes an item ticks it.
- `docs/tasks/phaseN_*.md` — what each phase built and the open points it left.
- `deploy_instructions.md` — Sepolia and Vercel, including the one setting that can never be undone.

## Commands

Node 20, pnpm 9, Foundry 1.7.1.

```bash
pnpm install
cp packages/contracts/.env.example packages/contracts/.env   # required, and safe locally
pnpm build        # MUD codegen, forge build, ABI export, client bundle
pnpm test         # deploys a World on anvil, runs forge test, typechecks the client
pnpm dev          # anvil + deploy/watch + client on :3000 + MUD explorer
```

## Rules

- **Never commit to `main`.** One backlog item, one branch, one pull request. CI must be green.
- **Generated files travel with their source.** After touching Solidity or `mud.config.ts`, run
  `pnpm --filter contracts build` and commit `abi/` and `src/codegen/` in the same commit. CI fails
  on drift.
- **A System change ships with its forge tests**, asserting state explicitly. For a new guard, show
  that removing it fails a test and say so in the PR.
- **Table schemas are immutable on a deployed World.** A new field is a new table unless the change
  comes with a fresh deploy.
- **Never deploy, broadcast, or handle a private key.** Deploys, Vercel settings and funding wallets
  belong to the repo owner. `.env` files are never committed; `packages/client/.env` is the one
  exception and holds only `VITE_CHAIN_ID`.
- **Languages.** UI copy is Italian. Code, comments, docs, commits and PRs are English. Commits
  follow `feat:` / `fix:` / `docs:` / `chore:` / `ci:`.
- **Comments say why.** This codebase documents the reasoning behind each decision, and the
  alternatives it rejected, next to the code. Keep that up, and correct a comment when the code
  under it changes.
