// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import { MudTest } from "@latticexyz/world/test/MudTest.t.sol";
import { StoreHook } from "@latticexyz/store/src/StoreHook.sol";
import { ResourceId } from "@latticexyz/store/src/ResourceId.sol";
import { AFTER_SPLICE_STATIC_DATA } from "@latticexyz/store/src/storeHookTypes.sol";

import { IWorld } from "../src/codegen/world/IWorld.sol";
import { IProgressionSystem } from "../src/codegen/world/IProgressionSystem.sol";
// Worldgen exposes errors but not events, so the event tests reference the System directly: a
// signature change then breaks compilation instead of asserting a stale shape.
import { ProgressionSystem } from "../src/systems/ProgressionSystem.sol";
import { CrystalNFT } from "../src/tokens/CrystalNFT.sol";
import { DevERC6551Registry } from "../src/dev/DevERC6551Registry.sol";
import { AtlantysmAccount } from "../src/accounts/AtlantysmAccount.sol";
import { ManaToken } from "../src/tokens/ManaToken.sol";
import { CrystalData, ManaBalance, ManaSupply, StarterManaClaimed } from "../src/codegen/index.sol";
import { Element } from "../src/codegen/common.sol";


/**
 * @dev Re-enters `levelUp` from inside the mana write, to test security note 2 rather than trust it.
 *
 * `levelUp` has no terminal state, so re-entry cannot be blocked outright — the guarantee is only
 * that it fails SAFE. This hook is what makes that guarantee falsifiable: with the debit written
 * before the level, the re-entrant call sees an already-debited balance and an unraised level, so it
 * pays again for the same level. Reverse the two writes and it would instead see a raised level
 * against an undebited balance, and the outer write would overwrite the inner debit — two levels for
 * one payment.
 */
contract ReentrantLevelUpHook is StoreHook {
  IWorld private immutable world;

  bool public armed;
  bool public fired;
  bool public reentered;
  bool private claimMode;

  constructor(IWorld _world) {
    world = _world;
  }

  function arm(bool _claimMode) external {
    claimMode = _claimMode;
    armed = true;
  }

  function onAfterSpliceStaticData(ResourceId, bytes32[] memory, uint48, bytes memory) public override {
    if (!armed) return;
    armed = false; // one shot, otherwise it recurses on its own writes
    fired = true;

    if (claimMode) {
      try world.app__claimStarterMana() {
        reentered = true;
      } catch {
        reentered = false;
      }
    } else {
      try world.app__levelUp() {
        reentered = true;
      } catch {
        reentered = false;
      }
    }
  }
}

contract ProgressionSystemTest is MudTest {
  address internal human = address(0xB0B);
  address internal outsider = address(0x0157DE2);

  /// @dev Owner of the `app` namespace, needed to seed state no System writes yet.
  address internal deployer;

  address internal registry;
  address internal accountImplementation;
  address internal constant TOKEN_CONTRACT = address(0x7075E7);
  bytes32 internal constant ACCOUNT_SALT = bytes32(uint256(0xA71A));

  uint128 internal constant STARTER_MANA = 100 ether;

  /// @dev Base of the quadratic ladder. Note that the cost at level 1 is `BASE * 1^2 == BASE`, which
  /// is why every level-1 assertion below reads the same as it did under the old linear curve.
  uint128 internal constant BASE_COST = 50 ether;

  uint256 internal constant MINT_PRICE = 0.01 ether;

  /// @dev The NFT facade is the only mint path since phase 7.
  CrystalNFT internal nft;
  ManaToken internal manaToken;

  function setUp() public override {
    super.setUp();

    deployer = vm.addr(vm.envUint("PRIVATE_KEY"));
    registry = address(new DevERC6551Registry());
    accountImplementation = address(new AtlantysmAccount());

    nft = new CrystalNFT(IWorld(worldAddress));
    manaToken = new ManaToken(IWorld(worldAddress));

    vm.startPrank(deployer);
    IWorld(worldAddress).app__configureForge(registry, accountImplementation, TOKEN_CONTRACT, ACCOUNT_SALT);
    IWorld(worldAddress).app__setMintPrice(MINT_PRICE);
    IWorld(worldAddress).app__setTokenFacades(address(nft), address(manaToken));
    vm.stopPrank();
  }

  // ---------------------------------------------------------------------------------------------
  // Faucet
  // ---------------------------------------------------------------------------------------------

  function testClaimStarterManaCreditsTheCrystal() public {
    (bytes32 entity, address account) = _forge();

    assertEq(ManaBalance.getAmount(entity), 0, "a forged crystal starts with no mana");
    assertTrue(IWorld(worldAddress).app__canClaimStarterMana(entity), "eligible before claiming");

    vm.prank(account);
    uint128 granted = IWorld(worldAddress).app__claimStarterMana();

    assertEq(granted, STARTER_MANA, "granted amount");
    assertEq(ManaBalance.getAmount(entity), STARTER_MANA, "credited to the crystal");
    assertTrue(StarterManaClaimed.getClaimed(entity), "flag set");
    assertFalse(IWorld(worldAddress).app__canClaimStarterMana(entity), "no longer eligible");
  }

  function testStarterManaCannotBeClaimedTwice() public {
    (bytes32 entity, address account) = _forge();

    vm.prank(account);
    IWorld(worldAddress).app__claimStarterMana();

    vm.prank(account);
    vm.expectRevert(
      abi.encodeWithSelector(IProgressionSystem.Progression_StarterManaAlreadyClaimed.selector, entity)
    );
    IWorld(worldAddress).app__claimStarterMana();

    assertEq(ManaBalance.getAmount(entity), STARTER_MANA, "balance must not have moved");
  }

  /**
   * @dev The reason the flag is a separate fact rather than an inference. After spending the grant
   * the balance is back near zero, so any implementation that decided eligibility by looking at
   * `ManaBalance` would refill the crystal forever.
   */
  function testStarterManaCannotBeReclaimedAfterSpendingItAll() public {
    (bytes32 entity, address account) = _forge();

    vm.prank(account);
    IWorld(worldAddress).app__claimStarterMana();

    // Spend half the grant on a level, then drain the rest. The second step is seeded rather than
    // played out because levelling is currently the only sink and the next level already costs more
    // than the grant leaves behind — any future sink would land in the same place.
    vm.prank(account);
    IWorld(worldAddress).app__levelUp();
    assertEq(ManaBalance.getAmount(entity), STARTER_MANA - BASE_COST, "half spent on a level");
    _fund(entity, 0);

    assertEq(ManaBalance.getAmount(entity), 0, "balance now looks exactly like a crystal that never claimed");

    vm.prank(account);
    vm.expectRevert(
      abi.encodeWithSelector(IProgressionSystem.Progression_StarterManaAlreadyClaimed.selector, entity)
    );
    IWorld(worldAddress).app__claimStarterMana();
  }

  /// @dev Identity: an address with no crystal at its entity is not a token bound account.
  function testClaimRevertsForAnAddressThatIsNotACrystal() public {
    vm.prank(outsider);
    vm.expectRevert(
      abi.encodeWithSelector(IProgressionSystem.Progression_UnknownCrystal.selector, _entityOf(outsider))
    );
    IWorld(worldAddress).app__claimStarterMana();
  }

  /**
   * @dev Identity, the case that matters: the HUMAN owner cannot draw the crystal's grant. The
   * owner is not the entity — that is the whole forge/fight split from phase 4.
   */
  function testClaimRevertsForTheOwnerRatherThanTheAccount() public {
    _forge();

    vm.prank(human);
    vm.expectRevert(
      abi.encodeWithSelector(IProgressionSystem.Progression_UnknownCrystal.selector, _entityOf(human))
    );
    IWorld(worldAddress).app__claimStarterMana();
  }

  /// @dev The grant is per crystal, not per owner: one human with two crystals draws twice.
  function testEachCrystalHasItsOwnGrant() public {
    (bytes32 first, address firstAccount) = _forge();
    (bytes32 second, address secondAccount) = _forge();

    vm.prank(firstAccount);
    IWorld(worldAddress).app__claimStarterMana();
    vm.prank(secondAccount);
    IWorld(worldAddress).app__claimStarterMana();

    assertEq(ManaBalance.getAmount(first), STARTER_MANA, "first");
    assertEq(ManaBalance.getAmount(second), STARTER_MANA, "second");
  }

  // ---------------------------------------------------------------------------------------------
  // Level up
  // ---------------------------------------------------------------------------------------------

  function testLevelUpRaisesLevelAndBurnsMana() public {
    (bytes32 entity, address account) = _forge();
    _fund(entity, STARTER_MANA);

    assertEq(CrystalData.getLevel(entity), 1, "starts at level 1");
    assertEq(IWorld(worldAddress).app__levelUpCost(entity), BASE_COST, "cost at level 1");

    vm.prank(account);
    uint8 newLevel = IWorld(worldAddress).app__levelUp();

    assertEq(newLevel, 2, "returned level");
    assertEq(CrystalData.getLevel(entity), 2, "persisted level");
    assertEq(ManaBalance.getAmount(entity), STARTER_MANA - BASE_COST, "mana debited");
  }

  /**
   * @dev The ladder is QUADRATIC since phase 6: each level costs `50 * level^2`. Damage still scales
   * linearly with level, so squaring the price is what makes each additional point of power cost
   * strictly more than the last.
   */
  function testLevelUpCostIsQuadratic() public {
    (bytes32 entity, address account) = _forge();
    _fund(entity, 5_000 ether);

    uint128 spent = 0;
    for (uint8 level = 1; level <= 5; level++) {
      uint128 expected = BASE_COST * level * level;
      assertEq(IWorld(worldAddress).app__levelUpCost(entity), expected, "quoted cost");

      vm.prank(account);
      IWorld(worldAddress).app__levelUp();

      spent += expected;
      assertEq(CrystalData.getLevel(entity), level + 1, "level after each step");
      assertEq(ManaBalance.getAmount(entity), 5_000 ether - spent, "running balance");
    }

    // 50*1 + 50*4 + 50*9 + 50*16 + 50*25 = 50 + 200 + 450 + 800 + 1250
    assertEq(spent, 2_750 ether, "total cost of levels 1 through 5");
  }

  /// @dev Pinned literals, so a refactor that quietly reintroduced a linear curve would fail here
  /// rather than merely change a formula that the test recomputes the same wrong way.
  function testLevelUpCostMatchesExplicitLiterals() public {
    (bytes32 entity, ) = _forge();

    vm.startPrank(deployer);
    uint128[6] memory expected = [uint128(0), 50 ether, 200 ether, 450 ether, 800 ether, 1_250 ether];
    for (uint8 level = 1; level <= 5; level++) {
      CrystalData.setLevel(entity, level);
      assertEq(IWorld(worldAddress).app__levelUpCost(entity), expected[level], "quadratic literal");
    }
    vm.stopPrank();
  }

  /**
   * @dev The question the quadratic curve raises: does the uint128 mana ceiling now make high levels
   * physically unreachable? It does not, and the margin is enormous — so MAX_LEVEL stays 255.
   *   dearest single step (254 -> 255): 50e18 * 254^2 = 3.2258e24 wei
   *   uint128 ceiling:                                  3.4028e38 wei
   * A crystal only ever holds one step at a time, so the whole uint8 range remains payable.
   */
  function testTheQuadraticCurveNeverOutgrowsTheUint128Ceiling() public {
    (bytes32 entity, ) = _forge();

    vm.prank(deployer);
    CrystalData.setLevel(entity, 254);

    uint128 dearestStep = IWorld(worldAddress).app__levelUpCost(entity);
    assertEq(dearestStep, BASE_COST * 254 * 254, "dearest step");
    assertEq(dearestStep, 3_225_800 ether, "3.2258e24 wei, spelled out independently of the formula");
    assertLt(dearestStep, type(uint128).max, "must remain payable within a uint128 balance");

    // And it is genuinely payable, not merely representable.
    _fund(entity, dearestStep);
    address account = address(uint160(uint256(entity)));
    vm.prank(account);
    assertEq(IWorld(worldAddress).app__levelUp(), 255, "the ceiling is reachable under the new curve");
  }

  function testLevelUpRevertsOnInsufficientMana() public {
    (bytes32 entity, address account) = _forge();
    _fund(entity, BASE_COST - 1 wei);

    vm.prank(account);
    vm.expectRevert(
      abi.encodeWithSelector(
        IProgressionSystem.Progression_InsufficientMana.selector,
        entity,
        BASE_COST - 1 wei,
        BASE_COST
      )
    );
    IWorld(worldAddress).app__levelUp();

    assertEq(CrystalData.getLevel(entity), 1, "level must not move on a failed payment");
  }

  /// @dev The boundary must be inclusive: exactly enough is enough.
  function testLevelUpSucceedsAtExactlyTheCost() public {
    (bytes32 entity, address account) = _forge();
    _fund(entity, BASE_COST);

    vm.prank(account);
    IWorld(worldAddress).app__levelUp();

    assertEq(CrystalData.getLevel(entity), 2, "levelled");
    assertEq(ManaBalance.getAmount(entity), 0, "balance emptied exactly");
  }

  function testLevelUpRevertsForAnAddressThatIsNotACrystal() public {
    vm.prank(outsider);
    vm.expectRevert(
      abi.encodeWithSelector(IProgressionSystem.Progression_UnknownCrystal.selector, _entityOf(outsider))
    );
    IWorld(worldAddress).app__levelUp();
  }

  /**
   * @dev Security note 3. Checked arithmetic would already revert here with `Panic(0x11)`, so this
   * pins the named error rather than the absence of a wrap: removing the guard makes the test fail
   * on the panic instead. The distinction matters because `level == 0` is how every System reads
   * "no such crystal", so an `unchecked` refactor would turn this from a revert into a stranded
   * crystal — and the guard is what would still catch it.
   */
  function testLevelUpIsGuardedAtTheUint8Ceiling() public {
    (bytes32 entity, address account) = _forge();

    // No System can reach level 255 cheaply, so it is seeded as the namespace owner.
    vm.prank(deployer);
    CrystalData.setLevel(entity, 255);
    _fund(entity, type(uint128).max);

    vm.prank(account);
    vm.expectRevert(
      abi.encodeWithSelector(IProgressionSystem.Progression_MaxLevelReached.selector, entity, uint8(255))
    );
    IWorld(worldAddress).app__levelUp();

    assertEq(CrystalData.getLevel(entity), 255, "level must not wrap");
    assertTrue(CrystalData.getLevel(entity) != 0, "the crystal must still exist");
  }

  /// @dev Level 254 -> 255 must still be allowed; the guard blocks the wrap, not the last level.
  function testLevelUpToTheCeilingIsAllowed() public {
    (bytes32 entity, address account) = _forge();

    vm.prank(deployer);
    CrystalData.setLevel(entity, 254);
    _fund(entity, type(uint128).max);

    vm.prank(account);
    assertEq(IWorld(worldAddress).app__levelUp(), 255, "254 -> 255 is legal");
  }

  /**
   * @dev "The mana spent must disappear": it is burned, not moved. Summing every entity that could
   * plausibly receive it proves nothing was credited elsewhere.
   */
  function testLevelUpBurnsManaRatherThanTransferringIt() public {
    (bytes32 entity, address account) = _forge();
    _fund(entity, STARTER_MANA);

    uint256 before = _trackedSupply(entity);

    vm.prank(account);
    IWorld(worldAddress).app__levelUp();

    assertEq(_trackedSupply(entity), before - BASE_COST, "supply must shrink by exactly the cost");
    assertEq(ManaBalance.getAmount(_entityOf(human)), 0, "the owner must not receive it");
    assertEq(ManaBalance.getAmount(_entityOf(worldAddress)), 0, "nor the World");
  }

  function testLevelUpCostViewRevertsForAnUnknownCrystal() public {
    vm.expectRevert(
      abi.encodeWithSelector(IProgressionSystem.Progression_UnknownCrystal.selector, _entityOf(outsider))
    );
    IWorld(worldAddress).app__levelUpCost(_entityOf(outsider));
  }

  // ---------------------------------------------------------------------------------------------
  // Events
  // ---------------------------------------------------------------------------------------------

  function testClaimEmitsStarterManaGranted() public {
    (bytes32 entity, address account) = _forge();

    vm.expectEmit(true, false, false, true);
    emit ProgressionSystem.StarterManaGranted(entity, STARTER_MANA, STARTER_MANA);

    vm.prank(account);
    IWorld(worldAddress).app__claimStarterMana();
  }

  function testLevelUpEmitsCrystalLeveledUp() public {
    (bytes32 entity, address account) = _forge();
    _fund(entity, STARTER_MANA);

    vm.expectEmit(true, false, false, true);
    emit ProgressionSystem.CrystalLeveledUp(entity, 2, BASE_COST, STARTER_MANA - BASE_COST);

    vm.prank(account);
    IWorld(worldAddress).app__levelUp();
  }

  // ---------------------------------------------------------------------------------------------
  // Reentrancy
  // ---------------------------------------------------------------------------------------------

  /**
   * @dev Security note 2, proved rather than asserted. The hook is installed AT the crystal's own
   * account address, so the re-entrant call arrives with the SAME `_msgSender()` and therefore
   * operates on the SAME entity — which is the only configuration in which the stale-read problem
   * exists at all. It is hooked on `CrystalData`, the write the unsafe ordering would perform first.
   *
   * The invariant checked is the one that actually matters: mana burned must cover the full ladder
   * price of every level gained. Reverse the two writes in `levelUp` and the outer call overwrites
   * the inner debit with a stale local, yielding two levels for one payment — which this fails on.
   */
  function testReentrantLevelUpCannotBuyLevelsBelowTheLadderPrice() public {
    (bytes32 entity, address account) = _forge();
    uint128 funded = 1_000 ether;
    _fund(entity, funded);

    _installHookAtAccount(account, false);

    vm.prank(account);
    IWorld(worldAddress).app__levelUp();

    assertTrue(ReentrantLevelUpHook(account).fired(), "the hook never ran, the test would prove nothing");

    uint8 finalLevel = CrystalData.getLevel(entity);
    uint128 burned = funded - ManaBalance.getAmount(entity);

    assertTrue(finalLevel > 1, "the crystal should have levelled at least once");

    // Full ladder price for every level actually gained: 50 * (1^2 + 2^2 + ... + n^2).
    uint128 fairPrice = 0;
    for (uint8 level = 1; level < finalLevel; level++) {
      fairPrice += BASE_COST * level * level;
    }

    assertTrue(burned >= fairPrice, "levels gained must never cost less than the ladder price");
  }

  /**
   * @dev The claim path is fully closed, not merely fail-safe: the flag is written before the mana
   * moves, so a re-entrant claim on the same entity finds it already spent and reverts.
   */
  function testReentrantClaimCannotDoubleCredit() public {
    (bytes32 entity, address account) = _forge();

    _installHookAtAccount(account, true);

    vm.prank(account);
    IWorld(worldAddress).app__claimStarterMana();

    assertTrue(ReentrantLevelUpHook(account).fired(), "the hook never ran");
    assertFalse(ReentrantLevelUpHook(account).reentered(), "the re-entrant claim must have reverted");
    assertEq(ManaBalance.getAmount(entity), STARTER_MANA, "credited exactly once");
  }

  // ---------------------------------------------------------------------------------------------
  // The loop, end to end
  // ---------------------------------------------------------------------------------------------

  /**
   * @dev Phase 4 left levels frozen at 1, which made `ADVANTAGE_MULTIPLIER` in `ArenaSystem`
   * unreachable. This closes the loop and proves progression actually buys combat power: two
   * crystals play the SAME element, so the elemental triangle cancels and only the level decides.
   */
  function testLevellingUpWinsAnOtherwiseIdenticalMatch() public {
    (bytes32 strongEntity, address strong) = _forge();
    (bytes32 weakEntity, address weak) = _forge();

    vm.prank(strong);
    IWorld(worldAddress).app__claimStarterMana();
    vm.prank(weak);
    IWorld(worldAddress).app__claimStarterMana();

    // Only one of them invests in a level.
    vm.prank(strong);
    IWorld(worldAddress).app__levelUp();
    assertEq(CrystalData.getLevel(strongEntity), 2, "invested");
    assertEq(CrystalData.getLevel(weakEntity), 1, "did not");

    uint128 wager = 10 ether;
    uint128 strongBefore = ManaBalance.getAmount(strongEntity);
    uint128 weakBefore = ManaBalance.getAmount(weakEntity);

    bytes32 lobbySalt = keccak256("progression-duel");
    bytes32 lobbyId = keccak256(abi.encode(strongEntity, lobbySalt));

    vm.prank(strong);
    IWorld(worldAddress).app__createLobby(lobbySalt, wager, _commit(lobbyId, strongEntity, Element.Fire, "s"));
    vm.prank(weak);
    IWorld(worldAddress).app__joinLobby(lobbyId, _commit(lobbyId, weakEntity, Element.Fire, "w"));

    vm.prank(strong);
    IWorld(worldAddress).app__revealMove(lobbyId, Element.Fire, "s");
    vm.prank(weak);
    IWorld(worldAddress).app__revealMove(lobbyId, Element.Fire, "w");

    assertEq(IWorld(worldAddress).app__resolveMatch(lobbyId), strongEntity, "the higher level must win");
    assertEq(ManaBalance.getAmount(strongEntity), strongBefore + wager, "winner takes the pot");
    assertEq(ManaBalance.getAmount(weakEntity), weakBefore - wager, "loser forfeits the wager");
  }

  /// @dev A freshly forged crystal can now reach the arena entirely on its own: forge, claim, fight.
  /// Phase 4 could not do this without an admin seeding mana by hand.
  function testFreshCrystalCanFundItselfAndEnterTheArena() public {
    (bytes32 entity, address account) = _forge();

    vm.prank(account);
    IWorld(worldAddress).app__claimStarterMana();

    vm.prank(account);
    bytes32 lobbyId = IWorld(worldAddress).app__createLobby(keccak256("self-funded"), 10 ether, keccak256("c"));

    assertTrue(lobbyId != bytes32(0), "the crystal funded itself into a match");
    assertEq(ManaBalance.getAmount(entity), STARTER_MANA - 10 ether, "wager escrowed from the grant");
  }

  // ---------------------------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------------------------

  function _entityOf(address account) internal pure returns (bytes32) {
    return bytes32(uint256(uint160(account)));
  }

  /// @dev Mirrors `ArenaSystem._commitmentOf` (phase 3.6 binding).
  function _commit(bytes32 lobbyId, bytes32 player, Element move, bytes32 salt) internal pure returns (bytes32) {
    return keccak256(abi.encodePacked(lobbyId, player, move, salt));
  }

  /// @dev Forge a crystal and return both its entity and the address that must call as it. The
  /// account is never deployed — phase 4 open point 2 — so tests reach it with `vm.prank`.
  function _forge() internal returns (bytes32 entity, address account) {
    vm.deal(human, MINT_PRICE);
    vm.prank(human);
    uint256 tokenId = nft.mint{ value: MINT_PRICE }(human);
    entity = IWorld(worldAddress).app__crystalEntityOf(tokenId);
    account = IWorld(worldAddress).app__crystalAccountOf(tokenId);
    assertEq(entity, _entityOf(account), "the entity must be the account, widened");
  }

  /**
   * @dev Plant the re-entrant hook AT the crystal's own account address, so its callback re-enters
   * with the same `_msgSender()` and therefore the same entity. `vm.etch` is what makes this
   * possible: the account is never deployed (phase 4 open point 2), so its address is free to take,
   * and the hook's `world` immutable travels with the runtime code.
   *
   * The hook is registered on the table whose write the safe ordering performs FIRST, since that is
   * where a reversed ordering would open its window: `CrystalData` for levelling, `ManaBalance` for
   * the claim.
   */
  function _installHookAtAccount(address account, bool claimMode) internal {
    ReentrantLevelUpHook template = new ReentrantLevelUpHook(IWorld(worldAddress));
    vm.etch(account, address(template).code);
    ReentrantLevelUpHook(account).arm(claimMode);

    ResourceId tableId = claimMode ? ManaBalance._tableId : CrystalData._tableId;
    vm.prank(deployer);
    IWorld(worldAddress).registerStoreHook(tableId, ReentrantLevelUpHook(account), AFTER_SPLICE_STATIC_DATA);
  }

  /**
   * @dev Seed mana directly where the faucet would be the wrong lever (boundary and ceiling tests).
   *
   * It must move `ManaSupply` by the same delta. That is not test bookkeeping for its own sake:
   * `ManaSupply` is DERIVED state, and `levelUp` subtracts from it, so seeding a balance without it
   * makes the next level-up underflow. Any future System that writes `ManaBalance` outside the
   * faucet inherits exactly this obligation.
   */
  function _fund(bytes32 entity, uint128 amount) internal {
    uint128 previous = ManaBalance.getAmount(entity);

    vm.startPrank(deployer);
    ManaBalance.setAmount(entity, amount);
    if (amount >= previous) {
      ManaSupply.setValue(ManaSupply.getValue() + (amount - previous));
    } else {
      ManaSupply.setValue(ManaSupply.getValue() - (previous - amount));
    }
    vm.stopPrank();
  }

  function _trackedSupply(bytes32 entity) internal view returns (uint256) {
    return
      uint256(ManaBalance.getAmount(entity)) +
      ManaBalance.getAmount(_entityOf(human)) +
      ManaBalance.getAmount(_entityOf(outsider)) +
      ManaBalance.getAmount(_entityOf(worldAddress)) +
      ManaBalance.getAmount(_entityOf(deployer));
  }
}
