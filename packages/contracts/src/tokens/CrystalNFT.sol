// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { ERC721Utils } from "@openzeppelin/contracts/token/ERC721/utils/ERC721Utils.sol";

import { IWorld } from "../codegen/world/IWorld.sol";
import { IERC6551Registry } from "../accounts/IERC6551.sol";

/**
 * @title CrystalNFT
 * @notice ERC-721 projection of the crystals held in MUD. Holds NO ownership state of its own.
 *
 * ---------------------------------------------------------------------------------------------
 * WHAT LIVES WHERE
 * ---------------------------------------------------------------------------------------------
 *
 *   Ownership (`_owners`)   -> MUD `CrystalOwner`, read back via `ownerOfCrystal`
 *   Balances (`_balances`)  -> MUD `CrystalBalance`, read back via `crystalBalanceOf`
 *   Approvals               -> STAY HERE, in the facade's own storage
 *
 * Approvals are deliberately not pushed into MUD. They are a token-protocol concern with no meaning
 * inside the game — no System asks "who may transfer this" — so putting them in a table would mean
 * paying MUD writes for state the game never reads. `TokenBridgeSystem` compensates by re-checking
 * the one fact this contract cannot be trusted on: that `from` really is the current owner.
 *
 * OpenZeppelin v5 makes this shape possible at all: `_ownerOf`, `balanceOf` and `_update` are the
 * three virtual seams, and `_update` is documented as the single place ownership changes.
 *
 * ---------------------------------------------------------------------------------------------
 * THE MINT PATH IS THE POINT
 * ---------------------------------------------------------------------------------------------
 *
 * `mint` is the ONLY way a crystal comes into existence: `CrystalForgeSystem.mintCrystal` rejects
 * every caller but this contract. So MUD state and the ERC-721 `Transfer` log cannot drift — a
 * crystal that exists without having been announced is unreachable, not merely discouraged.
 *
 * The call goes facade -> World -> System, never the reverse. No System calls back into this
 * contract, which means the replaceable, owner-registered code is always the OUTER frame and every
 * table write has settled before it regains control.
 *
 * ---------------------------------------------------------------------------------------------
 * KNOWN LIMITS
 * ---------------------------------------------------------------------------------------------
 *
 * - NO BURN. Nothing in the game deletes `CrystalData`, so a crystal cannot cease to exist. A
 *   transfer to address(0) is rejected here rather than silently stranding the entity's mana and
 *   match history at an unreachable address.
 * - `tokenURI` is unimplemented (empty base URI). Metadata should eventually project `CrystalData`
 *   — level in particular — but that needs a renderer, not just a facade.
 */
contract CrystalNFT is ERC721 {
  /// @notice The MUD World that owns all crystal state.
  IWorld public immutable world;

  /**
   * @notice ERC-6551 inputs, cached on the first mint.
   *
   * These cannot be immutables: `configureForge` needs this contract's address as its
   * `tokenContract`, so the config necessarily comes into existence AFTER this constructor runs.
   *
   * Caching is safe for a specific reason rather than by luck — `configureForge` freezes the moment
   * the first crystal is minted, so the values read during that very mint are the final ones. After
   * that the World could not change them even if asked. The alternative, reading
   * `world.forgeConfig()` on every mint, pays a World hop plus three table slots forever to fetch
   * a value that provably cannot move.
   */
  address public accountRegistry;
  address public accountImplementation;
  bytes32 public accountSalt;

  /// @notice Emitted when a crystal's token bound account is deployed on-chain.
  event CrystalAccountDeployed(uint256 indexed tokenId, address indexed account);

  error CrystalNFT_BurnNotSupported();

  constructor(IWorld _world) ERC721("Atlantysm Crystal", "CRYSTAL") {
    world = _world;
  }

  /**
   * @notice Forge a new crystal and assign it to `to`. Payment is forwarded to the World, which
   * credits the namespace balance; the price is set on-chain by `MintPrice` and must match exactly.
   * @dev Emits `Transfer` directly rather than calling OZ's `_mint`: by the time this returns, MUD
   * has already recorded the owner, so `_mint`'s "token must not exist" precondition — which reads
   * ownership through the overridden `_ownerOf` — would see the crystal and revert.
   */
  function mint(address to) external payable returns (uint256 tokenId) {
    (, tokenId) = world.app__mintCrystal{ value: msg.value }(to);

    emit Transfer(address(0), to, tokenId);

    // Phase 9: give the crystal a body. Until the account exists on-chain, its address is only a
    // prediction and nothing can call as it — the identity model would be unreachable by a human.
    _deployAccount(tokenId);

    // The receiver hook `_safeMint` would have run. Skipping it would let a mint land in a contract
    // that cannot move it again. It runs last, after MUD state has settled, so a re-entrant mint is
    // just another ordinary mint.
    ERC721Utils.checkOnERC721Received(_msgSender(), address(0), to, tokenId, "");
  }

  /**
   * @dev Deploys the crystal's ERC-6551 account. `createAccount` is idempotent per the spec, so
   * this stays correct even if the account somehow already exists.
   *
   * The address it returns is the same one `CrystalIdentityLib` predicted when MUD wrote
   * `CrystalData`, because both hash the same creation code with the same salt. A mismatch here
   * would mean the crystal's state lives at an address its account will never occupy — which is why
   * `testTheAccountLandsExactlyWhereMudPredicted` asserts the two agree rather than trusting it.
   */
  function _deployAccount(uint256 tokenId) internal returns (address account) {
    (address registry, address implementation, bytes32 salt) = _identityInputs();

    account = IERC6551Registry(registry).createAccount(implementation, salt, block.chainid, address(this), tokenId);

    emit CrystalAccountDeployed(tokenId, account);
  }

  /// @dev Cache-through read of the frozen ERC-6551 config. See the fields' documentation for why
  /// caching is sound.
  function _identityInputs() internal returns (address registry, address implementation, bytes32 salt) {
    registry = accountRegistry;
    if (registry != address(0)) {
      return (registry, accountImplementation, accountSalt);
    }

    (registry, implementation, , salt) = world.app__forgeConfig();

    accountRegistry = registry;
    accountImplementation = implementation;
    accountSalt = salt;
  }

  // -----------------------------------------------------------------------------------------
  // Projections of MUD state
  // -----------------------------------------------------------------------------------------

  /// @dev Returns address(0) for a crystal that does not exist, which is what OZ's `_requireOwned`
  /// turns into the `ERC721NonexistentToken` error wallets expect.
  function _ownerOf(uint256 tokenId) internal view override returns (address) {
    return world.app__ownerOfCrystal(tokenId);
  }

  function balanceOf(address owner) public view override returns (uint256) {
    if (owner == address(0)) revert ERC721InvalidOwner(address(0));
    return world.app__crystalBalanceOf(owner);
  }

  // -----------------------------------------------------------------------------------------
  // The single mutation seam
  // -----------------------------------------------------------------------------------------

  /**
   * @dev Mirrors OZ's `_update` contract exactly — authorisation check, approval clear, ledger
   * write, `Transfer` — with the ledger write delegated to MUD instead of local storage.
   *
   * Mints do not pass through here (see `mint`), so `from == address(0)` means the token genuinely
   * does not exist.
   */
  function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
    from = _ownerOf(tokenId);

    if (auth != address(0)) {
      _checkAuthorized(from, auth, tokenId);
    }

    if (from == address(0)) revert ERC721NonexistentToken(tokenId);
    if (to == address(0)) revert CrystalNFT_BurnNotSupported();

    // Clear the approval without emitting, exactly as OZ does on transfer.
    _approve(address(0), tokenId, address(0), false);

    world.app__transferCrystal(from, to, tokenId);

    emit Transfer(from, to, tokenId);
  }
}
