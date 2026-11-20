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
 * REVERTS unless `ERC6551_REGISTRY` and `ERC6551_ACCOUNT_IMPLEMENTATION` are supplied — and unless
 * both have code on the chain being deployed to. A non-zero address is not evidence of a contract:
 * a typo, or an address copied from another network, would be frozen in exactly as permanently as
 * a placeholder. Failing the deploy is the cheap outcome; discovering the mistake after the first
 * mint is the expensive one.
 *
 * ---------------------------------------------------------------------------------------------
 * THE SAME CHECK, MIRRORED, ON THE DEV CHAIN
 * ---------------------------------------------------------------------------------------------
 *
 * One `.env` serves both Sepolia and local development, and `.env.example` ships with the canonical
 * registry address filled in. That address has no code on a fresh anvil. Trusting it there used to
 * wire a World in which EVERY mint reverted — `CrystalNFT._deployAccount` calls a registry that is
 * not there — so a fresh clone that followed the documented setup got an unplayable `pnpm dev` and
 * 16 failing tests.
 *
 * On the dev chain an identity input with no code is therefore treated as absent and replaced by a
 * dev deployment. An input that DOES have code is kept, which is what makes an anvil fork of a real
 * network behave like that network.
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

  /// @notice An identity input was supplied but is not a contract on this chain. `variable` is the
  /// environment variable it came from, so the message says which line of `.env` to look at.
  error PostDeploy_IdentityInputHasNoCode(string variable, address value);

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
      // Read here and passed in, so `_resolveIdentityInputs` itself never touches the environment.
      // `envOr` also falls back to the default for a variable that is set but empty, which is how
      // `.env.example` ships `ERC6551_ACCOUNT_IMPLEMENTATION`.
      (address registry, address implementation) = _resolveIdentityInputs(
        vm.envOr("ERC6551_REGISTRY", address(0)),
        vm.envOr("ERC6551_ACCOUNT_IMPLEMENTATION", address(0))
      );

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
   * @dev Decides which ERC-6551 registry and account implementation get frozen into `ForgeConfig`.
   *
   *   off the dev chain   both must be supplied AND both must have code here, otherwise revert
   *   on the dev chain    anything without code here is replaced by a fresh dev deployment
   *
   * The environment values arrive as ARGUMENTS rather than being read here. That is what lets the
   * tests exercise every branch with explicit inputs: `vm.setEnv` is process-wide, so a test that
   * set these variables would race every other test that runs the script.
   *
   * Deploys inside the caller's broadcast, so the dev contracts are real transactions rather than
   * script-local state.
   */
  function _resolveIdentityInputs(address registry, address implementation) internal returns (address, address) {
    if (block.chainid != DEV_CHAIN_ID) {
      // Deliberately fatal. See "the production guard" above.
      if (registry == address(0) || implementation == address(0)) {
        revert PostDeploy_MissingIdentityConfig(block.chainid);
      }
      if (registry.code.length == 0) {
        revert PostDeploy_IdentityInputHasNoCode("ERC6551_REGISTRY", registry);
      }
      if (implementation.code.length == 0) {
        revert PostDeploy_IdentityInputHasNoCode("ERC6551_ACCOUNT_IMPLEMENTATION", implementation);
      }
      return (registry, implementation);
    }

    // `address(0)` has no code either, so "unset" and "set to something that is not here" take the
    // same path. Only the second is worth a line in the log.
    if (registry.code.length == 0) {
      if (registry != address(0)) {
        console.log("ERC6551_REGISTRY has no code on this dev chain, deploying a dev registry instead of", registry);
      }
      registry = address(new DevERC6551Registry());
    }

    // A REAL implementation since phase 9, not a placeholder: this is what lets a crystal act for
    // its owner. Deploying it here rather than only on dev chains would be wrong for the registry —
    // that one must be the canonical deployment — but the account implementation is ours to choose,
    // so the same contract is used everywhere and only the address differs.
    if (implementation.code.length == 0) {
      if (implementation != address(0)) {
        console.log(
          "ERC6551_ACCOUNT_IMPLEMENTATION has no code on this dev chain, deploying a fresh one instead of",
          implementation
        );
      }
      implementation = address(new AtlantysmAccount());
    }

    return (registry, implementation);
  }
}
