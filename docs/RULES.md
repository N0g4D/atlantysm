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
3. **Hidden by default.** The game lets only a crystal's owner read its level and MANA, and only those who own it or
   have owned it read its element (§4). A duel publishes who won and who lost, and nothing else.
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
level and MANA are encrypted from the first block, and only the owner can read them. A forger who wants another
element can shatter the crystal and forge a new one, paying only gas: the draw starts again, and the new crystal is
born like any other.

**The element never changes.** It is the crystal's nature and its move in the Arena.

**Shattering.** The owner can shatter a crystal that is not waiting in an open lobby. The crystal is burned and its
charge is returned to the owner; in Season 0 its unspent MANA returns to the centre. Because shattering always
returns the charge, a crystal is never worth less than its charge. On any market the charge is the floor, and
everything above it is the price of the crystal's level, element and record.

**Ownership.** Crystals are transferable tokens (ERC-721), and their secrets travel with them. On a transfer the
level and MANA are sealed again for the new owner, so previous owners can no longer read them. The element cannot
be sealed again in the same way: it never changes, so everyone who has ever owned the crystal keeps knowing it. A
crystal waiting in an open lobby cannot be transferred or shattered.

**What a transfer leaves behind.** A previous owner keeps what it read, and can prove it to anyone: the element for
good, and the level and MANA as they were at the transfer. Until the crystal attunes again, its level is still the
one the previous owner saw, and its balance what it saw plus the crystal's public income, give or take the stakes of
its duels and any prize it takes (§5, §8). So a seller can reveal a crystal's element to the whole Arena at any
time after the sale, and the buyer cannot undo it. No code can prevent this while the element never changes:
whoever buys a crystal accepts it.

An account that the owner approves to move a crystal, alone or with all its crystals as marketplaces ask, can read
it too. It can move the crystal to itself and back in one transaction, which leaves only two public transfers
behind, and from then on it counts as a previous owner. Approving an account already means trusting it with the
crystal, which it could simply take.

The new owner, for its part, reads the crystal as it is, and with its public record can sometimes work out what its
previous owners did with it: how its attunements went, whether its stakes moved, and what a prize it took was worth.

**Record.** Every crystal's wins and losses are public and permanent.

## 5. MANA

Every crystal receives the same flow of MANA from the Monolith: **100 MANA per day** in Season 0 *(parameter)*,
accrued continuously and credited whenever the crystal acts. On mainnet the flow is the staking yield of all the
charges, divided equally among crystals.

A crystal's balance is encrypted. From the public flow and the crystal's stakes and results, anyone can work out
the most MANA it can have received, but not whether each stake moved (§7). Once a crystal has attuned, nobody else
can tell how much it has spent or has left, beyond what a previous owner saw before a transfer (§4). One that has
never attuned has spent nothing in secret, so others can often work out its balance.

## 6. The Sanctuary: levels

**Attunement.** The owner attunes a crystal with an encrypted choice, *rise* or *hold*. If the choice is *rise*
and the crystal holds enough MANA, it pays the cost and rises one level. Otherwise nothing changes. From outside,
every attunement looks the same: a rise, a rise refused for lack of MANA and a deliberate *hold* cannot be told
apart.

**Cost.** Rising from level L to L + 1 costs **50 × L² MANA** *(parameter)*. The maximum level is **10**
*(parameter)*.

**Where the MANA goes.** Spent MANA flows to the centre and becomes the season's prize. Individual contributions
stay encrypted, and so does the total (§8). Nobody can read the total, but a player knows what it paid in itself.
So whoever first adds to a season's empty centre, by attuning or shattering, knows the total until anyone else
adds to it. The top three of a closed season also know, to within a few MANA, what its close carried over into the
centre of the season in progress (§8), and so that centre's total if it was empty, again until anyone else adds to
it. And since MANA is neither created nor lost, the owners of every live crystal could together work out what the
centre holds across all seasons.

**What others can know.** From a crystal's public income and record, anyone can work out the highest level it
could have reached. Attunements are public too, so a crystal stands at most one level above the number of times it
has attuned, and one that has never attuned is at level 1. A *hold* adds to that count without a rise, so the count
says no more. Nobody else ever learns the level it has, except a previous owner, until the crystal attunes again
(§4).

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

**Stakes.** Elements and levels decide every duel: MANA never wins one. The creator puts up the stake when opening
the lobby, and the challenger when joining, each from its encrypted balance if that covers the stake. The stake
moves only when both crystals have covered it, and then the winner takes both. Otherwise each crystal keeps its
own and no MANA moves. The duel itself shows nobody outside it which happened, because the outcome does not depend on
it. Public history can still settle it, when it settles whether each crystal could cover the stake: a crystal forged
too recently to have received the stake cannot, and one that has never attuned often has a balance others can work
out (§5). Each of the two players can always tell, from its own balance, and so, sometimes, can those who owned
either crystal before or own it later (§4).

**Resolution.** The duel is fought the moment the challenger joins. The outcome is computed on encrypted data, and
any stakes move at once, still encrypted. Then only the winner is decrypted and published, with a proof that the
contract verifies. Anyone can submit the published result, so no player can stall it by staying away.

**What a duel reveals.** The two crystals, the stake and the winner. Each player also knows its own crystal's
element and level, and sees from its own balance whether the stakes moved, so every duel tells it something about
the opponent. Deducing who is who, and hiding it, is the game.

## 8. Seasons and the centre

A season lasts **four weeks** *(parameter)*. A new season resets the ranking only: crystals keep their level,
MANA and record.

**Ranking.** Crystals are ranked by Arena wins in the season. Ties go to whoever reached the score first, counting
duels in the order they were fought. A duel counts for the season in which it was fought if its result is published
less than **1 hour** after the season ends *(parameter)*; a result published later counts only in the crystals'
records. The ranking is final at that hour, and from then on anyone can close the season: whoever closes it, the
same crystals take the same shares.

**The prize.** When a season is closed, the centre is credited to the top three crystals in encrypted shares:
**50%, 30% and 20%** *(parameter)*, each rounded down. Its total is never published: with few players, it would
reveal what individual crystals had spent. Each winner sees only its own share, and since the split is fixed, it can
work out the total from that share once the season is closed, to within a few MANA because of the rounding. Nobody
else can, unless it already knows the total from its own payments (§6), or later owns a winner and can tell its
share from the rest of its balance (§4); and whoever knows the total knows every share. A share with no crystal to
take it, because fewer than three were ranked or one was shattered before the close, stays in the centre for the
season in progress at the close, with what the rounding leaves.

**Known weaknesses.** A player with several crystals can duel themselves to inflate their wins, and no on-chain
ranking can rule that out entirely. A lobby's creator can also refuse any challenger: it sees the challenger's
transaction before it is mined and gets in first, joining its own lobby with another of its crystals, which earns it
a win as well, or cancelling the lobby once that is allowed. A second wallet gets around any check on addresses.
And a crystal that cannot cover the stake fights without risking MANA. A new one never can, and its element can be
drawn again for the price of gas (§4), so a player who has guessed a creator's element can forge until it draws the
one that beats it, then join for free: a win if it guessed right, nothing lost if not. The same freedom lets a new
player fight at once, without waiting for its crystal to fill. These weaknesses are acceptable in Season 0, where
nothing has monetary value, and must be resolved before mainnet. Options on the table: count each pair of crystals
once per season; return the centre in equal shares to every crystal that fought during the season; let challengers
join through private transactions, or in two steps, committing to a hidden crystal first; refuse a lobby or a join
to a crystal that has not yet received the stake.

## 9. What is public, what is secret

| Data | Who can read it |
|---|---|
| A crystal's element | Its owner, and everyone who has ever owned it, who can also prove it to anyone (§4) |
| Its level | Its owner. A previous owner keeps the one it saw, true until the crystal attunes again (§4) |
| Its MANA balance | Its owner. A previous owner keeps the one it saw at the transfer (§4) |
| What an attunement did | Its owner; others see only that one happened. A later owner can sometimes work out what earlier ones did (§4) |
| The charge | Everyone (it is the same for every crystal) |
| Lobbies and stakes | Everyone |
| Who won a duel | Everyone |
| Whether a duel's stakes moved | The two players, and sometimes the crystals' owners before or after them (§4); others only when public history settles whether each crystal could cover the stake (§7) |
| A crystal's record | Everyone |
| The centre's total | Nobody reads it. It can be worked out from one's own payments into it and, to within a few MANA, by a closed season's top three, and sometimes by their later owners (§4, §6, §8) |

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
| Season close delay | 1 hour after the season ends: from then on, results no longer count for it, and it can be closed |
| Prize split | 50% / 30% / 20% |
