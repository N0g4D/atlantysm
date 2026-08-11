// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import { MudTest } from "@latticexyz/world/test/MudTest.t.sol";
import { Vm } from "forge-std/Vm.sol";
import { IWorldErrors } from "@latticexyz/world/src/IWorldErrors.sol";
import { IERC721Errors, IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IWorld } from "../src/codegen/world/IWorld.sol";
import { ICrystalForgeSystem } from "../src/codegen/world/ICrystalForgeSystem.sol";
import { ITokenBridgeSystem } from "../src/codegen/world/ITokenBridgeSystem.sol";
import { IProgressionSystem } from "../src/codegen/world/IProgressionSystem.sol";
import { IArenaSystem } from "../src/codegen/world/IArenaSystem.sol";
import { CrystalNFT } from "../src/tokens/CrystalNFT.sol";
import { DevERC6551Registry } from "../src/dev/DevERC6551Registry.sol";
import { AtlantysmAccount } from "../src/accounts/AtlantysmAccount.sol";
import { ManaToken } from "../src/tokens/ManaToken.sol";
import { CrystalData, CrystalOwner, CrystalBalance, ManaBalance, ManaSupply } from "../src/codegen/index.sol";


/**
 * @dev Exercises the two facades against the World they project.
 *
 * The recurring question in every test here is the same one: does the ERC-721/ERC-20 view agree
 * with the MUD table it claims to mirror? Because the facades hold no state of their own, agreement
 * is not a property that can drift quietly — it either reads through or it does not.
 */
contract TokenFacadesTest is MudTest {
  address internal alice = address(0xA11CE);
  address internal bob = address(0xB0B);
  address internal carol = address(0xCA401);
  address internal stranger = address(0x57A2);

  address internal deployer;

  CrystalNFT internal nft;
  ManaToken internal mana;

  address internal constant TOKEN_CONTRACT = address(0x7075E7);
  bytes32 internal constant ACCOUNT_SALT = bytes32(uint256(0xA71A));
  uint256 internal constant MINT_PRICE = 0.01 ether;
  uint128 internal constant STARTER_MANA = 100 ether;
  uint128 internal constant BASE_COST = 50 ether;

  function setUp() public override {
    super.setUp();

    deployer = vm.addr(vm.envUint("PRIVATE_KEY"));

    nft = new CrystalNFT(IWorld(worldAddress));
    mana = new ManaToken(IWorld(worldAddress));

    vm.startPrank(deployer);
    IWorld(worldAddress).app__configureForge(
      address(new DevERC6551Registry()),
      address(new AtlantysmAccount()),
      TOKEN_CONTRACT,
      ACCOUNT_SALT
    );
    IWorld(worldAddress).app__setMintPrice(MINT_PRICE);
    IWorld(worldAddress).app__setTokenFacades(address(nft), address(mana));
    vm.stopPrank();
  }

  // ---------------------------------------------------------------------------------------------
  // ERC-721 projects MUD
  // ---------------------------------------------------------------------------------------------

  function testMintProjectsOwnershipStraightFromMud() public {
    uint256 tokenId = _mint(alice, alice);
    bytes32 entity = IWorld(worldAddress).app__crystalEntityOf(tokenId);

    assertEq(nft.ownerOf(tokenId), alice, "ownerOf reads through to MUD");
    assertEq(nft.ownerOf(tokenId), CrystalOwner.getOwner(entity), "and agrees with the table");
    assertEq(nft.balanceOf(alice), 1, "balanceOf reads the derived counter");
    assertEq(nft.balanceOf(alice), CrystalBalance.getCount(alice), "and agrees with the table");
  }

  function testMintEmitsTheErc721Transfer() public {
    // The token id is only knowable after the fact, so the event is matched on topics we can fix:
    // sender and recipient. The exact id is asserted separately below.
    vm.deal(alice, MINT_PRICE);
    vm.recordLogs();
    vm.prank(alice);
    uint256 tokenId = nft.mint{ value: MINT_PRICE }(alice);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    bool found;
    for (uint256 i = 0; i < logs.length; i++) {
      if (
        logs[i].emitter == address(nft) &&
        logs[i].topics[0] == keccak256("Transfer(address,address,uint256)") &&
        logs[i].topics[1] == bytes32(0) &&
        logs[i].topics[2] == bytes32(uint256(uint160(alice))) &&
        logs[i].topics[3] == bytes32(tokenId)
      ) {
        found = true;
      }
    }
    assertTrue(found, "a mint must announce itself as Transfer(0, to, tokenId)");
  }

  function testOwnerOfRevertsForAnUnmintedToken() public {
    uint256 ghost = uint256(keccak256("no such crystal"));

    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, ghost));
    nft.ownerOf(ghost);
  }

  function testTransferMovesOwnershipInMud() public {
    uint256 tokenId = _mint(alice, alice);
    bytes32 entity = IWorld(worldAddress).app__crystalEntityOf(tokenId);

    vm.prank(alice);
    nft.transferFrom(alice, bob, tokenId);

    assertEq(CrystalOwner.getOwner(entity), bob, "the MUD table is what actually moved");
    assertEq(nft.ownerOf(tokenId), bob, "and the facade reflects it");
    assertEq(nft.balanceOf(alice), 0, "sender balance");
    assertEq(nft.balanceOf(bob), 1, "recipient balance");
  }

  function testTransferEmitsTheErc721Transfer() public {
    uint256 tokenId = _mint(alice, alice);

    vm.expectEmit(true, true, true, false, address(nft));
    emit IERC721.Transfer(alice, bob, tokenId);

    vm.prank(alice);
    nft.transferFrom(alice, bob, tokenId);
  }

  /// @dev Approvals stay in the facade's own storage; this proves that half still works while the
  /// ledger half lives in MUD.
  function testApprovedOperatorCanMoveTheCrystal() public {
    uint256 tokenId = _mint(alice, alice);

    vm.prank(alice);
    nft.approve(carol, tokenId);

    vm.prank(carol);
    nft.transferFrom(alice, bob, tokenId);

    assertEq(nft.ownerOf(tokenId), bob, "the approved operator moved it");
  }

  function testTransferRevertsForAnUnauthorisedCaller() public {
    uint256 tokenId = _mint(alice, alice);

    vm.prank(stranger);
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, stranger, tokenId));
    nft.transferFrom(alice, bob, tokenId);
  }

  /// @dev Crystals cannot be destroyed — nothing deletes `CrystalData`, and a token at address(0)
  /// would strand the entity's mana and match history. OZ rejects this before our own guard is
  /// reached, so the guard in `_update` is defence in depth rather than the active check.
  function testCrystalsCannotBeBurned() public {
    uint256 tokenId = _mint(alice, alice);

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(0)));
    nft.transferFrom(alice, address(0), tokenId);
  }

  function testSelfTransferLeavesTheLedgerUnchanged() public {
    uint256 tokenId = _mint(alice, alice);

    vm.prank(alice);
    nft.transferFrom(alice, alice, tokenId);

    assertEq(nft.ownerOf(tokenId), alice, "still owned");
    assertEq(nft.balanceOf(alice), 1, "a self transfer must not double-count or zero the balance");
  }

  // ---------------------------------------------------------------------------------------------
  // ERC-20 projects MUD
  // ---------------------------------------------------------------------------------------------

  function testManaBalanceProjectsTheEntityLedger() public {
    (uint256 tokenId, address account) = _mintAndAccount(alice);
    bytes32 entity = IWorld(worldAddress).app__crystalEntityOf(tokenId);

    vm.prank(account);
    IWorld(worldAddress).app__claimStarterMana();

    assertEq(mana.balanceOf(account), STARTER_MANA, "the facade reads the crystal's mana");
    assertEq(mana.balanceOf(account), ManaBalance.getAmount(entity), "and agrees with the table");
  }

  /// @dev `totalSupply` is the one ERC-20 figure that cannot be read from a per-holder table, so it
  /// is maintained. The faucet issues and levelling burns; nothing else moves it.
  function testTotalSupplyFollowsIssuanceAndBurn() public {
    (, address account) = _mintAndAccount(alice);

    assertEq(mana.totalSupply(), 0, "nothing issued yet");

    vm.prank(account);
    IWorld(worldAddress).app__claimStarterMana();
    assertEq(mana.totalSupply(), STARTER_MANA, "the faucet issues");

    vm.prank(account);
    IWorld(worldAddress).app__levelUp();
    assertEq(mana.totalSupply(), STARTER_MANA - BASE_COST, "levelling burns");
    assertEq(mana.totalSupply(), ManaSupply.getValue(), "and agrees with the table");
  }

  function testManaTransferMovesTheMudLedger() public {
    (, address account) = _mintAndAccount(alice);
    vm.prank(account);
    IWorld(worldAddress).app__claimStarterMana();

    vm.expectEmit(true, true, false, true, address(mana));
    emit IERC20.Transfer(account, bob, 30 ether);

    vm.prank(account);
    mana.transfer(bob, 30 ether);

    assertEq(mana.balanceOf(account), STARTER_MANA - 30 ether, "debited");
    assertEq(mana.balanceOf(bob), 30 ether, "credited");
    assertEq(mana.totalSupply(), STARTER_MANA, "a transfer is neither issuance nor destruction");
  }

  function testManaTransferRevertsOnInsufficientBalance() public {
    (, address account) = _mintAndAccount(alice);
    vm.prank(account);
    IWorld(worldAddress).app__claimStarterMana();

    vm.prank(account);
    vm.expectRevert(
      abi.encodeWithSelector(
        ITokenBridgeSystem.TokenBridge_InsufficientMana.selector,
        account,
        uint256(STARTER_MANA),
        uint256(STARTER_MANA) + 1
      )
    );
    mana.transfer(bob, uint256(STARTER_MANA) + 1);
  }

  /// @dev Allowances live in the facade; the ledger move still goes through MUD.
  function testApproveAndTransferFrom() public {
    (, address account) = _mintAndAccount(alice);
    vm.prank(account);
    IWorld(worldAddress).app__claimStarterMana();

    vm.prank(account);
    mana.approve(carol, 40 ether);

    vm.prank(carol);
    mana.transferFrom(account, bob, 40 ether);

    assertEq(mana.balanceOf(bob), 40 ether, "moved by the spender");
    assertEq(mana.allowance(account, carol), 0, "allowance consumed");
  }

  /**
   * @dev Security note 5 on the bridge: a non-crystal address may HOLD mana — otherwise this would
   * not be a real ERC-20 — but it can never USE it. Every game action independently requires a
   * crystal at the caller's entity, so wrapping mana is not a way around the identity model.
   */
  function testManaHeldByANonCrystalAddressCannotBeUsedInGame() public {
    (, address account) = _mintAndAccount(alice);
    vm.prank(account);
    IWorld(worldAddress).app__claimStarterMana();

    vm.prank(account);
    mana.transfer(bob, 50 ether);
    assertEq(mana.balanceOf(bob), 50 ether, "bob really holds mana");

    // ...but bob is not a crystal, so none of the game entry points accept him.
    bytes32 bobEntity = bytes32(uint256(uint160(bob)));

    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(IArenaSystem.ArenaSystem_UnknownCrystal.selector, bobEntity));
    IWorld(worldAddress).app__createLobby(keccak256("nope"), 10 ether, keccak256("c"));

    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(IProgressionSystem.Progression_UnknownCrystal.selector, bobEntity));
    IWorld(worldAddress).app__levelUp();
  }

  // ---------------------------------------------------------------------------------------------
  // The bridge is facade-only
  // ---------------------------------------------------------------------------------------------

  /// @dev The property that makes ownership single-sourced: there is no MUD-side mint that could
  /// create a crystal without an ERC-721 `Transfer` to announce it.
  function testMintingDirectlyOnTheSystemIsRejected() public {
    vm.deal(alice, MINT_PRICE);
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ICrystalForgeSystem.CrystalForge_NotTheCrystalFacade.selector, alice));
    IWorld(worldAddress).app__mintCrystal{ value: MINT_PRICE }(bob);
  }

  function testTransferringCrystalsDirectlyOnTheSystemIsRejected() public {
    uint256 tokenId = _mint(alice, alice);

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ITokenBridgeSystem.TokenBridge_NotTheCrystalFacade.selector, alice));
    IWorld(worldAddress).app__transferCrystal(alice, bob, tokenId);
  }

  function testTransferringManaDirectlyOnTheSystemIsRejected() public {
    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(ITokenBridgeSystem.TokenBridge_NotTheManaFacade.selector, alice));
    IWorld(worldAddress).app__transferMana(alice, bob, 1 ether);
  }

  /// @dev Each facade is checked against ITS OWN slot, so registering both does not make them
  /// interchangeable: the mana token must not be able to move crystals.
  function testOneFacadeCannotActAsTheOther() public {
    uint256 tokenId = _mint(alice, alice);

    vm.prank(address(mana));
    vm.expectRevert(
      abi.encodeWithSelector(ITokenBridgeSystem.TokenBridge_NotTheCrystalFacade.selector, address(mana))
    );
    IWorld(worldAddress).app__transferCrystal(alice, bob, tokenId);

    vm.prank(address(nft));
    vm.expectRevert(abi.encodeWithSelector(ITokenBridgeSystem.TokenBridge_NotTheManaFacade.selector, address(nft)));
    IWorld(worldAddress).app__transferMana(alice, bob, 1 ether);
  }

  /// @dev The bridge re-verifies the ledger even though the facade already authorised the caller:
  /// the facade knows about approvals, only MUD knows who actually owns the crystal.
  function testTheBridgeRejectsAWrongFromEvenFromTheFacade() public {
    uint256 tokenId = _mint(alice, alice);

    vm.prank(address(nft));
    vm.expectRevert(
      abi.encodeWithSelector(ITokenBridgeSystem.TokenBridge_WrongOwner.selector, tokenId, carol, alice)
    );
    IWorld(worldAddress).app__transferCrystal(carol, bob, tokenId);
  }

  function testSetTokenFacadesRequiresTheNamespaceOwner() public {
    vm.prank(stranger);
    vm.expectPartialRevert(IWorldErrors.World_AccessDenied.selector);
    IWorld(worldAddress).app__setTokenFacades(address(nft), address(mana));
  }

  // ---------------------------------------------------------------------------------------------
  // Synchronisation
  // ---------------------------------------------------------------------------------------------

  /**
   * @dev The question this phase has to answer: after a realistic sequence of mints and transfers,
   * does the ERC-721 view still agree with MUD on every token and every balance?
   *
   * Both `CrystalOwner` (authoritative) and `CrystalBalance` (derived) are checked, because the
   * derived counter is the one that could drift without anything reverting.
   */
  function testFacadeAndWorldStayInSyncAcrossAMintAndTransferSequence() public {
    uint256[] memory tokens = new uint256[](6);
    address[] memory expectedOwners = new address[](6);

    for (uint256 i = 0; i < 3; i++) {
      tokens[i] = _mint(alice, alice);
      expectedOwners[i] = alice;
    }
    for (uint256 i = 3; i < 6; i++) {
      tokens[i] = _mint(bob, bob);
      expectedOwners[i] = bob;
    }

    // A few moves, including one that hands a crystal on twice.
    vm.prank(alice);
    nft.transferFrom(alice, bob, tokens[0]);
    expectedOwners[0] = bob;

    vm.prank(bob);
    nft.transferFrom(bob, carol, tokens[0]);
    expectedOwners[0] = carol;

    vm.prank(bob);
    nft.transferFrom(bob, alice, tokens[4]);
    expectedOwners[4] = alice;

    vm.prank(alice);
    nft.transferFrom(alice, alice, tokens[1]); // self transfer

    uint256 aliceCount;
    uint256 bobCount;
    uint256 carolCount;

    for (uint256 i = 0; i < tokens.length; i++) {
      bytes32 entity = IWorld(worldAddress).app__crystalEntityOf(tokens[i]);

      assertEq(nft.ownerOf(tokens[i]), expectedOwners[i], "facade owner");
      assertEq(CrystalOwner.getOwner(entity), expectedOwners[i], "MUD owner");
      assertEq(CrystalData.getLevel(entity), 1, "the crystal itself is untouched by ownership moves");

      if (expectedOwners[i] == alice) aliceCount++;
      else if (expectedOwners[i] == bob) bobCount++;
      else if (expectedOwners[i] == carol) carolCount++;
    }

    assertEq(nft.balanceOf(alice), aliceCount, "alice: derived counter matches reality");
    assertEq(nft.balanceOf(bob), bobCount, "bob: derived counter matches reality");
    assertEq(nft.balanceOf(carol), carolCount, "carol: derived counter matches reality");
    assertEq(aliceCount + bobCount + carolCount, tokens.length, "no crystal lost or duplicated");
  }

  /// @dev Same question for mana: after issuance, burn and transfers, does `totalSupply` still equal
  /// what the holders actually hold?
  function testManaSupplyEqualsTheSumOfHoldings() public {
    (, address first) = _mintAndAccount(alice);
    (, address second) = _mintAndAccount(bob);

    vm.prank(first);
    IWorld(worldAddress).app__claimStarterMana();
    vm.prank(second);
    IWorld(worldAddress).app__claimStarterMana();

    vm.prank(first);
    IWorld(worldAddress).app__levelUp(); // burns 50

    vm.prank(first);
    mana.transfer(carol, 20 ether);
    vm.prank(second);
    mana.transfer(first, 10 ether);

    uint256 held = mana.balanceOf(first) + mana.balanceOf(second) + mana.balanceOf(carol);
    assertEq(mana.totalSupply(), held, "supply must equal the sum of every holding");
    assertEq(mana.totalSupply(), 2 * uint256(STARTER_MANA) - BASE_COST, "issued twice, burned once");
  }

  // ---------------------------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------------------------

  function _mint(address payer, address to) internal returns (uint256 tokenId) {
    vm.deal(payer, MINT_PRICE);
    vm.prank(payer);
    tokenId = nft.mint{ value: MINT_PRICE }(to);
  }

  /// @dev Returns the token id and the crystal's token bound account — the address that must act
  /// for it in game.
  function _mintAndAccount(address owner) internal returns (uint256 tokenId, address account) {
    tokenId = _mint(owner, owner);
    account = IWorld(worldAddress).app__crystalAccountOf(tokenId);
  }
}
