// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import { System } from "@latticexyz/world/src/System.sol";
import { AccessControl } from "@latticexyz/world/src/AccessControl.sol";
import { WorldResourceIdLib } from "@latticexyz/world/src/WorldResourceId.sol";
import { ResourceId } from "@latticexyz/store/src/ResourceId.sol";
import { Balances } from "@latticexyz/world/src/codegen/tables/Balances.sol";

import { CrystalData, CrystalOwner, CrystalBalance, ForgeConfig, ForgeConfigData, ForgeNonce, MintPrice, TokenFacade } from "../codegen/index.sol";
import { CrystalIdentityLib } from "../libraries/CrystalIdentityLib.sol";

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
 * addresses on purpose, and `CrystalOwner` is what links them — permanently, as the ERC-721
 * facade projects that table rather than replacing it.
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
 * 1. MINTING IS PERMISSIONLESS, PRICED, AND ROUTED THROUGH THE FACADE. Anyone may mint for any
 *    recipient, but only by calling the ERC-721 facade, which forwards here; a direct call to this
 *    System is rejected. That single path is what keeps MUD state and the ERC-721 `Transfer` event
 *    from diverging — a mint that produced a crystal without announcing it is unreachable rather
 *    than merely discouraged.
 *    Each mint costs exactly `MintPrice.price` in native ETH. That price is the sybil gate for the
 *    whole economy: a crystal is the only way to draw the mana faucet, so an unpriced forge would
 *    make mana free and unbounded no matter what the faucet itself limits.
 *    Note the side effect on entropy: `_msgSender()` is now always the facade, so the minter's own
 *    address no longer contributes to the token id preimage. Uniqueness was never resting on it —
 *    the monotonic nonce carries that — but the derivation is one input poorer than before.
 *    Payment must be EXACT. Underpaying reverts, and so does overpaying — no change is returned. A
 *    refund path would mean sending ETH back mid-mint, which is a reentrancy surface bought for
 *    nothing, since the caller already knows the price from `MintPrice` before sending.
 *
 * 1b. WHERE THE ETH ACTUALLY GOES, AND WHY THERE IS NO `withdrawETH` HERE. MUD does NOT forward
 *    value to a System: `SystemCall` credits `Balances[namespace]` inside the World and then calls
 *    the System with `call{value: 0}`, appending the original `msg.value` to calldata as trusted
 *    context. So `_msgValue()` is what the payment check must read, and this contract's own ETH
 *    balance is permanently zero. A `withdrawETH()` implemented here over `address(this).balance`
 *    would compile, run, emit nothing suspicious and transfer exactly nothing.
 *    Withdrawal is therefore the World's job, and MUD already ships it:
 *      IWorld.transferBalanceToAddress(namespaceId, to, amount)
 *    gated on namespace access and written checks-effects-interactions. `mintRevenue()` below
 *    exposes the balance so the collectable amount is readable from this System's own surface.
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
 * 5. `CrystalOwner` IS NOW THE AUTHORITATIVE OWNERSHIP LEDGER, NOT A STOPGAP. Phase 7 resolved this
 *    the other way round from what phase 4 anticipated: rather than the ERC-721 becoming the source
 *    of truth, the facade holds NO ownership state at all and projects this table. `ownerOf` and
 *    `balanceOf` read it back through `TokenBridgeSystem`. There is exactly one writer per
 *    operation — this System on mint, `TokenBridgeSystem` on transfer — so the two-writers
 *    divergence that note warned about never materialised.
 *    `CrystalBalance` is derived from this table and must move with it on every write.
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

  /// @notice Emitted whenever the mint price changes. Unlike `ForgeConfigured`, this may fire any
  /// number of times: a price is an economic lever, not an identity input.
  event MintPriceSet(uint256 price);

  error CrystalForge_ZeroRecipient();
  error CrystalForge_NotConfigured();
  error CrystalForge_InvalidConfig();
  error CrystalForge_AlreadyMinted(uint256 minted);
  error CrystalForge_EntityCollision(bytes32 entity, uint256 tokenId);
  error CrystalForge_MintPriceNotConfigured();
  error CrystalForge_IncorrectPayment(uint256 expected, uint256 provided);
  error CrystalForge_NotTheCrystalFacade(address caller);

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
    AccessControl.requireOwner(_namespaceId(), _msgSender());

    // Security note 2: reconfiguring after a mint would strand every existing crystal.
    uint256 minted = ForgeNonce.getValue();
    if (minted != 0) revert CrystalForge_AlreadyMinted(minted);

    if (accountRegistry == address(0) || accountImplementation == address(0) || tokenContract == address(0)) {
      revert CrystalForge_InvalidConfig();
    }

    ForgeConfig.set(accountRegistry, accountImplementation, tokenContract, accountSalt);
    emit ForgeConfigured(accountRegistry, accountImplementation, tokenContract, accountSalt);
  }

  /**
   * @notice Set the price of one mint, in native ETH wei. Namespace owner only.
   *
   * Deliberately NOT frozen by the first mint, unlike `configureForge`: that config decides where a
   * crystal's identity lives and must never move, whereas a price is a lever the economy is expected
   * to pull. Setting `0` is legal and means a genuinely free mint — it is distinguishable from "no
   * price set yet" because the record carries an explicit `configured` flag.
   */
  function setMintPrice(uint256 price) public {
    AccessControl.requireOwner(_namespaceId(), _msgSender());

    MintPrice.set(true, price);
    emit MintPriceSet(price);
  }

  // -----------------------------------------------------------------------------------------
  // Minting
  // -----------------------------------------------------------------------------------------

  /**
   * @notice Forge a new crystal at level 1 and assign it to `to`, against an exact ETH payment.
   * @dev `payable` matters for a reason that is easy to miss: the World forwards no value to a
   * System (`call{value: 0}`), so this function never actually receives ETH — but worldgen mirrors
   * the mutability onto `IWorld.app__mintCrystal`, and without `payable` there the World would
   * reject the transaction before any of this runs. The payment itself is read from `_msgValue()`,
   * the trusted context MUD appends to calldata. See security note 1b.
   * @param to The owner to credit. May be an EOA — the human forges, the crystal fights.
   * @return entity The crystal's permanent ECS key, derived from its token bound account.
   * @return tokenId The crystal's ERC-721 token id.
   */
  function mintCrystal(address to) public payable returns (bytes32 entity, uint256 tokenId) {
    // Phase 7: the ERC-721 facade is the sole mint path, so every crystal that exists has a
    // matching `Transfer` event. A MUD-side mint that skipped the event is not discouraged here,
    // it is unreachable. Unset reads address(0), so this fails closed before configuration.
    address facade = TokenFacade.getCrystalNft();
    if (_msgSender() != facade) revert CrystalForge_NotTheCrystalFacade(_msgSender());

    if (to == address(0)) revert CrystalForge_ZeroRecipient();

    // The sybil gate. Checked before anything is derived or written.
    if (!MintPrice.getConfigured()) revert CrystalForge_MintPriceNotConfigured();
    uint256 price = MintPrice.getPrice();
    if (_msgValue() != price) revert CrystalForge_IncorrectPayment(price, _msgValue());

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

    address account = CrystalIdentityLib.accountOf(config, tokenId);
    entity = CrystalIdentityLib.entityOf(account);

    // Backstop only; uniqueness comes from the nonce (security note 4).
    if (CrystalData.getLevel(entity) != 0) revert CrystalForge_EntityCollision(entity, tokenId);

    CrystalData.set(entity, tokenId, INITIAL_LEVEL);
    CrystalOwner.setOwner(entity, to);
    // Derived counter for the ERC-721 facade's `balanceOf`; must move with every `CrystalOwner`
    // write, here and in `TokenBridgeSystem.transferCrystal`.
    CrystalBalance.setCount(to, CrystalBalance.getCount(to) + 1);

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
    return CrystalIdentityLib.accountOf(ForgeConfig.get(), tokenId);
  }

  /// @notice The ECS entity a given token id maps to. No index is needed for this: the mapping is
  /// pure derivation, so a reverse lookup table would be redundant state to keep in sync.
  function crystalEntityOf(uint256 tokenId) public view returns (bytes32) {
    return CrystalIdentityLib.entityOfToken(tokenId);
  }

  /**
   * @notice Mint revenue collected so far, in wei, still held by the World.
   * @dev Reads the namespace balance MUD credits on every paid call. Withdraw it with
   * `IWorld.transferBalanceToAddress(namespaceId, to, amount)` — see security note 1b for why that
   * lives on the World and not here.
   */
  function mintRevenue() public view returns (uint256) {
    return Balances.getBalance(_namespaceId());
  }

  /// @notice The current mint price, and whether one has been set at all. Read this before minting:
  /// payment must match exactly and no change is returned.
  function mintPrice() public view returns (bool configured, uint256 price) {
    return (MintPrice.getConfigured(), MintPrice.getPrice());
  }

  // -----------------------------------------------------------------------------------------
  // Internals
  // -----------------------------------------------------------------------------------------

  // Identity derivation lives in `CrystalIdentityLib` since phase 7: `TokenBridgeSystem` needs the
  // same `tokenId -> account -> entity` mapping, and two copies of an ERC-6551 CREATE2 derivation
  // would diverge silently rather than loudly.

  /// @dev The namespace this System lives in, and whose owner administers it and holds its revenue.
  function _namespaceId() internal pure returns (ResourceId) {
    return WorldResourceIdLib.encodeNamespace(NAMESPACE);
  }
}
