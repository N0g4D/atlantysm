// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import { System } from "@latticexyz/world/src/System.sol";

import { ArenaLobby, ArenaLobbyData, CrystalData, ManaBalance, MatchCommitment, MatchCommitmentData } from "../codegen/index.sol";
import { Element, LobbyStatus } from "../codegen/common.sol";

/**
 * @title ArenaSystem
 * @notice Stateless wager-based combat between two crystals, settled with commit-reveal over an
 * elemental triangle. All match state lives in `ArenaLobby` and `MatchCommitment`; this contract
 * holds no storage of its own.
 *
 * Mana is settled exclusively against the `ManaBalance` table, which is the single source of truth
 * for the in-game currency. There is no ERC-20 to keep in sync: the ERC-20 interface is a facade to
 * be built on top of this table, so it must never be read from or written to here.
 *
 * Lifecycle:
 *   createLobby(salt, wager, commitment)   Open      challenger escrows and commits
 *   joinLobby(lobbyId, commitment)         Matched   opponent escrows and commits, clock starts
 *   revealMove(lobbyId, move, salt)        Matched   each side opens its commitment, before deadline
 *   resolveMatch(lobbyId)                  Resolved  both revealed: pay the winner, or refund a draw
 *   claimTimeout(lobbyId)                  Resolved  after deadline: the sole revealer takes the pot
 *                                          Cancelled after deadline: neither revealed, refund both
 *   cancelLobby(lobbyId)                   Cancelled challenger withdraws while still unmatched
 *
 * ---------------------------------------------------------------------------------------------
 * SECURITY NOTES
 * ---------------------------------------------------------------------------------------------
 *
 * 1. REENTRANCY. Every table write is an external call into the World, and MUD lets the namespace
 *    owner register store hooks that run inside that call. A hook on any table this System touches
 *    can therefore re-enter mid-function; that is the concrete vector here, not ETH transfers, of
 *    which there are none. Two mitigations, applied together:
 *      a. Strict checks-effects-interactions, with the extra rule that the lobby is moved to its
 *         TERMINAL status BEFORE any mana moves. A re-entrant call always observes the closed
 *         state and reverts on the status check.
 *      b. Every status transition is written with a WHOLE-RECORD `ArenaLobby.set`, never a
 *         sequence of per-field setters. A field-by-field transition would expose intermediate
 *         states — e.g. `opponent` already assigned while `status` is still `Open` — that an
 *         `onAfterSpliceStaticData` hook could exploit to double-join and strand a wager.
 *    Residual, and deliberately not defended against: an `onBefore*` hook runs BEFORE the write it
 *    guards, so it observes stale state by construction. No ordering can fix that; only a mutex
 *    could, and a System must stay storage-free. Installing any hook requires namespace-owner
 *    privileges, i.e. an actor that can already rewrite these tables directly, so this sits inside
 *    the trust boundary rather than outside it.
 *
 * 2. DIRECT CALLS BYPASSING THE WORLD. This System is namespaced, not root, so it can be called
 *    directly. That is not exploitable: `StoreSwitch` falls back to `msg.sender` as the store
 *    address, so a direct caller's writes land in its own fake store and never touch the real
 *    World. Access decisions still use `_msgSender()`, never `msg.sender`, which the World appends
 *    to calldata as trusted context.
 *
 * 3. FRONT-RUNNING ON LOBBY CREATION. The lobby id is `keccak256(challenger, salt)`, so it is
 *    namespaced by the caller's own entity. An observer who sees a pending `createLobby` cannot
 *    squat the resulting id by front-running it with the same salt: their entity differs, so their
 *    lobby lands on a different id.
 *
 * 4. HIDDEN MOVES, AND WHY THE TIMEOUT IS PART OF THE SECURITY MODEL. Moves are committed before
 *    the match starts and opened only afterwards, so no participant can compute the outcome before
 *    deciding to join — which is what makes joining a fair bet. Nothing block-derived is read at
 *    any point: no `blockhash`, no `prevrandao`, no timestamp in the damage formula. The one attack
 *    this opens is the losing player simply refusing to reveal, to strand the pot. `claimTimeout`
 *    removes the incentive: once the window closes, the player who DID reveal takes everything, so
 *    withholding a reveal never beats revealing. Reveals are hard-closed at the deadline and
 *    `claimTimeout` only opens after it, so the two can never race in the same block.
 *
 * 5. COMMITMENT SCOPE. The commitment is `keccak256(abi.encodePacked(move, salt))`, as specified.
 *    It is bound to neither the lobby nor the player, so the same commitment can be replayed across
 *    matches: an observer who learns a (move, salt) pair from one revealed match can recognise it
 *    if it is reused. Clients MUST draw a fresh random salt per match. Binding the hash to
 *    `(lobbyId, playerEntity, move, salt)` would enforce that in the contract instead of relying on
 *    client discipline. Note also that a move has only three values, so a low-entropy salt is
 *    brute-forceable in milliseconds — the salt is what hides the move, not the hash.
 *
 * 6. TOKEN BOUND ACCOUNTS AND NFT TRANSFERS. An entity is the crystal's ERC-6551 account, whose
 *    controller is whoever owns the ERC-721 at that moment. Staked mana is escrowed the instant a
 *    lobby is created or joined, so selling the crystal mid-match cannot pull a wager back out. It
 *    does move the upside: the pot is credited to the entity, so the buyer of a winning crystal
 *    collects it, and a seller front-run by a sale before settlement loses that pot. If crystals
 *    become tradeable while matched, the lifecycle needs a transfer lock.
 *
 * 7. `createdAt` AND `matchedAt` ARE uint32. They store seconds and overflow in 2106. Deadline
 *    arithmetic is widened to uint256 so it cannot wrap before then.
 */
contract ArenaSystem is System {
  /// @dev How long a matched lobby stays open for reveals. After this, only `claimTimeout` applies.
  uint256 internal constant REVEAL_WINDOW = 1 hours;

  /// @dev Level multiplier applied to the side whose element beats the other's.
  uint256 internal constant ADVANTAGE_MULTIPLIER = 2;

  /// @notice Emitted on settlement. `winner` is bytes32(0) when the match ended in a draw.
  event MatchResolved(bytes32 indexed lobbyId, bytes32 indexed winner, uint128 pot);

  error ArenaSystem_UnknownCrystal(bytes32 entity);
  error ArenaSystem_ZeroWager();
  error ArenaSystem_EmptyCommitment();
  error ArenaSystem_InsufficientMana(bytes32 entity, uint128 balance, uint128 required);
  error ArenaSystem_LobbyAlreadyExists(bytes32 lobbyId);
  error ArenaSystem_LobbyNotOpen(bytes32 lobbyId);
  error ArenaSystem_LobbyNotMatched(bytes32 lobbyId);
  error ArenaSystem_SelfMatch(bytes32 entity);
  error ArenaSystem_NotChallenger(bytes32 lobbyId, bytes32 entity);
  error ArenaSystem_NotAParticipant(bytes32 lobbyId, bytes32 entity);
  error ArenaSystem_InvalidMove();
  error ArenaSystem_AlreadyRevealed(bytes32 lobbyId, bytes32 entity);
  error ArenaSystem_CommitmentMismatch(bytes32 lobbyId, bytes32 entity);
  error ArenaSystem_RevealWindowClosed(bytes32 lobbyId);
  error ArenaSystem_RevealWindowOpen(bytes32 lobbyId);
  error ArenaSystem_RevealPending(bytes32 lobbyId);
  error ArenaSystem_BothRevealed(bytes32 lobbyId);
  error ArenaSystem_PotOverflow(bytes32 entity);

  // -----------------------------------------------------------------------------------------
  // Commit phase
  // -----------------------------------------------------------------------------------------

  /**
   * @notice Open a lobby, escrow the challenger's wager and record its hidden move.
   * @param lobbySalt Caller-chosen value that makes the lobby id unique per challenger. Unrelated
   * to the commitment salt. Reusing it reverts, including for terminal lobbies, which are kept as
   * history rather than deleted.
   * @param wager Mana staked by the challenger, matched by the opponent on join.
   * @param commitment keccak256(abi.encodePacked(move, salt)), see security note 5.
   */
  function createLobby(bytes32 lobbySalt, uint128 wager, bytes32 commitment) public returns (bytes32 lobbyId) {
    if (wager == 0) revert ArenaSystem_ZeroWager();
    if (commitment == bytes32(0)) revert ArenaSystem_EmptyCommitment();

    bytes32 challenger = _entityOf(_msgSender());
    _requireCrystal(challenger);

    lobbyId = keccak256(abi.encode(challenger, lobbySalt));
    if (ArenaLobby.getStatus(lobbyId) != LobbyStatus.None) revert ArenaSystem_LobbyAlreadyExists(lobbyId);

    uint128 balance = ManaBalance.getAmount(challenger);
    if (balance < wager) revert ArenaSystem_InsufficientMana(challenger, balance, wager);

    ArenaLobby.set(
      lobbyId,
      ArenaLobbyData({
        challenger: challenger,
        opponent: bytes32(0),
        winner: bytes32(0),
        wager: wager,
        createdAt: uint32(block.timestamp),
        matchedAt: 0,
        status: LobbyStatus.Open
      })
    );
    MatchCommitment.set(lobbyId, challenger, commitment, Element.None, false);
    ManaBalance.setAmount(challenger, balance - wager);
  }

  /**
   * @notice Match an open lobby, escrow an equal wager and record the opponent's hidden move.
   * The reveal clock starts here, not at creation: a lobby may sit open indefinitely.
   */
  function joinLobby(bytes32 lobbyId, bytes32 commitment) public {
    if (commitment == bytes32(0)) revert ArenaSystem_EmptyCommitment();

    ArenaLobbyData memory lobby = ArenaLobby.get(lobbyId);
    if (lobby.status != LobbyStatus.Open) revert ArenaSystem_LobbyNotOpen(lobbyId);

    bytes32 opponent = _entityOf(_msgSender());
    _requireCrystal(opponent);
    if (opponent == lobby.challenger) revert ArenaSystem_SelfMatch(opponent);

    uint128 balance = ManaBalance.getAmount(opponent);
    if (balance < lobby.wager) revert ArenaSystem_InsufficientMana(opponent, balance, lobby.wager);

    // Single whole-record write: `opponent`, `matchedAt` and `status` flip atomically, so no hook
    // can observe an assigned opponent while the lobby still reads as `Open` (security note 1b).
    lobby.opponent = opponent;
    lobby.matchedAt = uint32(block.timestamp);
    lobby.status = LobbyStatus.Matched;
    ArenaLobby.set(lobbyId, lobby);

    MatchCommitment.set(lobbyId, opponent, commitment, Element.None, false);
    ManaBalance.setAmount(opponent, balance - lobby.wager);
  }

  // -----------------------------------------------------------------------------------------
  // Reveal phase
  // -----------------------------------------------------------------------------------------

  /**
   * @notice Open your commitment. Allowed only while the reveal window is open; past the deadline
   * the match can only be settled through `claimTimeout`, so a reveal and a claim can never race.
   */
  function revealMove(bytes32 lobbyId, Element move, bytes32 salt) public {
    ArenaLobbyData memory lobby = ArenaLobby.get(lobbyId);
    if (lobby.status != LobbyStatus.Matched) revert ArenaSystem_LobbyNotMatched(lobbyId);
    // Validator timestamp drift is seconds against a one-hour window, and the deadline gates a
    // deliberate user action rather than a payout formula, so the skew is not worth defending.
    // forge-lint: disable-next-line(block-timestamp)
    if (block.timestamp > _revealDeadline(lobby)) revert ArenaSystem_RevealWindowClosed(lobbyId);
    if (move == Element.None) revert ArenaSystem_InvalidMove();

    bytes32 player = _entityOf(_msgSender());
    if (player != lobby.challenger && player != lobby.opponent) {
      revert ArenaSystem_NotAParticipant(lobbyId, player);
    }

    MatchCommitmentData memory entry = MatchCommitment.get(lobbyId, player);
    if (entry.revealed) revert ArenaSystem_AlreadyRevealed(lobbyId, player);
    if (keccak256(abi.encodePacked(move, salt)) != entry.commitment) {
      revert ArenaSystem_CommitmentMismatch(lobbyId, player);
    }

    MatchCommitment.set(lobbyId, player, entry.commitment, move, true);
  }

  // -----------------------------------------------------------------------------------------
  // Settlement
  // -----------------------------------------------------------------------------------------

  /**
   * @notice Settle a fully revealed match. Permissionless: with both moves already on-chain the
   * outcome is fixed, so ordering this transaction gains nothing and any keeper can drive it.
   * Callable after the deadline too, as long as both sides revealed in time.
   * @return winner The winning entity, or bytes32(0) if the match was a draw.
   */
  function resolveMatch(bytes32 lobbyId) public returns (bytes32 winner) {
    ArenaLobbyData memory lobby = ArenaLobby.get(lobbyId);
    if (lobby.status != LobbyStatus.Matched) revert ArenaSystem_LobbyNotMatched(lobbyId);

    MatchCommitmentData memory challengerEntry = MatchCommitment.get(lobbyId, lobby.challenger);
    MatchCommitmentData memory opponentEntry = MatchCommitment.get(lobbyId, lobby.opponent);
    if (!challengerEntry.revealed || !opponentEntry.revealed) revert ArenaSystem_RevealPending(lobbyId);

    winner = _winnerOf(lobby, challengerEntry.move, opponentEntry.move);
    _settle(lobbyId, lobby, winner);
  }

  /**
   * @notice Settle a match whose reveal window has closed with at least one move still hidden.
   * The player who revealed takes the whole pot; if neither did, both wagers are refunded and the
   * lobby ends `Cancelled` rather than `Resolved`, because no combat ever took place.
   */
  function claimTimeout(bytes32 lobbyId) public returns (bytes32 winner) {
    ArenaLobbyData memory lobby = ArenaLobby.get(lobbyId);
    if (lobby.status != LobbyStatus.Matched) revert ArenaSystem_LobbyNotMatched(lobbyId);
    // Exact complement of the check in `revealMove`, so a reveal and a claim can never both be
    // valid in the same block. See the note there on validator drift.
    // forge-lint: disable-next-line(block-timestamp)
    if (block.timestamp <= _revealDeadline(lobby)) revert ArenaSystem_RevealWindowOpen(lobbyId);

    bool challengerRevealed = MatchCommitment.getRevealed(lobbyId, lobby.challenger);
    bool opponentRevealed = MatchCommitment.getRevealed(lobbyId, lobby.opponent);
    if (challengerRevealed && opponentRevealed) revert ArenaSystem_BothRevealed(lobbyId);

    if (challengerRevealed) {
      winner = lobby.challenger;
    } else if (opponentRevealed) {
      winner = lobby.opponent;
    }

    if (winner == bytes32(0)) {
      // Nobody showed up. Terminal status first, then the refunds (security note 1a).
      lobby.status = LobbyStatus.Cancelled;
      ArenaLobby.set(lobbyId, lobby);

      _credit(lobby.challenger, lobby.wager);
      _credit(lobby.opponent, lobby.wager);

      emit MatchResolved(lobbyId, bytes32(0), 0);
    } else {
      _settle(lobbyId, lobby, winner);
    }
  }

  /// @notice Withdraw an unmatched lobby and refund the escrowed wager to the challenger.
  function cancelLobby(bytes32 lobbyId) public {
    ArenaLobbyData memory lobby = ArenaLobby.get(lobbyId);
    if (lobby.status != LobbyStatus.Open) revert ArenaSystem_LobbyNotOpen(lobbyId);

    bytes32 caller = _entityOf(_msgSender());
    if (caller != lobby.challenger) revert ArenaSystem_NotChallenger(lobbyId, caller);

    lobby.status = LobbyStatus.Cancelled;
    ArenaLobby.set(lobbyId, lobby);

    _credit(lobby.challenger, lobby.wager);
  }

  // -----------------------------------------------------------------------------------------
  // Internals
  // -----------------------------------------------------------------------------------------

  /**
   * @dev Writes the terminal record, then pays out. A draw (`winner == 0`) refunds each side its
   * own wager instead of moving a pot, so settlement stays zero-sum either way.
   */
  function _settle(bytes32 lobbyId, ArenaLobbyData memory lobby, bytes32 winner) internal {
    lobby.winner = winner;
    lobby.status = LobbyStatus.Resolved;
    ArenaLobby.set(lobbyId, lobby);

    if (winner == bytes32(0)) {
      _credit(lobby.challenger, lobby.wager);
      _credit(lobby.opponent, lobby.wager);
      emit MatchResolved(lobbyId, bytes32(0), 0);
    } else {
      uint256 pot = uint256(lobby.wager) * 2;
      _credit(winner, pot);
      // Bounded by the overflow check inside `_credit`: pot <= type(uint128).max.
      // forge-lint: disable-next-line(unsafe-typecast)
      emit MatchResolved(lobbyId, winner, uint128(pot));
    }
  }

  /**
   * @dev Damage is `level * ADVANTAGE_MULTIPLIER` for the side whose element beats the other's, and
   * `level` otherwise. Higher damage wins; equal damage — same element, or an advantage exactly
   * cancelled by a level gap — is a draw, reported as bytes32(0).
   */
  function _winnerOf(
    ArenaLobbyData memory lobby,
    Element challengerMove,
    Element opponentMove
  ) internal view returns (bytes32) {
    uint256 challengerDamage = _damage(lobby.challenger, challengerMove, opponentMove);
    uint256 opponentDamage = _damage(lobby.opponent, opponentMove, challengerMove);

    if (challengerDamage == opponentDamage) return bytes32(0);
    return challengerDamage > opponentDamage ? lobby.challenger : lobby.opponent;
  }

  function _damage(bytes32 entity, Element own, Element other) internal view returns (uint256) {
    uint256 level = CrystalData.getLevel(entity);
    return _beats(own, other) ? level * ADVANTAGE_MULTIPLIER : level;
  }

  /// @dev Strict cycle: Water > Fire > Earth > Water. Every element beats exactly one other.
  function _beats(Element own, Element other) internal pure returns (bool) {
    return
      (own == Element.Water && other == Element.Fire) ||
      (own == Element.Fire && other == Element.Earth) ||
      (own == Element.Earth && other == Element.Water);
  }

  /// @dev Widened to uint256 so the deadline cannot wrap when uint32 seconds overflow in 2106.
  function _revealDeadline(ArenaLobbyData memory lobby) internal pure returns (uint256) {
    return uint256(lobby.matchedAt) + REVEAL_WINDOW;
  }

  function _credit(bytes32 entity, uint256 amount) internal {
    uint256 credited = uint256(ManaBalance.getAmount(entity)) + amount;
    if (credited > type(uint128).max) revert ArenaSystem_PotOverflow(entity);
    // Bounded by the check above.
    // forge-lint: disable-next-line(unsafe-typecast)
    ManaBalance.setAmount(entity, uint128(credited));
  }

  /// @dev An entity is its ERC-6551 account address widened to the ECS key type.
  function _entityOf(address account) internal pure returns (bytes32) {
    return bytes32(uint256(uint160(account)));
  }

  /**
   * @dev Existence check. MUD returns a zero-filled record for keys that were never written, so
   * `level == 0` means "no such crystal". This relies on the invariant that minting starts crystals
   * at level 1 — whichever System eventually mints them must uphold it.
   */
  function _requireCrystal(bytes32 entity) internal view {
    if (CrystalData.getLevel(entity) == 0) revert ArenaSystem_UnknownCrystal(entity);
  }
}
