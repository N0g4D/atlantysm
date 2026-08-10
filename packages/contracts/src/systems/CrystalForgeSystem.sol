// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import { System } from "@latticexyz/world/src/System.sol";
import { AccessControl } from "@latticexyz/world/src/AccessControl.sol";
import { WorldResourceIdLib } from "@latticexyz/world/src/WorldResourceId.sol";

import { CrystalData, CrystalOwner, ForgeConfig, ForgeConfigData, ForgeNonce } from "../codegen/index.sol";

/**
 * @title CrystalForgeSystem
 * @notice Mints crystals. Each one is born at level 1 and is identified, for the whole rest of the
 * game, by the entity derived from its ERC-6551 token bound account.
 *
 * ---------------------------------------------------------------------------------------------
 * IDENTITY: WHY THE ENTITY IS THE ACCOUNT, NOT THE OWNER AND NOT THE TOKEN ID
 * ---------------------------------------------------------------------------------------------
 *
 * `ArenaSystem` resolves a fighter with `bytes32(uint256(uint160(_msgSender())))` — the caller's own
 * address, widened to the ECS key type. That single line fixes the identity model for everything
 * else: an entity must be an ADDRESS, because only an address can call, and it must be the crystal's
 * token bound account, because the crystal itself is what fights.
 *
 * Three consequences, each of which rules out an alternative that might look simpler:
 *
 *   a. The entity cannot be the OWNER's address. Ownership is transferable and one owner may hold
 *      many crystals, but `CrystalData` is keyed by entity — so an owner-keyed model would cap each
 *      address at one crystal and would move a crystal's entire history on every sale.
 *   b. The entity cannot be an arbitrary hash of the token id. Nothing can ever call as such a
 *      value, so a crystal keyed that way could be minted but never fight.
 *   c. Therefore the entity is the account address, and it must be derived correctly AT MINT TIME.
 *      This is the reason `mintCrystal` is hard-gated on `ForgeConfig`: the entity key is permanent
 *      and load-bearing for `CrystalData`, `ManaBalance` and `ArenaLobby`, so a crystal written at a
 *      placeholder address would be stranded there with no migration path.
 *
 * A human forges (`to` is an EOA, or any contract), but a crystal fights. Those are different
 * addresses on purpose, and `CrystalOwner` is what links them until the ERC-721 facade exists.
 *
 * ---------------------------------------------------------------------------------------------
 * TOKEN ID DERIVATION
 * ---------------------------------------------------------------------------------------------
 *
 * `tokenId = uint256(keccak256(abi.encodePacked(block.timestamp, _msgSender(), to, nonce)))`
 *
 * Note `_msgSender()`, not `msg.sender`. In a namespaced System `msg.sender` is the World, which is
 * constant across every mint — using it would contribute zero entropy and would not identify the
 * minter at all.
 *
 * The `nonce` is not decoration. Without it, two mints in the same block from the same sender to the
 * same recipient share every other input and derive an IDENTICAL token id — a collision reachable by
 * accident in one batched transaction, not a cryptographic curiosity. The nonce is an entropy input
 * only; the id itself remains a hash, never the counter.
 *
 * What this derivation does NOT provide, stated plainly: it is not unpredictable to a proposer. All
 * four inputs are known to whoever builds the block, and `block.timestamp` is theirs to nudge, so a
 * validator can grind for a token id — and therefore for an account address — that it likes. That is
 * acceptable here only because a token id carries no gameplay advantage: every crystal is born at
 * level 1 and nothing in `ArenaSystem` reads the id. The moment an id confers ANY benefit (rarity,
 * traits, ordering), this derivation must be replaced with a commit-reveal or a VRF.
 *
 * ---------------------------------------------------------------------------------------------
 * SECURITY NOTES
 * ---------------------------------------------------------------------------------------------
 *
 * 1. MINTING IS PERMISSIONLESS AND FREE. Anyone may call `mintCrystal`, for any recipient, without
 *    limit or cost beyond gas. This matches the specification for this phase and is deliberately not
 *    fixed here, but it IS an open economic hole: crystals are the entry point to the arena, so an
 *    unbounded free supply undermines any scarcity the game later depends on. Gating (payment, an
 *    allowlist, a per-address cap) belongs in the phase that defines the economy.
 *
 * 2. THE CONFIG IS FROZEN BY THE FIRST MINT. `configureForge` reverts once any crystal exists.
 *    Changing the registry, implementation, token contract or salt afterwards would re-derive every
 *    account address, so every already-minted crystal would silently stop matching its own entity —
 *    its `CrystalData`, its mana and its match history would all become unreachable. Freezing turns
 *    an unrecoverable, silent corruption into a loud revert.
 *
 * 3. REENTRANCY IS NOT A LEVER HERE. As in `ArenaSystem`, a namespace-owner store hook can re-enter
 *    mid-write. `ForgeNonce` is incremented BEFORE it is consumed, so a re-entrant mint derives a
 *    different token id rather than colliding. And since minting is already permissionless, a
 *    re-entrant caller gains nothing it could not obtain with a second transaction.
 *
 * 4. THE COLLISION CHECK IS A BACKSTOP, NOT THE MECHANISM. Uniqueness comes from the monotonic
 *    nonce inside the preimage; `CrystalForge_EntityCollision` only fires on a keccak256 collision
 *    (~2^-256) or on a future change to the preimage that reintroduces one. It is cheap and it turns
 *    the catastrophic case — overwriting a live crystal's data — into a revert.
 *
 * 5. `CrystalOwner` IS A STOPGAP WITH ONE WRITER. Until the ERC-721 facade exists this table is the
 *    only record of ownership and only this System writes it. When the facade lands, `ownerOf` must
 *    become authoritative and this table must be retired or demoted to a facade-maintained mirror.
 *    Leaving two independent writers for one fact is how ownership silently diverges.
 *
 * 6. A FRESH CRYSTAL HAS NO MANA. Minting writes `CrystalData` only. `ArenaSystem.createLobby`
 *    requires a non-zero wager backed by `ManaBalance`, so a newly forged crystal cannot enter the
 *    arena until it is funded by whatever System eventually distributes mana.
 */
contract CrystalForgeSystem is System {
  /// @dev Every crystal is born here. `ArenaSystem._requireCrystal` treats `level == 0` as
  /// "no such crystal", so this MUST stay non-zero or minted crystals would read as non-existent.
  uint8 internal constant INITIAL_LEVEL = 1;

  /// @dev Namespace whose owner may configure the forge. Must match `namespace` in mud.config.ts.
  bytes14 internal constant NAMESPACE = "app";

  /// @notice Emitted once per crystal. `account` is the ERC-6551 address the entity is derived from.
  event CrystalForged(bytes32 indexed entity, uint256 indexed tokenId, address indexed owner, address account);

  /// @notice Emitted when the forge is configured. Can fire at most once per deployment (note 2).
  event ForgeConfigured(
    address accountRegistry,
    address accountImplementation,
    address tokenContract,
    bytes32 accountSalt
  );

  error CrystalForge_ZeroRecipient();
  error CrystalForge_NotConfigured();
  error CrystalForge_InvalidConfig();
  error CrystalForge_AlreadyMinted(uint256 minted);
  error CrystalForge_EntityCollision(bytes32 entity, uint256 tokenId);

  // -----------------------------------------------------------------------------------------
  // Configuration
  // -----------------------------------------------------------------------------------------

  /**
   * @notice Set the ERC-6551 inputs used to derive every crystal's account, and through it its
   * entity. Namespace owner only, and only before the first crystal is forged.
   * @param accountSalt The ERC-6551 salt. Fixed per deployment; it is part of the address
   * derivation, not a randomness source.
   */
  function configureForge(
    address accountRegistry,
    address accountImplementation,
    address tokenContract,
    bytes32 accountSalt
  ) public {
    AccessControl.requireOwner(WorldResourceIdLib.encodeNamespace(NAMESPACE), _msgSender());

    // Security note 2: reconfiguring after a mint would strand every existing crystal.
    uint256 minted = ForgeNonce.getValue();
    if (minted != 0) revert CrystalForge_AlreadyMinted(minted);

    if (accountRegistry == address(0) || accountImplementation == address(0) || tokenContract == address(0)) {
      revert CrystalForge_InvalidConfig();
    }

    ForgeConfig.set(accountRegistry, accountImplementation, tokenContract, accountSalt);
    emit ForgeConfigured(accountRegistry, accountImplementation, tokenContract, accountSalt);
  }

  // -----------------------------------------------------------------------------------------
  // Minting
  // -----------------------------------------------------------------------------------------

  /**
   * @notice Forge a new crystal at level 1 and assign it to `to`.
   * @param to The owner to credit. May be an EOA — the human forges, the crystal fights.
   * @return entity The crystal's permanent ECS key, derived from its token bound account.
   * @return tokenId The crystal's ERC-721 token id.
   */
  function mintCrystal(address to) public returns (bytes32 entity, uint256 tokenId) {
    if (to == address(0)) revert CrystalForge_ZeroRecipient();

    ForgeConfigData memory config = ForgeConfig.get();
    if (
      config.accountRegistry == address(0) ||
      config.accountImplementation == address(0) ||
      config.tokenContract == address(0)
    ) {
      revert CrystalForge_NotConfigured();
    }

    // Consumed before it is used, so a re-entrant mint cannot reuse it (security note 3).
    uint256 nonce = ForgeNonce.getValue() + 1;
    ForgeNonce.setValue(nonce);

    // Grindable by a block proposer, and harmless only while a token id confers no advantage.
    // See the token id discussion above before changing this.
    // forge-lint: disable-next-line(block-timestamp)
    tokenId = uint256(keccak256(abi.encodePacked(block.timestamp, _msgSender(), to, nonce)));

    address account = _accountOf(config, tokenId);
    entity = _entityOf(account);

    // Backstop only; uniqueness comes from the nonce (security note 4).
    if (CrystalData.getLevel(entity) != 0) revert CrystalForge_EntityCollision(entity, tokenId);

    CrystalData.set(entity, tokenId, INITIAL_LEVEL);
    CrystalOwner.setOwner(entity, to);

    emit CrystalForged(entity, tokenId, to, account);
  }

  // -----------------------------------------------------------------------------------------
  // Views
  // -----------------------------------------------------------------------------------------

  /**
   * @notice The ERC-6551 account a given token id maps to. Exposed so clients and the future
   * ERC-721 facade can resolve identity without re-implementing the derivation.
   */
  function crystalAccountOf(uint256 tokenId) public view returns (address) {
    return _accountOf(ForgeConfig.get(), tokenId);
  }

  /// @notice The ECS entity a given token id maps to. No index is needed for this: the mapping is
  /// pure derivation, so a reverse lookup table would be redundant state to keep in sync.
  function crystalEntityOf(uint256 tokenId) public view returns (bytes32) {
    return _entityOf(_accountOf(ForgeConfig.get(), tokenId));
  }

  // -----------------------------------------------------------------------------------------
  // Internals
  // -----------------------------------------------------------------------------------------

  /**
   * @dev ERC-6551 account address, per the final spec (registry v0.3.1). The account need not be
   * deployed for this to be correct — CREATE2 makes the address deterministic and therefore usable
   * as an identity before it holds any code, which is exactly what lets minting run ahead of the
   * registry.
   *
   * creationCode = ERC-1167 header ++ implementation ++ ERC-1167 footer
   *                ++ abi.encode(salt, chainId, tokenContract, tokenId)
   * address      = CREATE2(registry, salt, keccak256(creationCode))
   */
  function _accountOf(ForgeConfigData memory config, uint256 tokenId) internal view returns (address) {
    bytes memory creationCode = abi.encodePacked(
      hex"3d60ad80600a3d3981f3363d3d373d3d3d363d73",
      config.accountImplementation,
      hex"5af43d82803e903d91602b57fd5bf3",
      abi.encode(config.accountSalt, block.chainid, config.tokenContract, tokenId)
    );

    bytes32 create2Hash = keccak256(
      abi.encodePacked(bytes1(0xff), config.accountRegistry, config.accountSalt, keccak256(creationCode))
    );

    // Standard CREATE2 address extraction: the low 20 bytes are the address by definition.
    // forge-lint: disable-next-line(unsafe-typecast)
    return address(uint160(uint256(create2Hash)));
  }

  /// @dev Must stay bit-identical to `ArenaSystem._entityOf`, or a minted crystal would be unable
  /// to fight under its own identity.
  function _entityOf(address account) internal pure returns (bytes32) {
    return bytes32(uint256(uint160(account)));
  }
}
