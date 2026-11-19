// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import { MudTest } from "@latticexyz/world/test/MudTest.t.sol";

import { IWorld } from "../src/codegen/world/IWorld.sol";
import { ICrystalForgeSystem } from "../src/codegen/world/ICrystalForgeSystem.sol";
import { CrystalNFT } from "../src/tokens/CrystalNFT.sol";
import { ManaToken } from "../src/tokens/ManaToken.sol";
import { DevERC6551Registry } from "../src/dev/DevERC6551Registry.sol";
import { AtlantysmAccount } from "../src/accounts/AtlantysmAccount.sol";
import { CrystalData, CrystalOwner, ForgeConfig, ManaBalance } from "../src/codegen/index.sol";
import { Element } from "../src/codegen/common.sol";
import { PostDeploy } from "../script/PostDeploy.s.sol";

/**
 * @dev Exposes the script's identity decision so every branch can be driven with explicit inputs.
 *
 * The alternative — `vm.setEnv` followed by `run` — mutates process-wide state while forge runs
 * tests in parallel, so one test's variables would leak into another's script run. The script reads
 * the environment in exactly one place and passes the values down, and this is the seam that buys.
 */
contract PostDeployHarness is PostDeploy {
  function resolveIdentityInputs(address registry, address implementation) external returns (address, address) {
    return _resolveIdentityInputs(registry, implementation);
  }
}

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

  /// @dev The canonical ERC-6551 registry (v0.3.1), the value `.env.example` ships. It is a real
  /// contract on Sepolia and on mainnet, and an EMPTY address on a fresh anvil — which is the whole
  /// regression the identity tests below pin.
  address internal constant CANONICAL_REGISTRY = 0x000000006551c19487814612e58FE06813775758;

  /// @dev Stands in for "an address pasted from another network": plausible, non-zero, no code.
  address internal constant ADDRESS_WITH_NO_CODE = address(0xDEAD6551);

  uint256 internal constant NOT_THE_DEV_CHAIN = 8453;

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
    // An implementation with no code is the quieter failure of the two: the registry would still
    // deploy 173-byte proxies, and a proxy that delegatecalls an empty address SUCCEEDS and does
    // nothing — every `callSystem` would report success while no System ever ran.
    assertTrue(implementation.code.length > 0, "and so is the account implementation");

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

    // This is the one test that runs the WHOLE script, so it is the one test that reads the real
    // environment — and a developer's `.env` legitimately carries Sepolia values. Blank both, or
    // the outcome would depend on whose machine this runs on. Safe under parallel execution only
    // because nothing else in the suite reads these two variables: every other identity test goes
    // through `PostDeployHarness` with explicit arguments.
    vm.setEnv("ERC6551_REGISTRY", "");
    vm.setEnv("ERC6551_ACCOUNT_IMPLEMENTATION", "");

    vm.chainId(NOT_THE_DEV_CHAIN);

    PostDeploy script = new PostDeploy();
    vm.expectRevert(abi.encodeWithSelector(PostDeploy.PostDeploy_MissingIdentityConfig.selector, NOT_THE_DEV_CHAIN));
    script.run(worldAddress);
  }

  /// @dev Half a configuration is no configuration: either input missing is refused, whichever it is.
  function testOffTheDevChainBothIdentityInputsAreRequired() public {
    PostDeployHarness script = new PostDeployHarness();
    address registry = address(new DevERC6551Registry());
    address implementation = address(new AtlantysmAccount());

    vm.chainId(NOT_THE_DEV_CHAIN);
    bytes memory missing = abi.encodeWithSelector(
      PostDeploy.PostDeploy_MissingIdentityConfig.selector,
      NOT_THE_DEV_CHAIN
    );

    vm.expectRevert(missing);
    script.resolveIdentityInputs(address(0), address(0));

    vm.expectRevert(missing);
    script.resolveIdentityInputs(registry, address(0));

    vm.expectRevert(missing);
    script.resolveIdentityInputs(address(0), implementation);
  }

  /**
   * @dev A non-zero address is not evidence of a contract. Before this guard, a typo or an address
   * copied from another network passed the "is it set" check and was frozen into `ForgeConfig` at
   * the first mint, exactly as permanently as a placeholder. The error names the variable so the
   * message points at a line of `.env`.
   */
  function testOffTheDevChainAnIdentityInputWithNoCodeIsRefused() public {
    PostDeployHarness script = new PostDeployHarness();
    address registry = address(new DevERC6551Registry());
    address implementation = address(new AtlantysmAccount());

    vm.chainId(NOT_THE_DEV_CHAIN);

    vm.expectRevert(
      abi.encodeWithSelector(
        PostDeploy.PostDeploy_IdentityInputHasNoCode.selector,
        "ERC6551_REGISTRY",
        ADDRESS_WITH_NO_CODE
      )
    );
    script.resolveIdentityInputs(ADDRESS_WITH_NO_CODE, implementation);

    vm.expectRevert(
      abi.encodeWithSelector(
        PostDeploy.PostDeploy_IdentityInputHasNoCode.selector,
        "ERC6551_ACCOUNT_IMPLEMENTATION",
        ADDRESS_WITH_NO_CODE
      )
    );
    script.resolveIdentityInputs(registry, ADDRESS_WITH_NO_CODE);
  }

  /// @dev The production path itself, which phase 8 left "reasoned about, not run": real inputs
  /// are used exactly as given, never swapped for dev deployments.
  function testOffTheDevChainRealIdentityInputsAreUsedAsGiven() public {
    PostDeployHarness script = new PostDeployHarness();
    address registry = address(new DevERC6551Registry());
    address implementation = address(new AtlantysmAccount());

    vm.chainId(NOT_THE_DEV_CHAIN);
    (address resolvedRegistry, address resolvedImplementation) = script.resolveIdentityInputs(registry, implementation);

    assertEq(resolvedRegistry, registry, "the supplied registry is the one that gets frozen");
    assertEq(resolvedImplementation, implementation, "and so is the supplied implementation");
  }

  /**
   * @dev THE REGRESSION. `.env.example` ships the canonical registry address, and one `.env` serves
   * Sepolia and local development alike. On a fresh anvil that address is empty, and the script
   * used to trust it anyway: the World deployed, every mint reverted, and 16 tests failed for
   * anyone who followed the documented setup.
   *
   * On the dev chain an input with no code must be replaced, not believed.
   */
  function testOnTheDevChainAnIdentityInputWithNoCodeIsReplaced() public {
    assertEq(CANONICAL_REGISTRY.code.length, 0, "precondition: the canonical registry is absent on a fresh anvil");

    PostDeployHarness script = new PostDeployHarness();

    // Exactly what `cp .env.example .env` produces: registry filled in, implementation blank.
    (address registry, address implementation) = script.resolveIdentityInputs(CANONICAL_REGISTRY, address(0));
    assertTrue(registry != CANONICAL_REGISTRY, "an empty address must not be wired as the registry");
    assertTrue(registry.code.length > 0, "a dev registry is deployed in its place");
    assertTrue(implementation.code.length > 0, "and the blank implementation gets a real one");

    // And what a developer's `.env` looks like after a Sepolia deploy: both filled in, neither here.
    (registry, implementation) = script.resolveIdentityInputs(CANONICAL_REGISTRY, ADDRESS_WITH_NO_CODE);
    assertTrue(registry.code.length > 0, "registry replaced");
    assertTrue(implementation != ADDRESS_WITH_NO_CODE, "an empty address must not be wired as the implementation");
    assertTrue(implementation.code.length > 0, "implementation replaced");
  }

  /// @dev The other half of the same rule, and what keeps an anvil FORK of a real network honest:
  /// inputs that do exist on this chain are kept, not shadowed by dev deployments.
  function testOnTheDevChainIdentityInputsThatExistAreKept() public {
    PostDeployHarness script = new PostDeployHarness();
    address registry = address(new DevERC6551Registry());
    address implementation = address(new AtlantysmAccount());

    (address resolvedRegistry, address resolvedImplementation) = script.resolveIdentityInputs(registry, implementation);

    assertEq(resolvedRegistry, registry, "an existing registry is kept");
    assertEq(resolvedImplementation, implementation, "an existing implementation is kept");
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
