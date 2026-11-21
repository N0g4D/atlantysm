# Atlantysm

Atlantysm Season 0 is a confidential on-chain game on Zama's FHEVM, running on Sepolia. Every crystal is an
ERC-721 token whose element, level and MANA only its owner can read; a duel publishes only who won. The game is
specified in `docs/RULES.md`.

The MUD MVP that came before lives in `packages/contracts` and `packages/client`. It is frozen: do not build on it,
and change it only to keep CI green.

## Read before changing anything

- `docs/RULES.md` — the game. Its invariants (§3) do not change without Alessio.
- `docs/SEASON0.md` — the binding technical design: the encrypted logic, the rules every change follows, and the
  toolchain.
- `docs/TASKS.md` — the backlog. Work comes from there, in order.

## FHEVM knowledge

`.claude/settings.json` adds Zama's plugin marketplace and enables its `zama-protocol` plugin, which carries three
skills. Load them before any FHE work: `zama-protocol` first, then `zama-solidity` for contracts or
`zama-typescript` for the client. If they are missing, install the plugin by hand:

```
/plugin marketplace add zama-ai/skills
/plugin install zama-protocol@zama-skills
```

The skills point at the maintained sources. Check every FHE call against the installed `@fhevm/solidity` `FHE.sol`
and every client call against the installed `@zama-fhe/sdk` type declarations. The APIs move between releases,
and memory is not a source.

## Commands

Node 24, pnpm 9, Foundry 1.7.1. The `app` scripts appear with T10.

```bash
pnpm install
pnpm --filter garden build
pnpm --filter garden test
pnpm --filter app dev
pnpm --filter app build
```

## How to work

- **One task, one branch, one pull request.** Never commit to `main`. CI must be green, and the pull request ticks
  its task in `docs/TASKS.md`.
- **Contract tasks start with a plan.** Before writing Solidity, write down the functions touched, the encrypted
  operations, and which rules of `RULES.md` and of `SEASON0.md` §2.3 apply. Then implement.
- **Tests come with the code.** A rule without a test is not done, and that includes the privacy rules: who must
  not be able to decrypt what.
- **Review before the pull request.** For contract changes, have a subagent that did not write the code review the
  diff against `RULES.md` §3 and `SEASON0.md` §2.3, and fix what it finds.
- **Report HCU.** A change to encrypted logic reports the HCU of every function it touched and updates
  `SEASON0.md` §2.6.
- **Stop and ask** when a task would change a rule, an invariant or the deployed API (`SEASON0.md` §2.4), or when a
  gate fails.
- **Never deploy, broadcast or handle a private key.** Deploys, Vercel settings and funding wallets belong to
  Alessio. `.env` files are never committed.
- **Languages.** UI copy is Italian. Code, comments, docs, commits and pull requests are English. Commits follow
  `feat:` / `fix:` / `docs:` / `chore:` / `ci:`.
- **Comments say why.** Keep the reasoning next to the code, and correct a comment when the code under it changes.
