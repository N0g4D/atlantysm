// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { IWorld } from "../src/codegen/world/IWorld.sol";
import { CrystalNFT } from "../src/tokens/CrystalNFT.sol";
import { ManaToken } from "../src/tokens/ManaToken.sol";
import { DevERC6551Registry } from "../src/dev/DevERC6551Registry.sol";
import { AtlantysmAccount } from "../src/accounts/AtlantysmAccount.sol";

/**
 * @title PostDeploy
 * @notice Wires a freshly deployed World into a playable game.
 *
 * Before this script existed the World deployed but could not be used at all: phase 7 made the
 * ERC-721 facade the only mint path, and nothing registered a facade, so `mintCrystal` rejected
 * every caller. That is the hole this closes.
 *
 * ---------------------------------------------------------------------------------------------
 * ORDER IS FORCED, NOT ARBITRARY
 * ---------------------------------------------------------------------------------------------
 *
 *   1. resolve the ERC-6551 registry and account implementation
 *   2. deploy CrystalNFT and ManaToken
 *   3. configureForge(registry, implementation, address(nft), salt)
 *   4. setTokenFacades(nft, manaToken)
 *   5. setMintPrice(price)
 *
 * Step 3 has to follow step 2 because the ERC-6551 `tokenContract` IS the NFT: accounts are bound
 * to the contract that owns the token ids, so the address cannot be known before the NFT exists.
 * Steps 4 and 5 could swap, but neither may precede 3 — a mint before `ForgeConfig` is set reverts.
 *
 * ---------------------------------------------------------------------------------------------
 * THE PRODUCTION GUARD
 * ---------------------------------------------------------------------------------------------
 *
 * `configureForge` freezes on the first mint, permanently, because the registry / implementation /
 * token contract triple decides where every crystal's identity lives. Writing throwaway dev
 * addresses into it on a real network would bind every crystal ever minted to an implementation
 * that does not exist, with no migration path.
 *
 * So the dev defaults are available ONLY on the local anvil chain. Anywhere else this script
 * REVERTS unless `ERC6551_REGISTRY` and `ERC6551_ACCOUNT_IMPLEMENTATION` are supplied. Failing the
 * deploy is the cheap outcome; discovering the mistake after the first mint is the expensive one.
 *
 * ---------------------------------------------------------------------------------------------
 * RE-RUNNING
 * ---------------------------------------------------------------------------------------------
 *
 * `mud deploy` against an existing World runs this again. Identity setup is therefore skipped when
 * the forge is already configured — and the facades are NOT redeployed with it, deliberately:
 * a fresh NFT would not match the frozen `tokenContract`, so every entity it minted would be
 * derived against the wrong address. The mint price is re-applied every time, since it is a
 * tunable lever rather than an identity input.
 */
contract PostDeploy is Script {
  /// @dev Anvil. The only chain on which throwaway identity inputs are acceptable.
  uint256 internal constant DEV_CHAIN_ID = 31337;

  uint256 internal constant DEFAULT_MINT_PRICE = 0.01 ether;

  /// @dev ERC-6551 salt. Fixed per deployment; part of address derivation, not a randomness source.
  bytes32 internal constant ACCOUNT_SALT = bytes32(0);

  error PostDeploy_MissingIdentityConfig(uint256 chainId);

  function run(address worldAddress) external {
    // NOTE: no `StoreSwitch.setStoreAddress` and no direct table reads here, unlike the MUD
    // template's suggestion. Every generated table accessor executes `address(this)` to choose
    // between local storage and an external call, and Foundry rejects that opcode inside a script:
    // "Usage of `address(this)` detected in script contract". All state is therefore read through
    // the World's own view functions.

    // Load the private key from the `PRIVATE_KEY` environment variable (in .env). This account is
    // the namespace owner, which is what `configureForge`, `setTokenFacades` and `setMintPrice`
    // all require.
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

    IWorld world = IWorld(worldAddress);
    uint256 mintPrice = vm.envOr("MINT_PRICE", DEFAULT_MINT_PRICE);
    (, , address configuredTokenContract, ) = world.app__forgeConfig();
    bool alreadyConfigured = configuredTokenContract != address(0);

    vm.startBroadcast(deployerPrivateKey);

    if (alreadyConfigured) {
      // Identity is frozen to the existing facades; replacing them here would silently re-derive
      // every future entity against a token contract `ForgeConfig` no longer points at.
      (address existingNft, address existingMana) = world.app__tokenFacades();
      console.log("Forge already configured - reusing facades");
      console.log("  CrystalNFT:", existingNft);
      console.log("  ManaToken: ", existingMana);
    } else {
      (address registry, address implementation) = _resolveIdentityInputs();

      CrystalNFT nft = new CrystalNFT(world);
      ManaToken manaToken = new ManaToken(world);

      // `tokenContract` is the real NFT, not a placeholder: ERC-6551 binds an account to the
      // contract that owns the token id, and that is this one.
      world.app__configureForge(registry, implementation, address(nft), ACCOUNT_SALT);
      world.app__setTokenFacades(address(nft), address(manaToken));

      console.log("ERC6551 registry:      ", registry);
      console.log("ERC6551 implementation:", implementation);
      console.log("CrystalNFT:            ", address(nft));
      console.log("ManaToken:             ", address(manaToken));
    }

    world.app__setMintPrice(mintPrice);
    console.log("Mint price (wei):      ", mintPrice);

    vm.stopBroadcast();
  }

  /**
   * @dev Environment first, dev defaults only on anvil, revert everywhere else.
   *
   * Deploys inside the caller's broadcast, so the dev contracts are real transactions rather than
   * script-local state.
   */
  function _resolveIdentityInputs() internal returns (address registry, address implementation) {
    registry = vm.envOr("ERC6551_REGISTRY", address(0));
    implementation = vm.envOr("ERC6551_ACCOUNT_IMPLEMENTATION", address(0));

    if (registry != address(0) && implementation != address(0)) {
      return (registry, implementation);
    }

    if (block.chainid != DEV_CHAIN_ID) {
      // Deliberately fatal. See "the production guard" above.
      revert PostDeploy_MissingIdentityConfig(block.chainid);
    }

    if (registry == address(0)) registry = address(new DevERC6551Registry());
    // A REAL implementation since phase 9, not a placeholder: this is what lets a crystal act for
    // its owner. Deploying it here rather than only on dev chains would be wrong for the registry —
    // that one must be the canonical deployment — but the account implementation is ours to choose,
    // so the same contract is used everywhere and only the address differs.
    if (implementation == address(0)) implementation = address(new AtlantysmAccount());
  }
}
