# Season 0 backlog

> **Deadline:** the Zama Developer Program, Mainnet Season 5 (Confidential Gaming), closes on
> **14 December 2026 at 23:59 AoE**. The submission needs the contract and the frontend, clear documentation, a
> 3-minute video pitch by a real person, an X post, and a deployment on Sepolia.
>
> The game: [`RULES.md`](RULES.md). The design: [`SEASON0.md`](SEASON0.md). How to work: [`CLAUDE.md`](../CLAUDE.md).

Take the first unchecked task whose milestone has started. One task, one branch, one pull request, and the pull
request ticks its task here.

## Before starting (Alessio)

- [ ] Merge #1 (CI and the local deploy fix), #3 (the rules), then this pull request.
- [ ] Open the repository in Claude Code and accept Zama's plugin marketplace when asked (see `CLAUDE.md`).
- [ ] Put at least 0.2 Sepolia ETH on the deployer wallet.

## M0 — Foundations (by Sunday 22 November)

- [x] **T01 · Node 24 and `packages/garden`.** First move the workspace to Node 24: `.nvmrc` and the root `engines`
  still say 20, and CI and Vercel follow them. The MUD MVP must keep building and passing its tests on Node 24; if
  it cannot, stop and report. Then scaffold `packages/garden`: Foundry with `@fhevm/forge`, set up as its README
  describes, and a smoke test that encrypts an input, computes on it and decrypts the result. The root `build` and
  `test` scripts run every package, so the existing CI job covers the new one.
  *Done when* `pnpm --filter garden test` passes locally and in CI, and the MVP's checks stay green.
- [ ] **T02 · Duel spike (gate).** A throwaway contract under `packages/garden/test/spike/` that implements *Join*
  and *Publish* from `SEASON0.md` §2.2 for two crystals with given elements and levels. Test all nine element
  pairs, mirrors with a higher, lower and equal level, the three forfeit cases, and a forged and a replayed proof.
  Measure the HCU of joining.
  *Done when* the tests pass and the pull request reports the HCU. If joining exceeds half of either cap, stop
  and report before T03.

## M1 — The Garden contract (by Sunday 29 November)

- [ ] **T03 · Crystals.** ERC-721, `forge`, `shatter` and MANA accrual.
  *Done when* the tests cover `RULES.md` §4–5, ETH conservation, a stranger failing to decrypt, and the spread of
  elements over 300 forges.
- [ ] **T04 · The Sanctuary.** `attune` with the encrypted *rise* or *hold*, costs, the maximum level, and spent MANA
  flowing into the season's pot.
  *Done when* the tests cover `RULES.md` §6, including that a rise, a refused rise and a hold look the same from
  outside.
- [ ] **T05 · Lobbies and duels.** `openLobby` with the stake bounds, `cancelLobby`, `joinLobby` and `publish`, built
  from the spike, with locks and lifetime records.
  *Done when* the tests cover `RULES.md` §7 and the adversarial cases in `SEASON0.md` §5.
- [ ] **T06 · Seasons.** The season index from deployment, wins and losses per season, the top three with
  tie-breaks, the close delay, `closeSeason` with encrypted shares, and the rollover.
  *Done when* the tests cover `RULES.md` §8.
- [ ] **T07 · Transfers.** The lock check, and sealing the crystal again for its new owner.
  *Done when* a test shows that the previous owner cannot decrypt the new level and MANA.
- [ ] **T08 · Hardening.** Check the rules in `SEASON0.md` §2.3 one by one in the pull request, check the contract
  size, fill in the HCU table in §2.6, and have a subagent that has not seen the contract being written review it
  against the invariants in `RULES.md` §3.
  *Done when* every finding is fixed or recorded with a reason.
- [ ] **T09 · Sepolia.** The deployment script, verification on Etherscan, and a scripted full round on Sepolia:
  two crystals, an attunement, a lobby, a duel, its publication and a season closed. Use a deployment with a short
  season for the round. Record the addresses and transaction hashes in `docs/season0-deployment.md`. Alessio
  deploys, or gives the go-ahead.

## M2 — The app (by Sunday 6 December)

- [ ] **T10 · Scaffold `packages/app`.** From the `react-wagmi` example of `@zama-fhe/react-sdk` at the installed
  version, on Sepolia, with the Garden ABI taken from the build.
- [ ] **T11 · Visual identity.** Before any page is built: a direction derived from the banner (the white garden, the
  monolith, the small white tables) and the three elements. Palette, type, how a crystal and the Monolith look, on
  desktop and mobile, shown on the Monolith home view with Italian copy.
  *Done when* Alessio approves the direction. Every page after follows it.
- [ ] **T12 · La Forgia.** Forging, the list of my crystals, and shattering. Decrypting my crystal on a click.
- [ ] **T13 · Santuario.** Attuning with *rise* or *hold*, the pending states, and the values refreshed afterwards.
- [ ] **T14 · L'Arena.** Open lobbies; opening, cancelling and joining; my duels; publishing pending results; the
  results feed.
- [ ] **T15 · Classifica and the Monolith.** The season ranking, its countdown, past seasons, and the close button
  when a season is due. The home view filled with the state of the world.
- [ ] **T16 · Vercel.** Configuration for `packages/app`, the COOP and COEP headers checked against the wallets, and
  the Garden address from the environment. Alessio points the Vercel project at the app.

## M3 — Keeper, documentation, playtest (by Thursday 10 December)

- [ ] **T17 · Keeper.** A Node script using `@zama-fhe/sdk/node` that publishes pending duels and closes seasons
  that are due. Run by hand or on a schedule.
- [ ] **T18 · Documentation for the judges.** A Season 0 section in the README: what is secret and why the game
  needs FHE (`RULES.md` §10), how to play, the verified contract addresses, and how to run the tests. Add an
  outline for the 3-minute video.
- [ ] **T19 · Playtest.** At least three real players on Sepolia for a whole season. Issues fixed or recorded.

## Submission (Alessio, 11–14 December)

- [ ] Record the 3-minute video. It must show a real person: AI-generated video or voice is not accepted.
- [ ] Publish the X post introducing the project.
- [ ] Submit the form before 14 December at 23:59 AoE.

## After Season 0

See `SEASON0.md` §7: the staking Monolith, crossing to a successor contract, the ranking fix, an audit and a legal
review.
