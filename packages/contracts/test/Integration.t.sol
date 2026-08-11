// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import { MudTest } from "@latticexyz/world/test/MudTest.t.sol";

import { IWorld } from "../src/codegen/world/IWorld.sol";
import { ICrystalForgeSystem } from "../src/codegen/world/ICrystalForgeSystem.sol";
import { IProgressionSystem } from "../src/codegen/world/IProgressionSystem.sol";
import { IArenaSystem } from "../src/codegen/world/IArenaSystem.sol";
import { CrystalNFT } from "../src/tokens/CrystalNFT.sol";
import { ManaToken } from "../src/tokens/ManaToken.sol";
import { AtlantysmAccount } from "../src/accounts/AtlantysmAccount.sol";
import { CrystalData, CrystalOwner, ManaBalance } from "../src/codegen/index.sol";
import { Element } from "../src/codegen/common.sol";

/**
 * @dev The keystone test: a human plays the game.
 *
 * THE RULE OF THIS FILE — it never pranks a token bound account. Every other suite reaches the
 * crystal's identity with `vm.prank(account)`, which is a cheat no player has. Here the only
 * addresses ever pranked are the EOAs Alice and Bob; the crystals act because their ERC-6551
 * accounts really exist on-chain and really forward calls.
 *
 * That distinction is the whole point of phase 9. Up to phase 8 the game passed 135 tests and was
 * still unplayable by a human, because nothing could call as a crystal. If this file passes without
 * pranking an account, the architecture closes.
 *
 * It also uses the wiring `PostDeploy` left rather than building its own, so what it exercises is
 * the deployment a real `pnpm dev` produces.
 */
contract IntegrationTest is MudTest {
  address internal alice = address(0xA11CE);
  address internal bob = address(0xB0B);

  CrystalNFT internal nft;
  ManaToken internal mana;

  uint256 internal constant MINT_PRICE = 0.01 ether;
  uint128 internal constant STARTER_MANA = 100 ether;
  uint128 internal constant BASE_COST = 50 ether;

  function setUp() public override {
    super.setUp();

    (address nftAddress, address manaAddress) = IWorld(worldAddress).app__tokenFacades();
    nft = CrystalNFT(nftAddress);
    mana = ManaToken(manaAddress);
  }

  // ---------------------------------------------------------------------------------------------
  // The account exists, and it is where MUD said it would be
  // ---------------------------------------------------------------------------------------------

  /**
   * @dev Phase 8 open point 1 closed. The account used to be a prediction only; minting now gives
   * the crystal a body in the same transaction.
   */
  function testMintingDeploysTheCrystalsAccountOnChain() public {
    (uint256 tokenId, address account) = _aliceMints();

    assertTrue(account.code.length > 0, "the token bound account must actually exist on-chain");
    assertEq(account.code.length, 173, "and be the 173-byte ERC-6551 proxy");
  }

  /**
   * @dev The agreement that everything else rests on: MUD wrote the crystal's state at an address
   * derived by hashing, and the registry deployed the account by CREATE2. If those two disagreed,
   * the crystal's mana would sit at an address its account could never occupy — and `ForgeConfig`
   * freezes at the first mint, so it would be permanent.
   */
  function testTheAccountLandsExactlyWhereMudPredicted() public {
    (uint256 tokenId, address account) = _aliceMints();

    bytes32 entity = IWorld(worldAddress).app__crystalEntityOf(tokenId);
    assertEq(entity, bytes32(uint256(uint160(account))), "entity is the deployed account, widened");
    assertTrue(CrystalData.getLevel(entity) != 0, "and MUD has a crystal there");
  }

  function testTheAccountKnowsWhichCrystalItIs() public {
    (uint256 tokenId, address account) = _aliceMints();

    (uint256 chainId, address tokenContract, uint256 boundTokenId) = AtlantysmAccount(payable(account)).token();

    assertEq(chainId, block.chainid, "bound on this chain");
    assertEq(tokenContract, address(nft), "bound to the crystal NFT");
    assertEq(boundTokenId, tokenId, "bound to this token");
    assertEq(AtlantysmAccount(payable(account)).owner(), alice, "and its owner is the human who minted it");
  }

  // ---------------------------------------------------------------------------------------------
  // A human drives the crystal
  // ---------------------------------------------------------------------------------------------

  /**
   * @dev THE headline of this phase. Alice never becomes the crystal — she instructs it. The World
   * sees `_msgSender()` as the account, so the identity check that has guarded every System since
   * phase 3 resolves to the crystal, exactly as designed.
   */
  function testAliceDrivesHerCrystalToClaimStarterMana() public {
    (uint256 tokenId, address account) = _aliceMints();
    bytes32 entity = IWorld(worldAddress).app__crystalEntityOf(tokenId);

    assertEq(ManaBalance.getAmount(entity), 0, "no mana before the claim");

    vm.prank(alice); // the HUMAN, not the crystal
    AtlantysmAccount(payable(account)).callSystem(
      worldAddress,
      abi.encodeCall(IProgressionSystem.app__claimStarterMana, ())
    );

    assertEq(ManaBalance.getAmount(entity), STARTER_MANA, "the crystal drew its own grant");
    assertEq(mana.balanceOf(account), STARTER_MANA, "and the ERC-20 shows it");
  }

  /// @dev `executeCall` is the general form; `callSystem` is sugar over it. Both must work, and both
  /// must be owner-gated.
  function testExecuteCallReachesTheWorldToo() public {
    (uint256 tokenId, address account) = _aliceMints();
    bytes32 entity = IWorld(worldAddress).app__crystalEntityOf(tokenId);

    vm.prank(alice);
    AtlantysmAccount(payable(account)).executeCall(
      worldAddress,
      0,
      abi.encodeCall(IProgressionSystem.app__claimStarterMana, ())
    );

    assertEq(ManaBalance.getAmount(entity), STARTER_MANA, "same result through the generic entry point");
  }

  function testOnlyTheOwnerCanDriveTheCrystal() public {
    (, address account) = _aliceMints();

    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(AtlantysmAccount.AtlantysmAccount_NotAuthorized.selector, bob));
    AtlantysmAccount(payable(account)).callSystem(worldAddress, abi.encodeCall(IProgressionSystem.app__claimStarterMana, ()));
  }

  /**
   * @dev Authority is not stored anywhere — it is derived, all the way down:
   *   MUD CrystalOwner -> CrystalNFT.ownerOf -> AtlantysmAccount.owner -> who may execute
   * so selling the crystal hands over its account in the same transaction that moves the token.
   */
  function testAuthorityFollowsTheNftWhenItIsSold() public {
    (uint256 tokenId, address account) = _aliceMints();

    vm.prank(alice);
    nft.transferFrom(alice, bob, tokenId);

    assertEq(AtlantysmAccount(payable(account)).owner(), bob, "the account now answers to the buyer");

    // The seller has lost control...
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(AtlantysmAccount.AtlantysmAccount_NotAuthorized.selector, alice));
    AtlantysmAccount(payable(account)).callSystem(worldAddress, abi.encodeCall(IProgressionSystem.app__claimStarterMana, ()));

    // ...and the buyer has gained it, with the crystal's identity unchanged underneath.
    bytes32 entity = IWorld(worldAddress).app__crystalEntityOf(tokenId);
    vm.prank(bob);
    AtlantysmAccount(payable(account)).callSystem(worldAddress, abi.encodeCall(IProgressionSystem.app__claimStarterMana, ()));
    assertEq(ManaBalance.getAmount(entity), STARTER_MANA, "same crystal, new driver");
  }

  // ---------------------------------------------------------------------------------------------
  // The account is powerful, but not privileged
  // ---------------------------------------------------------------------------------------------

  /**
   * @dev An ERC-6551 account can call anything, which is what makes it useful — and a reasonable
   * worry. It confers no standing inside the game: the facade-only gates reject it like any other
   * address, so a crystal cannot mint itself siblings.
   */
  function testTheAccountCannotBypassTheFacadeOnlyGates() public {
    (, address account) = _aliceMints();
    vm.deal(account, MINT_PRICE);

    vm.prank(alice);
    vm.expectRevert(
      abi.encodeWithSelector(ICrystalForgeSystem.CrystalForge_NotTheCrystalFacade.selector, account)
    );
    AtlantysmAccount(payable(account)).executeCall(
      worldAddress,
      MINT_PRICE,
      abi.encodeCall(ICrystalForgeSystem.app__mintCrystal, (alice))
    );
  }

  /// @dev A System's custom error must survive the hop through the account, or every failure a
  /// player sees would be an opaque blob.
  function testSystemRevertsSurviveTheAccountHopDecodable() public {
    (uint256 tokenId, address account) = _aliceMints();
    bytes32 entity = IWorld(worldAddress).app__crystalEntityOf(tokenId);

    vm.prank(alice);
    AtlantysmAccount(payable(account)).callSystem(worldAddress, abi.encodeCall(IProgressionSystem.app__claimStarterMana, ()));

    vm.prank(alice);
    vm.expectRevert(
      abi.encodeWithSelector(IProgressionSystem.Progression_StarterManaAlreadyClaimed.selector, entity)
    );
    AtlantysmAccount(payable(account)).callSystem(worldAddress, abi.encodeCall(IProgressionSystem.app__claimStarterMana, ()));
  }

  /// @dev ERC-6551 requires `state` to move on every state-changing operation.
  function testStateAdvancesOnEveryExecution() public {
    (, address account) = _aliceMints();

    uint256 before = AtlantysmAccount(payable(account)).state();

    vm.prank(alice);
    AtlantysmAccount(payable(account)).callSystem(worldAddress, abi.encodeCall(IProgressionSystem.app__claimStarterMana, ()));

    assertEq(AtlantysmAccount(payable(account)).state(), before + 1, "state must advance");
  }

  // ---------------------------------------------------------------------------------------------
  // The whole journey
  // ---------------------------------------------------------------------------------------------

  /// @dev Mint, fund, grow — every step initiated by the human, executed by the crystal.
  function testTheFullPlayerJourney() public {
    (uint256 tokenId, address account) = _aliceMints();
    bytes32 entity = IWorld(worldAddress).app__crystalEntityOf(tokenId);

    assertEq(nft.ownerOf(tokenId), alice, "alice owns the crystal");
    assertEq(CrystalOwner.getOwner(entity), alice, "and MUD agrees");

    _drive(alice, account, abi.encodeCall(IProgressionSystem.app__claimStarterMana, ()));
    assertEq(ManaBalance.getAmount(entity), STARTER_MANA, "funded");

    _drive(alice, account, abi.encodeCall(IProgressionSystem.app__levelUp, ()));
    assertEq(CrystalData.getLevel(entity), 2, "grown");
    assertEq(ManaBalance.getAmount(entity), STARTER_MANA - BASE_COST, "and paid for it");
  }

  /**
   * @dev Two humans, two crystals, one match — with no cheat codes touching either account. Both
   * play the same element so the elemental triangle cancels and only the level decides, which makes
   * the outcome a statement about progression rather than about luck.
   */
  function testTwoHumansFightThroughTheirCrystals() public {
    (uint256 aliceToken, address aliceAccount) = _mintFor(alice);
    (uint256 bobToken, address bobAccount) = _mintFor(bob);

    bytes32 aliceEntity = IWorld(worldAddress).app__crystalEntityOf(aliceToken);
    bytes32 bobEntity = IWorld(worldAddress).app__crystalEntityOf(bobToken);

    _drive(alice, aliceAccount, abi.encodeCall(IProgressionSystem.app__claimStarterMana, ()));
    _drive(bob, bobAccount, abi.encodeCall(IProgressionSystem.app__claimStarterMana, ()));

    // Alice invests in a level; Bob does not.
    _drive(alice, aliceAccount, abi.encodeCall(IProgressionSystem.app__levelUp, ()));

    uint128 wager = 10 ether;
    uint128 aliceBefore = ManaBalance.getAmount(aliceEntity);
    uint128 bobBefore = ManaBalance.getAmount(bobEntity);

    bytes32 lobbySalt = keccak256("integration-duel");
    bytes32 lobbyId = keccak256(abi.encode(aliceEntity, lobbySalt));

    _drive(
      alice,
      aliceAccount,
      abi.encodeCall(
        IArenaSystem.app__createLobby,
        (lobbySalt, wager, _commit(lobbyId, aliceEntity, Element.Fire, "a"))
      )
    );
    _drive(
      bob,
      bobAccount,
      abi.encodeCall(IArenaSystem.app__joinLobby, (lobbyId, _commit(lobbyId, bobEntity, Element.Fire, "b")))
    );

    _drive(alice, aliceAccount, abi.encodeCall(IArenaSystem.app__revealMove, (lobbyId, Element.Fire, "a")));
    _drive(bob, bobAccount, abi.encodeCall(IArenaSystem.app__revealMove, (lobbyId, Element.Fire, "b")));

    assertEq(IWorld(worldAddress).app__resolveMatch(lobbyId), aliceEntity, "the levelled crystal wins");
    assertEq(ManaBalance.getAmount(aliceEntity), aliceBefore + wager, "winner takes the pot");
    assertEq(ManaBalance.getAmount(bobEntity), bobBefore - wager, "loser forfeits the wager");
  }

  // ---------------------------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------------------------

  function _aliceMints() internal returns (uint256 tokenId, address account) {
    return _mintFor(alice);
  }

  function _mintFor(address human) internal returns (uint256 tokenId, address account) {
    vm.deal(human, MINT_PRICE);
    vm.prank(human);
    tokenId = nft.mint{ value: MINT_PRICE }(human);
    account = IWorld(worldAddress).app__crystalAccountOf(tokenId);
  }

  /// @dev A human instructing their crystal. Note what is NOT here: `vm.prank(account)`.
  function _drive(address human, address account, bytes memory callData) internal returns (bytes memory) {
    vm.prank(human);
    return AtlantysmAccount(payable(account)).callSystem(worldAddress, callData);
  }

  /// @dev Mirrors `ArenaSystem._commitmentOf` (phase 3.6 binding).
  function _commit(bytes32 lobbyId, bytes32 player, Element move, bytes32 salt) internal pure returns (bytes32) {
    return keccak256(abi.encodePacked(lobbyId, player, move, salt));
  }
}
