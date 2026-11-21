# Atlantysm — Rules

> Status: **draft for review**, Season 0. Agreed in principle with Alessio on 20 November 2026.
> Every value marked *(parameter)* can still move without changing the game.

## 1. The world

Atlantysm is the Ethereum of the alchemists. At the centre of a garden stands the **Monolith**, a crystal of
Ethereum. Every crystal forged around it leaves its charge inside the Monolith, and the Monolith radiates
energy, **MANA**, back to every crystal in equal shares. Alchemists spend that energy to make their crystals
stronger in the **Sanctuary** and wager it against one another in the **Arena**. The garden keeps the score;
what each crystal really is stays a secret between the crystal and its owner.

Two laws hold the world together:

- **Energy is not created from nothing.** All MANA is what the Monolith radiates. On mainnet that is the staking
  yield of the charges it holds; in Season 0 it is simulated at a fixed rate.
- **Energy is not destroyed.** MANA spent in the Sanctuary returns to the centre, where it becomes the season's
  prize.

## 2. Who it is for

People who keep their ETH on-chain because they believe in this version of Ethereum. Atlantysm is not a yield
product: the yield is the fuel that gives ETH a role in the world, not the promise. The game has to be worth
playing for small prizes. The value that matters is in the crystals themselves.

## 3. Invariants

These hold in every season and every implementation. A change that breaks one is a change to the game, not a
bug fix.

1. **The charge is never at stake.** Only MANA moves in the Arena. Shattering a crystal always returns its charge
   to its owner.
2. **Every crystal is born equal**: the same charge, level 1, and an element drawn by chance.
3. **Hidden by default.** A crystal's element, level and MANA can be read by its owner only. A duel publishes who
   won and who lost, and nothing else.
4. **Nobody can read or alter the secrets, the builders included.** The contract that holds them has no admin
   functions and cannot be upgraded; a fix means a new deployment. The decryption keys belong to Zama's threshold
   network, so no single party can decrypt.
5. **Energy is conserved.** MANA comes only from the Monolith. Spending it sends it to the centre, the centre
   pays it out only as the season's prize, and the Arena only moves it between crystals.
6. **Every outcome is verifiable.** Randomness is generated on-chain, and every published result carries a
   decryption proof that the contract checks.

## 4. Crystals

**Forging.** Anyone can forge a crystal by paying the charge: **0.01 ETH** *(parameter)*, the same for everyone.
Whoever wants more weight in the world forges more crystals. The charge is held by the Monolith and recorded
against the crystal.

At birth, encrypted on-chain randomness gives the crystal its **element**: Fire, Water or Earth, one chance in
three each. Nobody chooses it, not even the forger. The crystal starts at **level 1** with **0 MANA**. Element,
level and MANA are encrypted from the first block, and only the owner can read them.

**The element never changes.** It is the crystal's nature and its move in the Arena.

**Shattering.** The owner can shatter a crystal that is not waiting in an open lobby. The crystal is burned and its
charge is returned to the owner; in Season 0 its unspent MANA returns to the centre. Because shattering always
returns the charge, a crystal is never worth less than its charge. On any market the charge is the floor, and
everything above it is the price of the crystal's level, element and record.

**Ownership.** Crystals are transferable tokens (ERC-721), and their secrets travel with them. On a transfer the
level and MANA are sealed again for the new owner, so previous owners lose sight of them. The element cannot be
sealed again in the same way: it never changes, so everyone who has ever owned the crystal keeps knowing it. A
crystal waiting in an open lobby cannot be transferred or shattered.

**Record.** Every crystal's wins and losses are public and permanent.

## 5. MANA

Every crystal receives the same flow of MANA from the Monolith: **100 MANA per day** in Season 0 *(parameter)*,
accrued continuously and credited whenever the crystal acts. On mainnet the flow is the staking yield of all the
charges, divided equally among crystals.

A crystal's balance is encrypted. Anyone can work out how much MANA a crystal has received, because the flow is
public and so are its stakes and results. Nobody else can tell how much it has spent or has left.

## 6. The Sanctuary: levels

**Attunement.** The owner attunes a crystal with an encrypted choice, *rise* or *hold*. If the choice is *rise*
and the crystal holds enough MANA, it pays the cost and rises one level. Otherwise nothing changes. From outside,
every attunement looks the same: a rise, a rise refused for lack of MANA and a deliberate *hold* cannot be told
apart.

**Cost.** Rising from level L to L + 1 costs **50 × L² MANA** *(parameter)*. The maximum level is **10**
*(parameter)*.

**Where the MANA goes.** Spent MANA flows to the centre and becomes the season's prize. Individual contributions
stay encrypted, and so does the total (§8).

**What others can know.** From a crystal's public income and record, anyone can work out the highest level it
could have reached. Never the level it has.

## 7. The Arena: duels

**The triangle.** Water beats Fire, Fire beats Earth, Earth beats Water.

**The move is the crystal.** A player chooses which crystal to bring, and that crystal's element is the move.
There is no other choice to make inside a duel.

**Mirrors.** When both crystals share an element, the higher level wins. When element and level are both equal,
an encrypted coin decides. Every duel has exactly one winner and one loser.

**Lobbies.** A player opens a lobby with one crystal and a public **stake** in MANA, from **10** to **100**
*(parameters)*: at least a tenth of a day's MANA, so that a stake is never symbolic, and at most a day's, so that no
lobby asks for more than a day of MANA can cover. Anyone can join it with one crystal of their own. A crystal can
wait in one open lobby at a time. The creator can cancel a lobby that nobody has joined after **24 hours**
*(parameter)*.

**Stakes and forfeits.** The creator puts up the stake when opening the lobby, the challenger when joining, both
from their encrypted balances. A crystal that cannot cover the stake loses by forfeit, and nobody can tell a
forfeit from a defeat. If neither crystal can cover it, the duel is decided as usual and no MANA moves.

**Resolution.** The duel is fought the moment the challenger joins. The outcome is computed on encrypted data and
the stakes move at once, still encrypted: the winner takes the pot, which is both stakes, or only its own back if
the loser forfeited. Then only the winner is decrypted and published, with a proof that the contract verifies.
Anyone can submit the published result, so no player can stall it by staying away.

**What a duel reveals.** The two crystals, the stake and the winner. Each player also knows their own crystal's
element and level, so every duel tells them something about the opponent. Deducing who is who, and hiding it, is
the game.

## 8. Seasons and the centre

A season lasts **four weeks** *(parameter)*. A new season resets the ranking only: crystals keep their level,
MANA and record.

**Ranking.** Crystals are ranked by Arena wins in the season. Ties go to whoever reached the score first, counting
duels in the order they were fought. A duel counts for the season in which it was fought, once its result is
published. A season can
be closed **1 hour** after it ends *(parameter)*; results published later count only in the crystals' records.

**The prize.** When a season is closed, the centre is credited to the top three crystals in encrypted shares:
**50%, 30% and 20%** *(parameter)*. Its total is never published, and each winner sees only its own share. With
few players, a published total would reveal what individual crystals had spent. A share with no crystal to take
it, because fewer than three were ranked or one has been shattered, stays in the centre for the season in
progress.

**Known weakness.** A player with several crystals can duel themselves to inflate their wins, and no on-chain
ranking can rule that out entirely. That is acceptable in Season 0, where nothing has monetary value, and must be
resolved before mainnet. Options on the table: count each pair of crystals once per season; or return the centre
in equal shares to every crystal that fought during the season.

## 9. What is public, what is secret

| Data | Who can read it |
|---|---|
| A crystal's element | Its owner, and everyone who has ever owned it |
| Its level | Its owner |
| Its MANA balance | Its owner |
| What an attunement did | Its owner; others see only that one happened |
| The charge | Everyone (it is the same for every crystal) |
| Lobbies and stakes | Everyone |
| Who won a duel | Everyone |
| A crystal's record | Everyone |
| The centre's total | Nobody; each of the top three sees its own share |

## 10. Why the game needs encryption

On a transparent chain every element and level would be visible. Nobody would accept a duel they could see they
would lose, so the only duels left would be the ones decided in advance. Strong crystals would hunt weak ones,
and every crystal's price would be a formula. With the state encrypted, a duel is a contest of deduction and
nerve, and a crystal's price includes what the market believes it is.

## 11. Season 0 and after

**Season 0** is the testnet period on Sepolia, up to the submission to the Zama Developer Program, Mainnet
Season 5 (Confidential Gaming), which closes on 14 December 2026. It runs the full loop: forging, MANA, the
Sanctuary, the Arena and the seasonal ranking, with simulated MANA and charges in Sepolia ETH. Its seasons last
**3 days** *(parameter)*, so that a full cycle can be seen.

**Before mainnet:**

- The Monolith stakes the charges, and MANA becomes the real yield.
- The ranking weakness in §8 is resolved.
- A rule for unspent MANA when a crystal is shattered (likely paid out with the charge).
- A security audit, and a legal review before any real money is involved.

**A possible dark path.** Putting the charge itself at stake breaks invariant 1. If it ever comes, it comes as a
*corruption* of the magic: a deliberate, opt-in turn, never the default.

## 12. Season 0 parameters

| Parameter | Value |
|---|---|
| Charge | 0.01 Sepolia ETH |
| MANA flow | 100 MANA per crystal per day |
| Level cost | 50 × L² MANA, from level L to L + 1 |
| Maximum level | 10 |
| Stake | From 10 to 100 MANA |
| Lobby timeout | 24 hours |
| Season length | 3 days in Season 0, then 4 weeks |
| Season close delay | 1 hour after the season ends |
| Prize split | 50% / 30% / 20% |
