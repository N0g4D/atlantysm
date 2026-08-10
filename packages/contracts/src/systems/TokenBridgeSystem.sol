// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import { System } from "@latticexyz/world/src/System.sol";
import { AccessControl } from "@latticexyz/world/src/AccessControl.sol";
import { WorldResourceIdLib } from "@latticexyz/world/src/WorldResourceId.sol";
import { ResourceId } from "@latticexyz/store/src/ResourceId.sol";

import { CrystalData, CrystalOwner, CrystalBalance, ManaBalance, ManaSupply, TokenFacade } from "../codegen/index.sol";
import { CrystalIdentityLib } from "../libraries/CrystalIdentityLib.sol";

/**
 * @title TokenBridgeSystem
 * @notice The ONLY write path the ERC-721 and ERC-20 facades have into MUD state.
 *
 * ---------------------------------------------------------------------------------------------
 * THE DIRECTION OF THE DEPENDENCY, AND WHY IT MATTERS
 * ---------------------------------------------------------------------------------------------
 *
 * MUD is the single source of truth. The facades hold no ownership or balance state of their own —
 * they read it back through the view functions here and re-publish it as ERC-721/ERC-20 events.
 *
 * The dependency points ONE way: facade -> World -> System. No System ever calls out to a token
 * contract. That is a deliberate security property, not an accident of layering:
 *   - a System calling a facade would be a System making an external call into a contract the
 *     namespace owner may later replace, i.e. handing a reentrancy lever to whoever controls the
 *     facade address;
 *   - with the arrow reversed, the untrusted-but-privileged code is always the OUTER frame, and by
 *     the time it regains control every table write has already settled.
 *
 * The consequence for minting is what makes ownership single-sourced: `CrystalForgeSystem.mintCrystal`
 * is restricted to the NFT facade, so there is exactly ONE path that creates a crystal. State and
 * the ERC-721 `Transfer` event therefore cannot diverge — a MUD-side mint that skipped the event is
 * not merely discouraged, it is unreachable.
 *
 * ---------------------------------------------------------------------------------------------
 * SECURITY NOTES
 * ---------------------------------------------------------------------------------------------
 *
 * 1. FACADE-ONLY, AND IT FAILS CLOSED. Every mutating entry point requires `_msgSender()` to be the
 *    exact address recorded in `TokenFacade`. Before configuration that record reads `address(0)`,
 *    which no caller can ever be, so an unconfigured bridge rejects everyone rather than admitting
 *    everyone. Each facade is checked against ITS own slot: the mana token cannot move crystals and
 *    the NFT cannot move mana.
 *
 * 2. AUTHORISATION IS SPLIT ON PURPOSE, AND EACH HALF IS CHECKED WHERE IT LIVES. ERC-721 approvals
 *    and ERC-20 allowances stay in the facades — they are token-protocol concerns with no meaning
 *    inside the game, and putting them in MUD would mean paying table writes for them. This System
 *    therefore trusts the facade's authorisation decision, which is safe ONLY because the facade is
 *    a fixed, owner-registered address. It still re-checks the FACT the facade cannot be trusted to
 *    know better than the ledger: that `from` really is the current owner.
 *
 * 3. NO BURN PATH. Nothing deletes `CrystalData`, so a crystal cannot cease to exist; the facade
 *    rejects burns rather than this System silently accepting a transfer to address(0) that would
 *    strand the entity's mana and match history.
 *
 * 4. MANA TRANSFERS DO NOT MOVE SUPPLY. `ManaSupply` tracks issuance, and a transfer is neither
 *    issuance nor destruction. Only `ProgressionSystem` moves it — the faucet mints, levelling
 *    burns. Arena settlement is zero-sum and correctly leaves it alone too.
 *
 * 5. MANA CAN BE HELD BY A NON-CRYSTAL ADDRESS, AND THAT IS DELIBERATE. `ManaBalance` is keyed by
 *    entity, and an EOA's entity is simply an address with no crystal at it. Such an address can
 *    hold and move mana — otherwise this would not be an ERC-20 — but it can never USE it: every
 *    game action (`createLobby`, `claimStarterMana`, `levelUp`) independently requires a crystal at
 *    the caller's entity. The identity model is enforced where it matters, not at the token layer.
 */
contract TokenBridgeSystem is System {
  /// @dev Namespace whose owner registers the facades. Must match `namespace` in mud.config.ts.
  bytes14 internal constant NAMESPACE = "app";

  event TokenFacadesSet(address crystalNft, address manaToken);

  error TokenBridge_InvalidFacade();
  error TokenBridge_NotTheCrystalFacade(address caller);
  error TokenBridge_NotTheManaFacade(address caller);
  error TokenBridge_UnknownCrystal(uint256 tokenId);
  error TokenBridge_WrongOwner(uint256 tokenId, address claimed, address actual);
  error TokenBridge_ZeroRecipient();
  error TokenBridge_AmountTooLarge(uint256 amount);
  error TokenBridge_InsufficientMana(address from, uint256 balance, uint256 amount);
  error TokenBridge_ManaOverflow(address to);

  // -----------------------------------------------------------------------------------------
  // Configuration
  // -----------------------------------------------------------------------------------------

  /**
   * @notice Register the two token facades. Namespace owner only.
   * @dev Not frozen after first use, unlike `ForgeConfig`: a facade is replaceable infrastructure
   * (a bug fix, a metadata change) and holds no state that a replacement would lose. Replacing the
   * NFT does change who may mint, which is exactly the intended lever.
   */
  function setTokenFacades(address crystalNft, address manaToken) public {
    AccessControl.requireOwner(_namespaceId(), _msgSender());
    if (crystalNft == address(0) || manaToken == address(0)) revert TokenBridge_InvalidFacade();

    TokenFacade.set(crystalNft, manaToken);
    emit TokenFacadesSet(crystalNft, manaToken);
  }

  // -----------------------------------------------------------------------------------------
  // ERC-721 writes
  // -----------------------------------------------------------------------------------------

  /**
   * @notice Move a crystal's ownership. Callable only by the registered NFT facade.
   * @dev The facade has already run the ERC-721 authorisation checks; what it cannot be trusted to
   * know is the ledger, so `from` is re-verified against `CrystalOwner` here (security note 2).
   */
  function transferCrystal(address from, address to, uint256 tokenId) public {
    _requireCrystalFacade();
    if (to == address(0)) revert TokenBridge_ZeroRecipient();

    bytes32 entity = CrystalIdentityLib.entityOfToken(tokenId);
    if (CrystalData.getLevel(entity) == 0) revert TokenBridge_UnknownCrystal(tokenId);

    address owner = CrystalOwner.getOwner(entity);
    if (owner != from) revert TokenBridge_WrongOwner(tokenId, from, owner);

    CrystalOwner.setOwner(entity, to);

    // Read-modify-write in this order so a self-transfer cancels exactly: when `from == to` the
    // second read observes the already-decremented count and restores it.
    CrystalBalance.setCount(from, CrystalBalance.getCount(from) - 1);
    CrystalBalance.setCount(to, CrystalBalance.getCount(to) + 1);
  }

  // -----------------------------------------------------------------------------------------
  // ERC-20 writes
  // -----------------------------------------------------------------------------------------

  /**
   * @notice Move mana between two holders. Callable only by the registered mana facade.
   * @dev Supply is untouched: a transfer is neither issuance nor destruction (security note 4).
   */
  function transferMana(address from, address to, uint256 amount) public {
    _requireManaFacade();
    if (to == address(0)) revert TokenBridge_ZeroRecipient();
    if (amount > type(uint128).max) revert TokenBridge_AmountTooLarge(amount);

    bytes32 fromEntity = CrystalIdentityLib.entityOf(from);
    bytes32 toEntity = CrystalIdentityLib.entityOf(to);

    // Bounded by the check above.
    // forge-lint: disable-next-line(unsafe-typecast)
    uint128 value = uint128(amount);

    uint128 fromBalance = ManaBalance.getAmount(fromEntity);
    if (fromBalance < value) revert TokenBridge_InsufficientMana(from, fromBalance, amount);

    ManaBalance.setAmount(fromEntity, fromBalance - value);

    // The credit re-reads deliberately rather than reusing a pre-debit local: on a self-transfer
    // that is what makes the two halves cancel instead of resurrecting the debited amount.
    uint256 credited = uint256(ManaBalance.getAmount(toEntity)) + value;
    if (credited > type(uint128).max) revert TokenBridge_ManaOverflow(to);

    // Bounded by the check above.
    // forge-lint: disable-next-line(unsafe-typecast)
    ManaBalance.setAmount(toEntity, uint128(credited));
  }

  // -----------------------------------------------------------------------------------------
  // Views — what the facades project
  // -----------------------------------------------------------------------------------------

  /**
   * @notice Owner of a crystal, or address(0) if no such crystal exists.
   * @dev Returning zero rather than reverting lets the facade produce the ERC-721-mandated
   * `ERC721NonexistentToken` error itself, which is the error wallets expect.
   */
  function ownerOfCrystal(uint256 tokenId) public view returns (address) {
    bytes32 entity = CrystalIdentityLib.entityOfToken(tokenId);
    if (CrystalData.getLevel(entity) == 0) return address(0);
    return CrystalOwner.getOwner(entity);
  }

  /// @notice How many crystals an address holds. Maintained on mint and transfer.
  function crystalBalanceOf(address owner) public view returns (uint256) {
    return CrystalBalance.getCount(owner);
  }

  /// @notice Mana held at an address's entity. Works for any address, crystal or not (note 5).
  function manaBalanceOf(address account) public view returns (uint256) {
    return ManaBalance.getAmount(CrystalIdentityLib.entityOf(account));
  }

  /// @notice Circulating mana. Moved only by the faucet and by levelling.
  function manaTotalSupply() public view returns (uint256) {
    return ManaSupply.getValue();
  }

  /// @notice The registered facades. Both are address(0) until configured, which is what makes the
  /// bridge fail closed.
  function tokenFacades() public view returns (address crystalNft, address manaToken) {
    return (TokenFacade.getCrystalNft(), TokenFacade.getManaToken());
  }

  // -----------------------------------------------------------------------------------------
  // Internals
  // -----------------------------------------------------------------------------------------

  function _requireCrystalFacade() internal view {
    address facade = TokenFacade.getCrystalNft();
    if (_msgSender() != facade) revert TokenBridge_NotTheCrystalFacade(_msgSender());
  }

  function _requireManaFacade() internal view {
    address facade = TokenFacade.getManaToken();
    if (_msgSender() != facade) revert TokenBridge_NotTheManaFacade(_msgSender());
  }

  function _namespaceId() internal pure returns (ResourceId) {
    return WorldResourceIdLib.encodeNamespace(NAMESPACE);
  }
}
