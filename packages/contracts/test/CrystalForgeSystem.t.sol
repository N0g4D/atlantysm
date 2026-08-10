// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import { MudTest } from "@latticexyz/world/test/MudTest.t.sol";
import { IWorldErrors } from "@latticexyz/world/src/IWorldErrors.sol";
import { WorldResourceIdLib } from "@latticexyz/world/src/WorldResourceId.sol";
import { ResourceId } from "@latticexyz/store/src/ResourceId.sol";

import { IWorld } from "../src/codegen/world/IWorld.sol";
import { IArenaSystem } from "../src/codegen/world/IArenaSystem.sol";
import { ICrystalForgeSystem } from "../src/codegen/world/ICrystalForgeSystem.sol";
// Worldgen exposes errors but not events, so the event test references the System directly; a
// signature change then breaks compilation instead of asserting a stale shape.
import { CrystalForgeSystem } from "../src/systems/CrystalForgeSystem.sol";
import { CrystalData, CrystalOwner, ForgeConfig, ManaBalance } from "../src/codegen/index.sol";
import { Element } from "../src/codegen/common.sol";

/**
 * @dev Independent ERC-6551 registry, reduced to the one thing worth testing: it CREATE2-deploys an
 * account and lets the EVM — not our arithmetic — decide where it lands.
 *
 * This is what makes `testEntityMatchesTheDeployedTokenBoundAccount` a real proof rather than a
 * restatement. The System computes the address by hashing; this contract computes it by actually
 * deploying. If the System's CREATE2 preimage were wrong in any way — operand order, salt choice,
 * the 0xff prefix — the deployment would land somewhere else and the assertion would fail.
 */
contract ReferenceERC6551Registry {
  error DeploymentFailed();

  function createAccount(
    address implementation,
    bytes32 salt,
    uint256 chainId,
    address tokenContract,
    uint256 tokenId
  ) external returns (address deployed) {
    bytes memory code = abi.encodePacked(
      hex"3d60ad80600a3d3981f3363d3d373d3d3d363d73",
      implementation,
      hex"5af43d82803e903d91602b57fd5bf3",
      abi.encode(salt, chainId, tokenContract, tokenId)
    );

    assembly {
      deployed := create2(0, add(code, 0x20), mload(code), salt)
    }
    if (deployed == address(0)) revert DeploymentFailed();
  }
}

/// @dev Stand-in for the ERC-6551 account implementation. The proxy never calls it at construction,
/// so it only has to exist.
contract MockAccount {
  function isAccount() external pure returns (bool) {
    return true;
  }
}

contract CrystalForgeSystemTest is MudTest {
  address internal alice = address(0xA11CE);
  address internal bob = address(0xB0B);
  address internal stranger = address(0x57A2);

  /// @dev Owner of the `app` namespace.
  address internal deployer;

  ReferenceERC6551Registry internal registry;
  address internal accountImplementation;
  address internal constant TOKEN_CONTRACT = address(0x7075E7);
  bytes32 internal constant ACCOUNT_SALT = bytes32(uint256(0xA71A));
  uint256 internal constant MINT_PRICE = 0.01 ether;

  function setUp() public override {
    super.setUp();

    deployer = vm.addr(vm.envUint("PRIVATE_KEY"));
    registry = new ReferenceERC6551Registry();
    accountImplementation = address(new MockAccount());
  }

  // ---------------------------------------------------------------------------------------------
  // The level-1 invariant
  // ---------------------------------------------------------------------------------------------

  /**
   * @dev The invariant `ArenaSystem._requireCrystal` depends on: it reads `level == 0` as "no such
   * crystal", so a crystal minted at level 0 would exist and simultaneously not exist.
   */
  function testMintCreatesCrystalAtLevelOne() public {
    _configureForge();

    (bytes32 entity, uint256 tokenId) = _mint(alice, bob);

    assertEq(CrystalData.getLevel(entity), 1, "every crystal is born at level 1");
    assertEq(CrystalData.getTokenId(entity), tokenId, "tokenId persisted on the entity");
    assertEq(CrystalOwner.getOwner(entity), bob, "owner recorded");
  }

  /// @dev The invariant must hold for every crystal, not just the first.
  function testEveryCrystalIsBornAtLevelOne() public {
    _configureForge();

    for (uint256 i = 0; i < 25; i++) {
      (bytes32 entity, ) = _mint(alice, bob);
      assertEq(CrystalData.getLevel(entity), 1, "level 1 must hold for every mint");
    }
  }

  // ---------------------------------------------------------------------------------------------
  // Token id uniqueness
  // ---------------------------------------------------------------------------------------------

  /**
   * @dev Worst case on purpose: same block, same sender, same recipient. Every input to the
   * preimage except the nonce is identical across all 32 mints, so this fails outright if the nonce
   * is ever dropped from the derivation.
   */
  function testTokenIdsAreUniqueUnderIdenticalInputs() public {
    _configureForge();

    uint256 count = 32;
    uint256[] memory tokenIds = new uint256[](count);
    bytes32[] memory entities = new bytes32[](count);

    for (uint256 i = 0; i < count; i++) {
      (entities[i], tokenIds[i]) = _mint(alice, bob);
    }

    for (uint256 i = 0; i < count; i++) {
      assertTrue(tokenIds[i] != 0, "a zero token id would collide with unset state");
      for (uint256 j = i + 1; j < count; j++) {
        assertTrue(tokenIds[i] != tokenIds[j], "token ids must be unique");
        assertTrue(entities[i] != entities[j], "entities must be unique");
      }
    }
  }

  /**
   * @dev The specific collision the nonce exists to prevent. Two mints in one block with identical
   * sender and recipient would otherwise share their entire preimage and derive the same id — a
   * failure reachable by one batched transaction, not by a hash collision.
   */
  function testTwoMintsInTheSameBlockDoNotCollide() public {
    _configureForge();

    uint256 timestampBefore = block.timestamp;
    (bytes32 firstEntity, uint256 firstId) = _mint(alice, bob);
    (bytes32 secondEntity, uint256 secondId) = _mint(alice, bob);

    assertEq(block.timestamp, timestampBefore, "the test is only meaningful within one block");
    assertTrue(firstId != secondId, "same-block mints must not share a token id");
    assertTrue(firstEntity != secondEntity, "same-block mints must not share an entity");
  }

  // ---------------------------------------------------------------------------------------------
  // ERC-6551 identity
  // ---------------------------------------------------------------------------------------------

  /**
   * @dev The load-bearing test of this phase. The System derives the account by hashing; here the
   * EVM derives it by actually CREATE2-deploying one. The two must agree, or every crystal is
   * keyed at an address that will never be its account.
   */
  function testEntityMatchesTheDeployedTokenBoundAccount() public {
    _configureForge();

    (bytes32 entity, uint256 tokenId) = _mint(alice, bob);

    address predicted = IWorld(worldAddress).app__crystalAccountOf(tokenId);
    address deployed = registry.createAccount(
      accountImplementation,
      ACCOUNT_SALT,
      block.chainid,
      TOKEN_CONTRACT,
      tokenId
    );

    assertEq(deployed, predicted, "the derived address must be where the account actually deploys");
    assertEq(entity, bytes32(uint256(uint160(deployed))), "the entity is that account, widened");
    assertTrue(deployed.code.length > 0, "the account must really have been deployed");
  }

  /// @dev The views must agree with what minting wrote, otherwise the ERC-721 facade would resolve
  /// identity differently from the forge.
  function testViewsAgreeWithMintedState() public {
    _configureForge();

    (bytes32 entity, uint256 tokenId) = _mint(alice, bob);

    assertEq(IWorld(worldAddress).app__crystalEntityOf(tokenId), entity, "entity view");
    assertEq(
      IWorld(worldAddress).app__crystalAccountOf(tokenId),
      address(uint160(uint256(entity))),
      "account view"
    );
  }

  /**
   * @dev The forge/fight split: a human owns, a token bound account fights. The two addresses must
   * be different, or the identity model has collapsed back into "the owner is the crystal".
   */
  function testOwnerAndEntityAreDifferentIdentities() public {
    _configureForge();

    (bytes32 entity, ) = _mint(alice, bob);

    assertEq(CrystalOwner.getOwner(entity), bob, "the human owns");
    assertTrue(entity != bytes32(uint256(uint160(bob))), "the owner must not be the entity");
    assertTrue(entity != bytes32(uint256(uint160(alice))), "nor the minter");
  }

  /// @dev Two crystals for the same owner must still be two distinct entities: ownership is
  /// many-to-one, identity is not.
  function testOneOwnerCanHoldSeveralCrystals() public {
    _configureForge();

    (bytes32 first, ) = _mint(alice, bob);
    (bytes32 second, ) = _mint(alice, bob);

    assertTrue(first != second, "distinct entities");
    assertEq(CrystalOwner.getOwner(first), bob);
    assertEq(CrystalOwner.getOwner(second), bob);
  }

  // ---------------------------------------------------------------------------------------------
  // Integration with ArenaSystem
  // ---------------------------------------------------------------------------------------------

  /**
   * @dev End-to-end proof that the identity model actually closes: a freshly forged crystal, once
   * funded, can open a lobby under its own account. This is what would break if `_entityOf` ever
   * diverged between the two Systems, or if minting wrote at anything other than the account.
   */
  function testForgedCrystalCanEnterTheArena() public {
    _configureForge();

    (bytes32 entity, uint256 tokenId) = _mint(alice, bob);
    address account = IWorld(worldAddress).app__crystalAccountOf(tokenId);

    // Mana distribution has no System yet, so it is seeded as the namespace owner.
    vm.prank(deployer);
    ManaBalance.setAmount(entity, 100 ether);

    // The crystal fights, not its owner: the call comes from the token bound account.
    vm.prank(account);
    bytes32 lobbyId = IWorld(worldAddress).app__createLobby(
      keccak256("forged-lobby"),
      10 ether,
      keccak256("commitment")
    );

    assertTrue(lobbyId != bytes32(0), "a forged crystal must be able to open a lobby");
    assertEq(ManaBalance.getAmount(entity), 90 ether, "the wager is escrowed from the crystal");
  }

  /// @dev The mirror case: the OWNER cannot fight, because it is not a crystal. This is what stops
  /// the identity model from silently degrading back to owner-as-entity.
  function testOwnerCannotFightOnTheCrystalsBehalf() public {
    _configureForge();

    _mint(alice, bob);

    vm.prank(bob);
    vm.expectRevert(
      abi.encodeWithSelector(IArenaSystem.ArenaSystem_UnknownCrystal.selector, bytes32(uint256(uint160(bob))))
    );
    IWorld(worldAddress).app__createLobby(keccak256("owner-lobby"), 10 ether, keccak256("commitment"));
  }

  // ---------------------------------------------------------------------------------------------
  // Guards
  // ---------------------------------------------------------------------------------------------

  function testMintRevertsOnZeroRecipient() public {
    _configureForge();

    vm.prank(alice);
    vm.expectRevert(ICrystalForgeSystem.CrystalForge_ZeroRecipient.selector);
    IWorld(worldAddress).app__mintCrystal(address(0));
  }

  /// @dev Security note 2 in the System: minting before the account inputs are known would strand
  /// every crystal at an address that can never be its account. The price is set first so the
  /// payment gate passes and this isolates the ForgeConfig gate.
  function testMintRevertsWhenNotConfigured() public {
    _setMintPrice(MINT_PRICE);

    vm.deal(alice, MINT_PRICE);
    vm.prank(alice);
    vm.expectRevert(ICrystalForgeSystem.CrystalForge_NotConfigured.selector);
    IWorld(worldAddress).app__mintCrystal{ value: MINT_PRICE }(bob);
  }

  /// @dev Partial match on purpose: the error carries MUD's own formatted resource string, which is
  /// an internal detail this test has no business pinning.
  function testConfigureRevertsForNonNamespaceOwner() public {
    vm.prank(stranger);
    vm.expectPartialRevert(IWorldErrors.World_AccessDenied.selector);
    IWorld(worldAddress).app__configureForge(address(registry), accountImplementation, TOKEN_CONTRACT, ACCOUNT_SALT);
  }

  function testConfigureRevertsOnZeroAddresses() public {
    vm.prank(deployer);
    vm.expectRevert(ICrystalForgeSystem.CrystalForge_InvalidConfig.selector);
    IWorld(worldAddress).app__configureForge(address(0), accountImplementation, TOKEN_CONTRACT, ACCOUNT_SALT);
  }

  /**
   * @dev The freeze that turns an unrecoverable, silent corruption into a loud revert: re-deriving
   * accounts after crystals exist would orphan all of them at once.
   */
  function testConfigureRevertsAfterTheFirstMint() public {
    _configureForge();
    _mint(alice, bob);

    vm.prank(deployer);
    vm.expectRevert(abi.encodeWithSelector(ICrystalForgeSystem.CrystalForge_AlreadyMinted.selector, 1));
    IWorld(worldAddress).app__configureForge(address(registry), accountImplementation, TOKEN_CONTRACT, ACCOUNT_SALT);
  }

  function testConfigurePersistsEveryField() public {
    _configureForge();

    assertEq(ForgeConfig.getAccountRegistry(), address(registry), "registry");
    assertEq(ForgeConfig.getAccountImplementation(), accountImplementation, "implementation");
    assertEq(ForgeConfig.getTokenContract(), TOKEN_CONTRACT, "token contract");
    assertEq(ForgeConfig.getAccountSalt(), ACCOUNT_SALT, "salt");
  }

  // ---------------------------------------------------------------------------------------------
  // ETH gating (the sybil gate)
  // ---------------------------------------------------------------------------------------------

  /// @dev The sentinel earning its keep: an unset price must block minting outright, not silently
  /// mean "free". A deployment that forgot to price the forge is the failure mode being prevented.
  function testMintRevertsWhenNoPriceHasBeenSet() public {
    vm.prank(deployer);
    IWorld(worldAddress).app__configureForge(address(registry), accountImplementation, TOKEN_CONTRACT, ACCOUNT_SALT);

    vm.deal(alice, 1 ether);
    vm.prank(alice);
    vm.expectRevert(ICrystalForgeSystem.CrystalForge_MintPriceNotConfigured.selector);
    IWorld(worldAddress).app__mintCrystal{ value: 1 ether }(bob);
  }

  function testMintRevertsOnUnderpayment() public {
    _configureForge();

    vm.deal(alice, MINT_PRICE);
    vm.prank(alice);
    vm.expectRevert(
      abi.encodeWithSelector(
        ICrystalForgeSystem.CrystalForge_IncorrectPayment.selector,
        MINT_PRICE,
        MINT_PRICE - 1 wei
      )
    );
    IWorld(worldAddress).app__mintCrystal{ value: MINT_PRICE - 1 wei }(bob);
  }

  /// @dev Overpaying reverts too. Returning change would mean sending ETH back mid-mint — a
  /// reentrancy surface bought for nothing, since the price is readable before calling.
  function testMintRevertsOnOverpaymentRatherThanRefunding() public {
    _configureForge();

    vm.deal(alice, MINT_PRICE + 1 wei);
    vm.prank(alice);
    vm.expectRevert(
      abi.encodeWithSelector(
        ICrystalForgeSystem.CrystalForge_IncorrectPayment.selector,
        MINT_PRICE,
        MINT_PRICE + 1 wei
      )
    );
    IWorld(worldAddress).app__mintCrystal{ value: MINT_PRICE + 1 wei }(bob);
  }

  function testMintRevertsWithNoPaymentAtAll() public {
    _configureForge();

    vm.prank(alice);
    vm.expectRevert(
      abi.encodeWithSelector(ICrystalForgeSystem.CrystalForge_IncorrectPayment.selector, MINT_PRICE, 0)
    );
    IWorld(worldAddress).app__mintCrystal(bob);
  }

  /// @dev A genuinely free mint stays expressible — that is the whole point of separating
  /// "configured" from "price". Testnets need it; silence must not provide it.
  function testAFreeMintIsExpressibleButMustBeDeliberate() public {
    _configureForge();
    _setMintPrice(0);

    vm.prank(alice);
    (bytes32 entity, ) = IWorld(worldAddress).app__mintCrystal(bob);

    assertEq(CrystalData.getLevel(entity), 1, "free mint still forges a real crystal");
    assertEq(IWorld(worldAddress).app__mintRevenue(), 0, "and collects nothing");
  }

  /**
   * @dev The finding this phase turned on: MUD credits the ETH to the namespace balance INSIDE the
   * World and calls the System with `call{value: 0}`. So the revenue is held by the World, and the
   * System's own balance is permanently zero — which is why `withdrawETH` over
   * `address(this).balance` would have transferred nothing.
   */
  function testRevenueAccruesToTheWorldNotToTheSystem() public {
    _configureForge();

    uint256 worldBefore = worldAddress.balance;

    _mint(alice, bob);
    _mint(alice, bob);
    _mint(alice, bob);

    assertEq(IWorld(worldAddress).app__mintRevenue(), 3 * MINT_PRICE, "revenue tracked per namespace");
    assertEq(worldAddress.balance - worldBefore, 3 * MINT_PRICE, "the ETH itself sits in the World");
  }

  /// @dev Withdrawal is MUD's own `transferBalanceToAddress`, gated on namespace access.
  function testAdminCanWithdrawTheRevenue() public {
    _configureForge();
    _mint(alice, bob);
    _mint(alice, bob);

    uint256 collected = 2 * MINT_PRICE;
    assertEq(IWorld(worldAddress).app__mintRevenue(), collected, "collected");

    address treasury = address(0x7BEA5);
    uint256 treasuryBefore = treasury.balance;

    vm.prank(deployer);
    IWorld(worldAddress).transferBalanceToAddress(_namespaceId(), treasury, collected);

    assertEq(treasury.balance - treasuryBefore, collected, "the admin really receives the ETH");
    assertEq(IWorld(worldAddress).app__mintRevenue(), 0, "namespace balance drained");
  }

  function testNonAdminCannotWithdrawTheRevenue() public {
    _configureForge();
    _mint(alice, bob);

    vm.prank(stranger);
    vm.expectPartialRevert(IWorldErrors.World_AccessDenied.selector);
    IWorld(worldAddress).transferBalanceToAddress(_namespaceId(), stranger, MINT_PRICE);

    assertEq(IWorld(worldAddress).app__mintRevenue(), MINT_PRICE, "revenue untouched");
  }

  function testWithdrawingMoreThanCollectedReverts() public {
    _configureForge();
    _mint(alice, bob);

    vm.prank(deployer);
    vm.expectPartialRevert(IWorldErrors.World_InsufficientBalance.selector);
    IWorld(worldAddress).transferBalanceToAddress(_namespaceId(), deployer, MINT_PRICE + 1 wei);
  }

  function testSetMintPriceRequiresTheNamespaceOwner() public {
    vm.prank(stranger);
    vm.expectPartialRevert(IWorldErrors.World_AccessDenied.selector);
    IWorld(worldAddress).app__setMintPrice(1 ether);
  }

  /**
   * @dev The deliberate asymmetry with `configureForge`, which freezes on the first mint: identity
   * derivation is permanent, but a price is an economic lever and must stay tunable forever.
   */
  function testMintPriceStaysTunableAfterTheFirstMintUnlikeForgeConfig() public {
    _configureForge();
    _mint(alice, bob);

    _setMintPrice(1 ether);
    (bool configured, uint256 price) = IWorld(worldAddress).app__mintPrice();
    assertTrue(configured, "still configured");
    assertEq(price, 1 ether, "price moved");

    // ...while the identity config is frozen for good.
    vm.prank(deployer);
    vm.expectRevert(abi.encodeWithSelector(ICrystalForgeSystem.CrystalForge_AlreadyMinted.selector, 1));
    IWorld(worldAddress).app__configureForge(address(registry), accountImplementation, TOKEN_CONTRACT, ACCOUNT_SALT);

    // And the new price is the one enforced.
    vm.deal(alice, 1 ether);
    vm.prank(alice);
    IWorld(worldAddress).app__mintCrystal{ value: 1 ether }(bob);
    assertEq(IWorld(worldAddress).app__mintRevenue(), MINT_PRICE + 1 ether, "both mints collected");
  }

  // ---------------------------------------------------------------------------------------------
  // Event
  // ---------------------------------------------------------------------------------------------

  /// @dev The forge emits the only record an indexer gets of a crystal coming into existence, so
  /// all four arguments are checked exactly.
  function testMintEmitsCrystalForged() public {
    _configureForge();

    // Derived ahead of the call so the expected topics are known: the derivation is deterministic
    // given the nonce, which is 1 for the first mint.
    uint256 expectedTokenId = uint256(
      keccak256(abi.encodePacked(block.timestamp, alice, bob, uint256(1)))
    );
    address expectedAccount = IWorld(worldAddress).app__crystalAccountOf(expectedTokenId);
    bytes32 expectedEntity = bytes32(uint256(uint160(expectedAccount)));

    vm.expectEmit(true, true, true, true);
    emit CrystalForgeSystem.CrystalForged(expectedEntity, expectedTokenId, bob, expectedAccount);

    vm.deal(alice, MINT_PRICE);
    vm.prank(alice);
    IWorld(worldAddress).app__mintCrystal{ value: MINT_PRICE }(bob);
  }

  function testSetMintPriceEmitsMintPriceSet() public {
    vm.expectEmit(false, false, false, true);
    emit CrystalForgeSystem.MintPriceSet(0.05 ether);

    _setMintPrice(0.05 ether);
  }

  // ---------------------------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------------------------

  /// @dev The namespace that owns this System and holds its mint revenue.
  function _namespaceId() internal pure returns (ResourceId) {
    return WorldResourceIdLib.encodeNamespace("app");
  }

  /// @dev Sets the ERC-6551 inputs AND a mint price: since phase 6 a forge with no price cannot
  /// mint at all, so every test that mints needs both.
  function _configureForge() internal {
    vm.prank(deployer);
    IWorld(worldAddress).app__configureForge(address(registry), accountImplementation, TOKEN_CONTRACT, ACCOUNT_SALT);
    _setMintPrice(MINT_PRICE);
  }

  function _setMintPrice(uint256 price) internal {
    vm.prank(deployer);
    IWorld(worldAddress).app__setMintPrice(price);
  }

  function _mint(address minter, address to) internal returns (bytes32 entity, uint256 tokenId) {
    vm.deal(minter, MINT_PRICE);
    vm.prank(minter);
    (entity, tokenId) = IWorld(worldAddress).app__mintCrystal{ value: MINT_PRICE }(to);
  }
}
