// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import { MudTest } from "@latticexyz/world/test/MudTest.t.sol";
import { StoreHook } from "@latticexyz/store/src/StoreHook.sol";
import { ResourceId } from "@latticexyz/store/src/ResourceId.sol";
import { EncodedLengths } from "@latticexyz/store/src/EncodedLengths.sol";
import { FieldLayout } from "@latticexyz/store/src/FieldLayout.sol";
import { AFTER_SET_RECORD, BEFORE_SPLICE_STATIC_DATA } from "@latticexyz/store/src/storeHookTypes.sol";

import { IWorld } from "../src/codegen/world/IWorld.sol";
import { IArenaSystem } from "../src/codegen/world/IArenaSystem.sol";
import { ArenaLobby, ArenaLobbyData, CrystalData, ManaBalance, MatchCommitment } from "../src/codegen/index.sol";
import { Element, LobbyStatus } from "../src/codegen/common.sol";

/**
 * @dev Malicious store hook, used to prove the reentrancy mitigations rather than assert them in a
 * comment. It is registered on a table the System writes to and fires inside the World, mid-call.
 *
 * Two hook types are implemented because the two mitigations need different probes:
 *  - `onBeforeSpliceStaticData` on `ManaBalance` fires while the winner is being paid, and probes
 *    the "terminal status before any mana moves" rule.
 *  - `onAfterSetRecord` on `ArenaLobby` fires the instant a status transition lands, and probes the
 *    "whole-record writes, no observable intermediate state" rule.
 */
contract ReentrantHook is StoreHook {
  uint8 public constant MODE_RESOLVE = 0;
  uint8 public constant MODE_CLAIM = 1;
  uint8 public constant MODE_JOIN = 2;

  IWorld private immutable world;

  uint8 private mode;
  bytes32 private lobbyId;
  bytes32 private commitment;

  bool public armed;
  bool public fired;
  bool public blocked;
  bool public reentered;

  constructor(IWorld _world) {
    world = _world;
  }

  function arm(uint8 _mode, bytes32 _lobbyId, bytes32 _commitment) external {
    mode = _mode;
    lobbyId = _lobbyId;
    commitment = _commitment;
    armed = true;
  }

  function onBeforeSpliceStaticData(ResourceId, bytes32[] memory, uint48, bytes memory) public override {
    _attack();
  }

  function onAfterSetRecord(
    ResourceId,
    bytes32[] memory,
    bytes memory,
    EncodedLengths,
    bytes memory,
    FieldLayout
  ) public override {
    _attack();
  }

  function _attack() internal {
    if (!armed) return;
    armed = false; // one shot, otherwise the callback recurses on its own writes
    fired = true;

    if (mode == MODE_RESOLVE) {
      try world.app__resolveMatch(lobbyId) {
        reentered = true;
      } catch {
        blocked = true;
      }
    } else if (mode == MODE_CLAIM) {
      try world.app__claimTimeout(lobbyId) {
        reentered = true;
      } catch {
        blocked = true;
      }
    } else {
      try world.app__joinLobby(lobbyId, commitment) {
        reentered = true;
      } catch {
        blocked = true;
      }
    }
  }
}

contract ArenaSystemTest is MudTest {
  address internal alice = address(0xA11CE);
  address internal bob = address(0xB0B);
  address internal dave = address(0xDA7E);
  address internal erin = address(0xE217);
  address internal stranger = address(0x57A2);

  bytes32 internal aliceEntity;
  bytes32 internal bobEntity;
  bytes32 internal daveEntity;
  bytes32 internal erinEntity;
  bytes32 internal strangerEntity;

  /// @dev Owner of the `app` namespace, needed to seed tables and register hooks.
  address internal deployer;

  uint128 internal constant FUNDING = 1_000 ether;
  uint128 internal constant WAGER = 100 ether;
  uint256 internal constant REVEAL_WINDOW = 1 hours;

  bytes32 internal constant LOBBY_SALT = keccak256("lobby-1");
  bytes32 internal constant C_SALT = keccak256("challenger-secret");
  bytes32 internal constant O_SALT = keccak256("opponent-secret");

  function setUp() public override {
    super.setUp();

    deployer = vm.addr(vm.envUint("PRIVATE_KEY"));

    aliceEntity = _entityOf(alice);
    bobEntity = _entityOf(bob);
    daveEntity = _entityOf(dave);
    erinEntity = _entityOf(erin);
    strangerEntity = _entityOf(stranger);

    // Levels chosen so the elemental triangle is testable in every direction:
    // dave ties alice, and bob's level-3 advantage (3*2=6) exactly cancels erin's level 6.
    _seedCrystal(alice, 1, 5, FUNDING);
    _seedCrystal(bob, 2, 3, FUNDING);
    _seedCrystal(dave, 3, 5, FUNDING);
    _seedCrystal(erin, 4, 6, FUNDING);
    // `stranger` owns no crystal at all.
  }

  // ---------------------------------------------------------------------------------------------
  // createLobby
  // ---------------------------------------------------------------------------------------------

  function testCreateLobbyEscrowsWagerAndHidesTheMove() public {
    bytes32 lobbyId = _open(alice, LOBBY_SALT, WAGER, Element.Fire, C_SALT);

    ArenaLobbyData memory lobby = ArenaLobby.get(lobbyId);
    assertEq(lobby.challenger, aliceEntity, "challenger");
    assertEq(lobby.opponent, bytes32(0), "opponent unset while open");
    assertEq(lobby.winner, bytes32(0), "winner unset before settlement");
    assertEq(lobby.wager, WAGER, "wager");
    assertEq(lobby.createdAt, uint32(block.timestamp), "createdAt");
    assertEq(lobby.matchedAt, 0, "reveal clock must not start before a match");
    assertEq(uint8(lobby.status), uint8(LobbyStatus.Open), "status");

    assertEq(MatchCommitment.getCommitment(lobbyId, aliceEntity), _commit(Element.Fire, C_SALT), "commitment");
    assertEq(uint8(MatchCommitment.getMove(lobbyId, aliceEntity)), uint8(Element.None), "move must stay hidden");
    assertFalse(MatchCommitment.getRevealed(lobbyId, aliceEntity), "revealed");

    assertEq(ManaBalance.getAmount(aliceEntity), FUNDING - WAGER, "wager must leave the challenger");
  }

  function testCreateLobbyRevertsForUnknownCrystal() public {
    vm.prank(stranger);
    vm.expectRevert(abi.encodeWithSelector(IArenaSystem.ArenaSystem_UnknownCrystal.selector, strangerEntity));
    IWorld(worldAddress).app__createLobby(LOBBY_SALT, WAGER, _commit(Element.Fire, C_SALT));
  }

  function testCreateLobbyRevertsOnZeroWager() public {
    vm.prank(alice);
    vm.expectRevert(IArenaSystem.ArenaSystem_ZeroWager.selector);
    IWorld(worldAddress).app__createLobby(LOBBY_SALT, 0, _commit(Element.Fire, C_SALT));
  }

  function testCreateLobbyRevertsOnEmptyCommitment() public {
    vm.prank(alice);
    vm.expectRevert(IArenaSystem.ArenaSystem_EmptyCommitment.selector);
    IWorld(worldAddress).app__createLobby(LOBBY_SALT, WAGER, bytes32(0));
  }

  function testCreateLobbyRevertsOnInsufficientMana() public {
    vm.prank(alice);
    vm.expectRevert(
      abi.encodeWithSelector(IArenaSystem.ArenaSystem_InsufficientMana.selector, aliceEntity, FUNDING, FUNDING + 1)
    );
    IWorld(worldAddress).app__createLobby(LOBBY_SALT, FUNDING + 1, _commit(Element.Fire, C_SALT));
  }

  function testCreateLobbyRevertsOnReusedSalt() public {
    bytes32 lobbyId = _open(alice, LOBBY_SALT, WAGER, Element.Fire, C_SALT);

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IArenaSystem.ArenaSystem_LobbyAlreadyExists.selector, lobbyId));
    IWorld(worldAddress).app__createLobby(LOBBY_SALT, WAGER, _commit(Element.Water, C_SALT));
  }

  /// @dev Security note 3: the id is namespaced by the challenger, so a front-runner reusing the
  /// same salt cannot collide with, or squat, someone else's pending lobby.
  function testLobbyIdIsNamespacedByChallenger() public {
    bytes32 aliceLobby = _open(alice, LOBBY_SALT, WAGER, Element.Fire, C_SALT);
    bytes32 bobLobby = _open(bob, LOBBY_SALT, WAGER, Element.Fire, C_SALT);

    assertTrue(aliceLobby != bobLobby, "same salt must not collide across challengers");
    assertEq(ArenaLobby.getChallenger(aliceLobby), aliceEntity);
    assertEq(ArenaLobby.getChallenger(bobLobby), bobEntity);
  }

  // ---------------------------------------------------------------------------------------------
  // joinLobby
  // ---------------------------------------------------------------------------------------------

  function testJoinLobbyStartsTheRevealClock() public {
    bytes32 lobbyId = _open(alice, LOBBY_SALT, WAGER, Element.Fire, C_SALT);

    vm.warp(block.timestamp + 3 days); // a lobby may sit open indefinitely
    _join(bob, lobbyId, Element.Water, O_SALT);

    ArenaLobbyData memory lobby = ArenaLobby.get(lobbyId);
    assertEq(lobby.opponent, bobEntity, "opponent");
    assertEq(uint8(lobby.status), uint8(LobbyStatus.Matched), "status");
    assertEq(lobby.matchedAt, uint32(block.timestamp), "clock starts at join, not at creation");
    assertTrue(lobby.matchedAt > lobby.createdAt, "matchedAt must be independent of createdAt");

    assertEq(MatchCommitment.getCommitment(lobbyId, bobEntity), _commit(Element.Water, O_SALT), "commitment");
    assertEq(ManaBalance.getAmount(bobEntity), FUNDING - WAGER, "wager must leave the opponent");
  }

  function testJoinLobbyRevertsOnSelfMatch() public {
    bytes32 lobbyId = _open(alice, LOBBY_SALT, WAGER, Element.Fire, C_SALT);

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IArenaSystem.ArenaSystem_SelfMatch.selector, aliceEntity));
    IWorld(worldAddress).app__joinLobby(lobbyId, _commit(Element.Water, O_SALT));
  }

  function testJoinLobbyRevertsForUnknownCrystal() public {
    bytes32 lobbyId = _open(alice, LOBBY_SALT, WAGER, Element.Fire, C_SALT);

    vm.prank(stranger);
    vm.expectRevert(abi.encodeWithSelector(IArenaSystem.ArenaSystem_UnknownCrystal.selector, strangerEntity));
    IWorld(worldAddress).app__joinLobby(lobbyId, _commit(Element.Water, O_SALT));
  }

  function testJoinLobbyRevertsOnEmptyCommitment() public {
    bytes32 lobbyId = _open(alice, LOBBY_SALT, WAGER, Element.Fire, C_SALT);

    vm.prank(bob);
    vm.expectRevert(IArenaSystem.ArenaSystem_EmptyCommitment.selector);
    IWorld(worldAddress).app__joinLobby(lobbyId, bytes32(0));
  }

  function testJoinLobbyRevertsWhenAlreadyMatched() public {
    bytes32 lobbyId = _open(alice, LOBBY_SALT, WAGER, Element.Fire, C_SALT);
    _join(bob, lobbyId, Element.Water, O_SALT);

    vm.prank(dave);
    vm.expectRevert(abi.encodeWithSelector(IArenaSystem.ArenaSystem_LobbyNotOpen.selector, lobbyId));
    IWorld(worldAddress).app__joinLobby(lobbyId, _commit(Element.Earth, O_SALT));
  }

  /// @dev A never-written lobby id reads back as `LobbyStatus.None`, which the sentinel keeps
  /// distinguishable from `Open`.
  function testJoinLobbyRevertsForNonExistentLobby() public {
    bytes32 ghost = keccak256("no such lobby");

    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(IArenaSystem.ArenaSystem_LobbyNotOpen.selector, ghost));
    IWorld(worldAddress).app__joinLobby(ghost, _commit(Element.Water, O_SALT));
  }

  // ---------------------------------------------------------------------------------------------
  // revealMove
  // ---------------------------------------------------------------------------------------------

  function testRevealMoveOpensTheCommitment() public {
    bytes32 lobbyId = _match(alice, Element.Fire, bob, Element.Water, LOBBY_SALT, WAGER);

    _reveal(alice, lobbyId, Element.Fire, C_SALT);

    assertEq(uint8(MatchCommitment.getMove(lobbyId, aliceEntity)), uint8(Element.Fire), "move");
    assertTrue(MatchCommitment.getRevealed(lobbyId, aliceEntity), "revealed");
    assertFalse(MatchCommitment.getRevealed(lobbyId, bobEntity), "the opponent must be unaffected");
  }

  function testRevealRevertsOnWrongSalt() public {
    bytes32 lobbyId = _match(alice, Element.Fire, bob, Element.Water, LOBBY_SALT, WAGER);

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IArenaSystem.ArenaSystem_CommitmentMismatch.selector, lobbyId, aliceEntity));
    IWorld(worldAddress).app__revealMove(lobbyId, Element.Fire, keccak256("wrong"));
  }

  /// @dev The whole point of the commitment: a player who sees the opponent's move cannot swap
  /// their own for a winning one.
  function testRevealRevertsWhenSwappingTheMove() public {
    bytes32 lobbyId = _match(alice, Element.Fire, bob, Element.Water, LOBBY_SALT, WAGER);
    _reveal(bob, lobbyId, Element.Water, O_SALT);

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IArenaSystem.ArenaSystem_CommitmentMismatch.selector, lobbyId, aliceEntity));
    IWorld(worldAddress).app__revealMove(lobbyId, Element.Earth, C_SALT); // Earth would beat Water
  }

  function testRevealRevertsForNonParticipant() public {
    bytes32 lobbyId = _match(alice, Element.Fire, bob, Element.Water, LOBBY_SALT, WAGER);

    vm.prank(dave);
    vm.expectRevert(abi.encodeWithSelector(IArenaSystem.ArenaSystem_NotAParticipant.selector, lobbyId, daveEntity));
    IWorld(worldAddress).app__revealMove(lobbyId, Element.Fire, C_SALT);
  }

  function testRevealRevertsOnDoubleReveal() public {
    bytes32 lobbyId = _match(alice, Element.Fire, bob, Element.Water, LOBBY_SALT, WAGER);
    _reveal(alice, lobbyId, Element.Fire, C_SALT);

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IArenaSystem.ArenaSystem_AlreadyRevealed.selector, lobbyId, aliceEntity));
    IWorld(worldAddress).app__revealMove(lobbyId, Element.Fire, C_SALT);
  }

  function testRevealRevertsOnSentinelMove() public {
    bytes32 lobbyId = _match(alice, Element.None, bob, Element.Water, LOBBY_SALT, WAGER);

    vm.prank(alice);
    vm.expectRevert(IArenaSystem.ArenaSystem_InvalidMove.selector);
    IWorld(worldAddress).app__revealMove(lobbyId, Element.None, C_SALT);
  }

  function testRevealRevertsAfterTheDeadline() public {
    bytes32 lobbyId = _match(alice, Element.Fire, bob, Element.Water, LOBBY_SALT, WAGER);

    vm.warp(block.timestamp + REVEAL_WINDOW + 1);

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IArenaSystem.ArenaSystem_RevealWindowClosed.selector, lobbyId));
    IWorld(worldAddress).app__revealMove(lobbyId, Element.Fire, C_SALT);
  }

  function testRevealRevertsBeforeAnyoneJoins() public {
    bytes32 lobbyId = _open(alice, LOBBY_SALT, WAGER, Element.Fire, C_SALT);

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IArenaSystem.ArenaSystem_LobbyNotMatched.selector, lobbyId));
    IWorld(worldAddress).app__revealMove(lobbyId, Element.Fire, C_SALT);
  }

  // ---------------------------------------------------------------------------------------------
  // resolveMatch and elemental combat
  // ---------------------------------------------------------------------------------------------

  function testResolveRevertsWhileARevealIsPending() public {
    bytes32 lobbyId = _match(alice, Element.Fire, bob, Element.Water, LOBBY_SALT, WAGER);
    _reveal(alice, lobbyId, Element.Fire, C_SALT);

    vm.expectRevert(abi.encodeWithSelector(IArenaSystem.ArenaSystem_RevealPending.selector, lobbyId));
    IWorld(worldAddress).app__resolveMatch(lobbyId);
  }

  /// @dev The core of the mechanic: level 3 with Water (3*2=6) beats level 5 with Fire (5).
  function testElementalAdvantageBeatsRawLevel() public {
    bytes32 lobbyId = _playOut(alice, Element.Fire, bob, Element.Water, LOBBY_SALT, WAGER);

    bytes32 winner = IWorld(worldAddress).app__resolveMatch(lobbyId);

    assertEq(winner, bobEntity, "Water must double bob's level and beat alice");
    assertEq(ArenaLobby.getWinner(lobbyId), bobEntity, "winner must be persisted on the lobby");
    assertEq(uint8(ArenaLobby.getStatus(lobbyId)), uint8(LobbyStatus.Resolved), "status");
    assertEq(ManaBalance.getAmount(bobEntity), FUNDING + WAGER, "winner takes the whole pot");
    assertEq(ManaBalance.getAmount(aliceEntity), FUNDING - WAGER, "loser forfeits the wager");
  }

  /// @dev Mirror case: with the advantage reversed, the same pair flips outcome.
  function testElementalAdvantageIsSymmetric() public {
    bytes32 lobbyId = _playOut(alice, Element.Water, bob, Element.Fire, LOBBY_SALT, WAGER);

    assertEq(IWorld(worldAddress).app__resolveMatch(lobbyId), aliceEntity, "10 vs 3");
  }

  /// @dev Without an advantage the raw level decides.
  function testHigherLevelWinsWhenElementsMatch() public {
    bytes32 lobbyId = _playOut(alice, Element.Fire, bob, Element.Fire, LOBBY_SALT, WAGER);

    assertEq(IWorld(worldAddress).app__resolveMatch(lobbyId), aliceEntity, "5 vs 3");
  }

  /// @dev The triangle must be a strict cycle, so Earth beats Water too.
  function testEarthBeatsWater() public {
    bytes32 lobbyId = _playOut(bob, Element.Earth, dave, Element.Water, LOBBY_SALT, WAGER);

    assertEq(IWorld(worldAddress).app__resolveMatch(lobbyId), bobEntity, "6 vs 5");
  }

  function testEqualLevelSameElementIsADraw() public {
    bytes32 lobbyId = _playOut(alice, Element.Fire, dave, Element.Fire, LOBBY_SALT, WAGER);

    bytes32 winner = IWorld(worldAddress).app__resolveMatch(lobbyId);

    assertEq(winner, bytes32(0), "5 vs 5 is a draw");
    assertEq(ArenaLobby.getWinner(lobbyId), bytes32(0), "no winner persisted");
    assertEq(uint8(ArenaLobby.getStatus(lobbyId)), uint8(LobbyStatus.Resolved), "a draw still resolves");
    assertEq(ManaBalance.getAmount(aliceEntity), FUNDING, "both wagers refunded");
    assertEq(ManaBalance.getAmount(daveEntity), FUNDING, "both wagers refunded");
  }

  /// @dev An advantage exactly cancelled by a level gap: bob level 3 with Earth (3*2=6) against
  /// erin level 6 with Water (6). The multiplier must not silently win ties.
  function testAdvantageCancelledByLevelGapIsADraw() public {
    bytes32 lobbyId = _playOut(bob, Element.Earth, erin, Element.Water, LOBBY_SALT, WAGER);

    assertEq(IWorld(worldAddress).app__resolveMatch(lobbyId), bytes32(0), "6 vs 6 is a draw");
    assertEq(ManaBalance.getAmount(bobEntity), FUNDING, "refunded");
    assertEq(ManaBalance.getAmount(erinEntity), FUNDING, "refunded");
  }

  function testResolveIsPermissionless() public {
    bytes32 lobbyId = _playOut(alice, Element.Water, bob, Element.Fire, LOBBY_SALT, WAGER);

    // Neither a participant nor a crystal owner: with both moves public there is nothing to gain
    // from ordering this call, so anyone may drive settlement.
    vm.prank(stranger);
    assertEq(IWorld(worldAddress).app__resolveMatch(lobbyId), aliceEntity);
  }

  function testResolveCannotBePaidTwice() public {
    bytes32 lobbyId = _playOut(alice, Element.Water, bob, Element.Fire, LOBBY_SALT, WAGER);
    IWorld(worldAddress).app__resolveMatch(lobbyId);

    vm.expectRevert(abi.encodeWithSelector(IArenaSystem.ArenaSystem_LobbyNotMatched.selector, lobbyId));
    IWorld(worldAddress).app__resolveMatch(lobbyId);
  }

  /**
   * @dev Security note 4: the outcome must not depend on when the settlement transaction lands.
   * Two identical matches are played out in the same block; one is settled immediately, the other
   * a year and a thousand blocks later.
   */
  function testResolveOutcomeIsIndependentOfBlockContext() public {
    bytes32 first = _playOut(alice, Element.Fire, bob, Element.Water, keccak256("a"), WAGER);
    bytes32 second = _playOut(alice, Element.Fire, bob, Element.Water, keccak256("b"), WAGER);

    bytes32 firstWinner = IWorld(worldAddress).app__resolveMatch(first);

    vm.warp(block.timestamp + 365 days);
    vm.roll(block.number + 1000);
    bytes32 secondWinner = IWorld(worldAddress).app__resolveMatch(second);

    assertEq(firstWinner, secondWinner, "settlement must not move with the block");
    assertEq(firstWinner, bobEntity);
  }

  // ---------------------------------------------------------------------------------------------
  // claimTimeout
  // ---------------------------------------------------------------------------------------------

  /**
   * @dev The incentive that makes commit-reveal safe: bob is about to lose and refuses to reveal,
   * hoping to strand the pot. Once the window closes, alice takes everything anyway.
   */
  function testWithholdingARevealForfeitsThePot() public {
    bytes32 lobbyId = _match(alice, Element.Water, bob, Element.Fire, LOBBY_SALT, WAGER);
    _reveal(alice, lobbyId, Element.Water, C_SALT);

    vm.warp(block.timestamp + REVEAL_WINDOW + 1);

    vm.prank(stranger);
    bytes32 winner = IWorld(worldAddress).app__claimTimeout(lobbyId);

    assertEq(winner, aliceEntity, "the sole revealer takes the pot");
    assertEq(ArenaLobby.getWinner(lobbyId), aliceEntity, "winner persisted");
    assertEq(uint8(ArenaLobby.getStatus(lobbyId)), uint8(LobbyStatus.Resolved), "status");
    assertEq(ManaBalance.getAmount(aliceEntity), FUNDING + WAGER, "pot");
    assertEq(ManaBalance.getAmount(bobEntity), FUNDING - WAGER, "forfeited");
  }

  /// @dev Symmetric: withholding does not become profitable just because the winner is the one
  /// who stayed silent.
  function testWinnerWhoStaysSilentStillLoses() public {
    // bob would win on damage (Water 6 vs Fire 5) but never reveals.
    bytes32 lobbyId = _match(alice, Element.Fire, bob, Element.Water, LOBBY_SALT, WAGER);
    _reveal(alice, lobbyId, Element.Fire, C_SALT);

    vm.warp(block.timestamp + REVEAL_WINDOW + 1);
    assertEq(IWorld(worldAddress).app__claimTimeout(lobbyId), aliceEntity, "silence forfeits the win");
  }

  function testClaimTimeoutRefundsBothWhenNobodyReveals() public {
    bytes32 lobbyId = _match(alice, Element.Fire, bob, Element.Water, LOBBY_SALT, WAGER);

    vm.warp(block.timestamp + REVEAL_WINDOW + 1);
    bytes32 winner = IWorld(worldAddress).app__claimTimeout(lobbyId);

    assertEq(winner, bytes32(0), "no winner");
    assertEq(uint8(ArenaLobby.getStatus(lobbyId)), uint8(LobbyStatus.Cancelled), "no combat took place");
    assertEq(ManaBalance.getAmount(aliceEntity), FUNDING, "refunded");
    assertEq(ManaBalance.getAmount(bobEntity), FUNDING, "refunded");
  }

  function testClaimTimeoutRevertsBeforeTheDeadline() public {
    bytes32 lobbyId = _match(alice, Element.Water, bob, Element.Fire, LOBBY_SALT, WAGER);
    _reveal(alice, lobbyId, Element.Water, C_SALT);

    vm.warp(ArenaLobby.getMatchedAt(lobbyId) + REVEAL_WINDOW); // exactly on the boundary
    vm.expectRevert(abi.encodeWithSelector(IArenaSystem.ArenaSystem_RevealWindowOpen.selector, lobbyId));
    IWorld(worldAddress).app__claimTimeout(lobbyId);
  }

  /// @dev A fully revealed match must go through `resolveMatch`, so the two entry points can never
  /// disagree about the outcome.
  function testClaimTimeoutRevertsWhenBothRevealed() public {
    bytes32 lobbyId = _playOut(alice, Element.Water, bob, Element.Fire, LOBBY_SALT, WAGER);

    vm.warp(block.timestamp + REVEAL_WINDOW + 1);
    vm.expectRevert(abi.encodeWithSelector(IArenaSystem.ArenaSystem_BothRevealed.selector, lobbyId));
    IWorld(worldAddress).app__claimTimeout(lobbyId);
  }

  /// @dev Revealing inside the window keeps the match settleable forever after.
  function testResolveStillWorksAfterTheDeadlineIfBothRevealed() public {
    bytes32 lobbyId = _playOut(alice, Element.Water, bob, Element.Fire, LOBBY_SALT, WAGER);

    vm.warp(block.timestamp + 30 days);
    assertEq(IWorld(worldAddress).app__resolveMatch(lobbyId), aliceEntity);
  }

  // ---------------------------------------------------------------------------------------------
  // cancelLobby
  // ---------------------------------------------------------------------------------------------

  function testCancelLobbyRefundsChallenger() public {
    bytes32 lobbyId = _open(alice, LOBBY_SALT, WAGER, Element.Fire, C_SALT);

    vm.prank(alice);
    IWorld(worldAddress).app__cancelLobby(lobbyId);

    assertEq(uint8(ArenaLobby.getStatus(lobbyId)), uint8(LobbyStatus.Cancelled), "status");
    assertEq(ManaBalance.getAmount(aliceEntity), FUNDING, "escrow returned in full");
  }

  function testCancelLobbyRevertsForNonChallenger() public {
    bytes32 lobbyId = _open(alice, LOBBY_SALT, WAGER, Element.Fire, C_SALT);

    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(IArenaSystem.ArenaSystem_NotChallenger.selector, lobbyId, bobEntity));
    IWorld(worldAddress).app__cancelLobby(lobbyId);
  }

  function testCancelLobbyRevertsOnceMatched() public {
    bytes32 lobbyId = _match(alice, Element.Fire, bob, Element.Water, LOBBY_SALT, WAGER);

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IArenaSystem.ArenaSystem_LobbyNotOpen.selector, lobbyId));
    IWorld(worldAddress).app__cancelLobby(lobbyId);
  }

  // ---------------------------------------------------------------------------------------------
  // Reentrancy
  // ---------------------------------------------------------------------------------------------

  /// @dev Security note 1a: the lobby reaches its terminal status before any mana moves, so a hook
  /// firing during the payout cannot collect twice.
  function testResolveMatchIsNotReentrant() public {
    bytes32 lobbyId = _playOut(alice, Element.Water, bob, Element.Fire, LOBBY_SALT, WAGER);

    ReentrantHook hook = _installHook(ManaBalance._tableId, BEFORE_SPLICE_STATIC_DATA);
    hook.arm(hook.MODE_RESOLVE(), lobbyId, bytes32(0));

    IWorld(worldAddress).app__resolveMatch(lobbyId);

    _assertBlocked(hook);
    assertEq(ManaBalance.getAmount(aliceEntity), FUNDING + WAGER, "pot must be paid exactly once");
  }

  /// @dev Same rule on the asynchronous path, which pays out from a different branch.
  function testClaimTimeoutIsNotReentrant() public {
    bytes32 lobbyId = _match(alice, Element.Water, bob, Element.Fire, LOBBY_SALT, WAGER);
    _reveal(alice, lobbyId, Element.Water, C_SALT);
    vm.warp(block.timestamp + REVEAL_WINDOW + 1);

    ReentrantHook hook = _installHook(ManaBalance._tableId, BEFORE_SPLICE_STATIC_DATA);
    hook.arm(hook.MODE_CLAIM(), lobbyId, bytes32(0));

    IWorld(worldAddress).app__claimTimeout(lobbyId);

    _assertBlocked(hook);
    assertEq(ManaBalance.getAmount(aliceEntity), FUNDING + WAGER, "pot must be paid exactly once");
  }

  /**
   * @dev Security note 1b: `joinLobby` flips `opponent`, `matchedAt` and `status` in one whole-record
   * write. A hook firing the instant that record lands must already see `Matched`, otherwise it
   * could join again, overwrite the opponent and strand the first opponent's wager.
   */
  function testJoinLobbyIsNotReentrant() public {
    bytes32 lobbyId = _open(alice, LOBBY_SALT, WAGER, Element.Fire, C_SALT);

    ReentrantHook hook = _installHook(ArenaLobby._tableId, AFTER_SET_RECORD);
    _seedCrystal(address(hook), 99, 9, FUNDING); // the attacker needs a crystal of its own
    hook.arm(hook.MODE_JOIN(), lobbyId, _commit(Element.Earth, O_SALT));

    _join(bob, lobbyId, Element.Water, O_SALT);

    _assertBlocked(hook);
    assertEq(ArenaLobby.getOpponent(lobbyId), bobEntity, "the real opponent must survive");
    assertEq(ManaBalance.getAmount(_entityOf(address(hook))), FUNDING, "the attacker must not be escrowed");
    assertEq(ManaBalance.getAmount(bobEntity), FUNDING - WAGER, "bob's wager is escrowed exactly once");
  }

  // ---------------------------------------------------------------------------------------------
  // Invariants
  // ---------------------------------------------------------------------------------------------

  function testManaIsConservedAcrossEveryTerminalPath() public {
    uint256 supplyBefore = _circulatingMana();

    bytes32 win = _playOut(alice, Element.Water, bob, Element.Fire, keccak256("win"), WAGER);
    IWorld(worldAddress).app__resolveMatch(win);

    bytes32 draw = _playOut(alice, Element.Fire, dave, Element.Fire, keccak256("draw"), WAGER);
    IWorld(worldAddress).app__resolveMatch(draw);

    bytes32 cancelled = _open(erin, keccak256("cancelled"), WAGER, Element.Fire, C_SALT);
    vm.prank(erin);
    IWorld(worldAddress).app__cancelLobby(cancelled);

    bytes32 forfeit = _match(alice, Element.Water, bob, Element.Fire, keccak256("forfeit"), WAGER);
    _reveal(alice, forfeit, Element.Water, C_SALT);
    vm.warp(block.timestamp + REVEAL_WINDOW + 1);
    IWorld(worldAddress).app__claimTimeout(forfeit);

    bytes32 noShow = _match(dave, Element.Fire, erin, Element.Water, keccak256("no-show"), WAGER);
    vm.warp(block.timestamp + REVEAL_WINDOW + 1);
    IWorld(worldAddress).app__claimTimeout(noShow);

    assertEq(_circulatingMana(), supplyBefore, "the arena must neither mint nor burn mana");
  }

  function testFuzz_SettlementIsZeroSum(uint128 wager, uint8 challengerMove, uint8 opponentMove) public {
    wager = uint128(bound(uint256(wager), 1, FUNDING));
    Element cMove = Element(bound(uint256(challengerMove), uint256(Element.Fire), uint256(Element.Earth)));
    Element oMove = Element(bound(uint256(opponentMove), uint256(Element.Fire), uint256(Element.Earth)));

    uint256 supplyBefore = _circulatingMana();

    bytes32 lobbyId = _playOut(alice, cMove, bob, oMove, LOBBY_SALT, wager);
    bytes32 winner = IWorld(worldAddress).app__resolveMatch(lobbyId);

    assertEq(_circulatingMana(), supplyBefore, "settlement must be zero-sum for every move pairing");
    assertEq(ArenaLobby.getWinner(lobbyId), winner, "winner field must match the return value");

    if (winner == bytes32(0)) {
      assertEq(ManaBalance.getAmount(aliceEntity), FUNDING, "draw refunds the challenger");
      assertEq(ManaBalance.getAmount(bobEntity), FUNDING, "draw refunds the opponent");
    } else {
      address loser = winner == aliceEntity ? bob : alice;
      assertEq(ManaBalance.getAmount(winner), FUNDING + wager, "winner");
      assertEq(ManaBalance.getAmount(_entityOf(loser)), FUNDING - wager, "loser");
    }
  }

  // ---------------------------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------------------------

  function _entityOf(address account) internal pure returns (bytes32) {
    return bytes32(uint256(uint160(account)));
  }

  function _commit(Element move, bytes32 salt) internal pure returns (bytes32) {
    return keccak256(abi.encodePacked(move, salt));
  }

  /// @dev No minting System exists yet, so state is seeded as the namespace owner.
  function _seedCrystal(address account, uint256 tokenId, uint8 level, uint128 mana) internal {
    bytes32 entity = _entityOf(account);
    vm.startPrank(deployer);
    CrystalData.set(entity, tokenId, level);
    ManaBalance.setAmount(entity, mana);
    vm.stopPrank();
  }

  function _installHook(ResourceId tableId, uint8 enabledHooks) internal returns (ReentrantHook hook) {
    hook = new ReentrantHook(IWorld(worldAddress));
    vm.prank(deployer);
    IWorld(worldAddress).registerStoreHook(tableId, hook, enabledHooks);
  }

  function _assertBlocked(ReentrantHook hook) internal view {
    assertTrue(hook.fired(), "hook never ran, the test would prove nothing");
    assertTrue(hook.blocked(), "the re-entrant call should have reverted");
    assertFalse(hook.reentered(), "the re-entrant call must not succeed");
  }

  function _open(
    address challenger,
    bytes32 lobbySalt,
    uint128 wager,
    Element move,
    bytes32 salt
  ) internal returns (bytes32 lobbyId) {
    vm.prank(challenger);
    lobbyId = IWorld(worldAddress).app__createLobby(lobbySalt, wager, _commit(move, salt));
  }

  function _join(address opponent, bytes32 lobbyId, Element move, bytes32 salt) internal {
    vm.prank(opponent);
    IWorld(worldAddress).app__joinLobby(lobbyId, _commit(move, salt));
  }

  function _reveal(address player, bytes32 lobbyId, Element move, bytes32 salt) internal {
    vm.prank(player);
    IWorld(worldAddress).app__revealMove(lobbyId, move, salt);
  }

  function _match(
    address challenger,
    Element challengerMove,
    address opponent,
    Element opponentMove,
    bytes32 lobbySalt,
    uint128 wager
  ) internal returns (bytes32 lobbyId) {
    lobbyId = _open(challenger, lobbySalt, wager, challengerMove, C_SALT);
    _join(opponent, lobbyId, opponentMove, O_SALT);
  }

  function _playOut(
    address challenger,
    Element challengerMove,
    address opponent,
    Element opponentMove,
    bytes32 lobbySalt,
    uint128 wager
  ) internal returns (bytes32 lobbyId) {
    lobbyId = _match(challenger, challengerMove, opponent, opponentMove, lobbySalt, wager);
    _reveal(challenger, lobbyId, challengerMove, C_SALT);
    _reveal(opponent, lobbyId, opponentMove, O_SALT);
  }

  function _circulatingMana() internal view returns (uint256) {
    return
      uint256(ManaBalance.getAmount(aliceEntity)) +
      ManaBalance.getAmount(bobEntity) +
      ManaBalance.getAmount(daveEntity) +
      ManaBalance.getAmount(erinEntity) +
      ManaBalance.getAmount(strangerEntity);
  }
}
