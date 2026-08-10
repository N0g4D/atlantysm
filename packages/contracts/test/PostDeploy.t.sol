// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import { MudTest } from "@latticexyz/world/test/MudTest.t.sol";

import { IWorld } from "../src/codegen/world/IWorld.sol";
import { ICrystalForgeSystem } from "../src/codegen/world/ICrystalForgeSystem.sol";
import { CrystalNFT } from "../src/tokens/CrystalNFT.sol";
import { ManaToken } from "../src/tokens/ManaToken.sol";
import { DevERC6551Registry } from "../src/dev/DevERC6551Registry.sol";
import { CrystalData, CrystalOwner, ForgeConfig, ManaBalance } from "../src/codegen/index.sol";
import { Element } from "../src/codegen/common.sol";
import { PostDeploy } from "../script/PostDeploy.s.sol";

/**
 * @dev Verifies the state `PostDeploy` actually leaves behind.
 *
 * The distinguishing rule of this file: it configures NOTHING. Every other test suite calls
 * `configureForge` / `setTokenFacades` / `setMintPrice` in its own `setUp`, which means they would
 * all still pass against a World where `PostDeploy` did nothing at all — exactly the state phase 7
 * shipped and flagged as unplayable. Here the only setup is `vm.deal`, so a regression in the
 * deployment script has nowhere to hide.
 */
contract PostDeployTest is MudTest {
  address internal player = address(0xF1A4E5);

  CrystalNFT internal nft;
  ManaToken internal mana;

  uint256 internal constant EXPECTED_MINT_PRICE = 0.01 ether;
  uint128 internal constant STARTER_MANA = 100 ether;
  uint128 internal constant BASE_COST = 50 ether;

  function setUp() public override {
    super.setUp();

    // Read the wiring rather than creating it.
    (address nftAddress, address manaAddress) = IWorld(worldAddress).app__tokenFacades();
    nft = CrystalNFT(nftAddress);
    mana = ManaToken(manaAddress);
  }

  // ---------------------------------------------------------------------------------------------
  // What the script wired
  // ---------------------------------------------------------------------------------------------

  function testDeployRegistersBothFacades() public view {
    assertTrue(address(nft) != address(0), "the NFT facade must be registered");
    assertTrue(address(mana) != address(0), "the mana facade must be registered");
    assertTrue(address(nft).code.length > 0, "and actually deployed");
    assertTrue(address(mana).code.length > 0, "and actually deployed");
    assertEq(address(nft.world()), worldAddress, "the NFT points at this World");
    assertEq(address(mana.world()), worldAddress, "so does the token");
  }

  function testDeployConfiguresTheForge() public view {
    (address registry, address implementation, address tokenContract, ) = IWorld(worldAddress).app__forgeConfig();

    assertTrue(registry != address(0), "registry set");
    assertTrue(implementation != address(0), "implementation set");
    assertTrue(registry.code.length > 0, "the registry is a real contract on this chain");

    // The ERC-6551 token contract must be the NFT that actually owns the ids, not a placeholder.
    assertEq(tokenContract, address(nft), "identity is bound to the deployed NFT");
  }

  function testDeploySetsAMintPrice() public view {
    (bool configured, uint256 price) = IWorld(worldAddress).app__mintPrice();

    assertTrue(configured, "an unpriced forge cannot mint at all");
    assertEq(price, EXPECTED_MINT_PRICE, "default dev price");
  }

  /**
   * @dev Cross-check between the two independent implementations of the same derivation: the
   * registry `PostDeploy` deployed computes an account address by hashing creation code, and
   * `CrystalIdentityLib` predicts it separately. If the script had wired a registry whose creation
   * code differs from the library's, every entity would be derived against the wrong address — and
   * `configureForge` freezes at the first mint, so it would be unrecoverable.
   */
  function testTheWiredRegistryAgreesWithTheGamesDerivation() public {
    uint256 tokenId = _mint(player);

    (address registry, address implementation, address tokenContract, bytes32 salt) = IWorld(worldAddress)
      .app__forgeConfig();

    address fromRegistry = DevERC6551Registry(registry).account(
      implementation,
      salt,
      block.chainid,
      tokenContract,
      tokenId
    );

    assertEq(
      fromRegistry,
      IWorld(worldAddress).app__crystalAccountOf(tokenId),
      "the wired registry and the game must derive the same account"
    );
  }

  /**
   * @dev The production guard, and the most consequential line in the script. `configureForge`
   * freezes at the first mint, so writing throwaway dev addresses into it on a real network would
   * bind every crystal ever minted to an implementation that does not exist — unrecoverable.
   *
   * On anything but anvil the script must therefore REFUSE to invent them. Failing the deploy is
   * the cheap outcome; noticing after the first mint is the expensive one.
   */
  function testDeployRefusesToInventIdentityInputsOffTheDevChain() public {
    // Undo the wiring so the script takes its configuring branch rather than the reuse branch.
    vm.prank(vm.addr(vm.envUint("PRIVATE_KEY")));
    ForgeConfig.set(address(0), address(0), address(0), bytes32(0));

    vm.chainId(8453);

    PostDeploy script = new PostDeploy();
    vm.expectRevert(abi.encodeWithSelector(PostDeploy.PostDeploy_MissingIdentityConfig.selector, uint256(8453)));
    script.run(worldAddress);
  }

  // ---------------------------------------------------------------------------------------------
  // Playable straight from deploy
  // ---------------------------------------------------------------------------------------------

  /**
   * @dev The actual acceptance criterion for this phase: a fresh `pnpm dev` yields a World a player
   * can use, with no administrative step in between. Mint, fund, grow, fight — all from the state
   * the script left.
   */
  function testTheGameIsPlayableStraightFromDeploy() public {
    // 1. Forge a crystal through the ERC-721, paying the configured price.
    uint256 tokenId = _mint(player);
    address account = IWorld(worldAddress).app__crystalAccountOf(tokenId);
    bytes32 entity = IWorld(worldAddress).app__crystalEntityOf(tokenId);

    assertEq(nft.ownerOf(tokenId), player, "the player owns it");
    assertEq(nft.balanceOf(player), 1, "and the ERC-721 balance agrees");
    assertEq(CrystalData.getLevel(entity), 1, "born at level 1");

    // 2. The crystal funds itself.
    vm.prank(account);
    IWorld(worldAddress).app__claimStarterMana();
    assertEq(mana.balanceOf(account), STARTER_MANA, "the faucet is reachable");
    assertEq(mana.totalSupply(), STARTER_MANA, "supply tracked");

    // 3. It grows.
    vm.prank(account);
    assertEq(IWorld(worldAddress).app__levelUp(), 2, "levelling works");
    assertEq(mana.balanceOf(account), STARTER_MANA - BASE_COST, "and costs mana");

    // 4. It can enter the arena.
    vm.prank(account);
    bytes32 lobbyId = IWorld(worldAddress).app__createLobby(
      keccak256("first-blood"),
      10 ether,
      _commit(keccak256(abi.encode(entity, keccak256("first-blood"))), entity, Element.Fire, "s")
    );
    assertTrue(lobbyId != bytes32(0), "and the arena accepts it");
  }

  /// @dev The mint gate the script configured is real, not decorative.
  function testTheConfiguredPriceIsEnforced() public {
    vm.deal(player, 1 ether);
    vm.prank(player);
    vm.expectRevert(
      abi.encodeWithSelector(
        ICrystalForgeSystem.CrystalForge_IncorrectPayment.selector,
        EXPECTED_MINT_PRICE,
        EXPECTED_MINT_PRICE + 1 wei
      )
    );
    nft.mint{ value: EXPECTED_MINT_PRICE + 1 wei }(player);
  }

  /// @dev The revenue path phase 6 established still works on a deployed World.
  function testMintRevenueAccruesToTheNamespace() public {
    uint256 before = IWorld(worldAddress).app__mintRevenue();

    _mint(player);
    _mint(player);

    assertEq(IWorld(worldAddress).app__mintRevenue() - before, 2 * EXPECTED_MINT_PRICE, "collected");
  }

  // ---------------------------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------------------------

  function _mint(address to) internal returns (uint256 tokenId) {
    vm.deal(to, EXPECTED_MINT_PRICE);
    vm.prank(to);
    tokenId = nft.mint{ value: EXPECTED_MINT_PRICE }(to);
  }

  /// @dev Mirrors `ArenaSystem._commitmentOf` (phase 3.6 binding).
  function _commit(bytes32 lobbyId, bytes32 playerEntity, Element move, bytes32 salt) internal pure returns (bytes32) {
    return keccak256(abi.encodePacked(lobbyId, playerEntity, move, salt));
  }
}
