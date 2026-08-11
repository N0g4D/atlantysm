// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import { IERC6551Account, IERC6551Executable } from "./IERC6551.sol";

/**
 * @title AtlantysmAccount
 * @notice The ERC-6551 account implementation every crystal is bound to. This is the contract that
 * finally lets a human play: it turns "the crystal is an address" from a modelling convenience into
 * something a person can actually drive.
 *
 * ---------------------------------------------------------------------------------------------
 * WHY THIS CLOSES THE ARCHITECTURE
 * ---------------------------------------------------------------------------------------------
 *
 * Every System in this game resolves an actor as `bytes32(uint256(uint160(_msgSender())))` and then
 * requires a crystal to exist at that entity. That is what makes a crystal — not its owner — the
 * thing that fights, funds itself and levels up. Until now nothing could actually CALL as that
 * address, so the whole model was reachable only through `vm.prank` in tests.
 *
 * This account is deployed at exactly that address by the ERC-6551 registry, and forwards calls to
 * the World. `msg.sender` at the World is therefore this account, MUD appends it as `_msgSender()`
 * trusted context, and every identity check in the game resolves to the crystal. The invariant is
 * not re-implemented here — it is simply satisfied.
 *
 * ---------------------------------------------------------------------------------------------
 * AUTHORITY FOLLOWS OWNERSHIP, WHICH FOLLOWS MUD
 * ---------------------------------------------------------------------------------------------
 *
 * `owner()` reads `IERC721.ownerOf(tokenId)` on the bound token contract — the `CrystalNFT` facade —
 * which projects MUD's `CrystalOwner` table. So the chain of authority is:
 *
 *     MUD CrystalOwner -> CrystalNFT.ownerOf -> AtlantysmAccount.owner -> who may execute
 *
 * There is no second source of truth and no separate access list to keep in sync: selling the
 * crystal transfers control of its account in the same transaction that moves the token, because
 * both read the same table.
 *
 * ---------------------------------------------------------------------------------------------
 * SECURITY NOTES
 * ---------------------------------------------------------------------------------------------
 *
 * 1. THE ACCOUNT IS A GENERAL-PURPOSE CALLER, DELIBERATELY. `execute` forwards to any target, which
 *    is what an ERC-6551 account is for. It confers no privilege inside the game beyond being the
 *    crystal: the facade-only gates (`mintCrystal`, `transferCrystal`, `transferMana`) reject it
 *    like any other address, and namespace-owner operations are out of its reach entirely.
 *
 * 2. `state` IS BUMPED BEFORE THE CALL, NOT AFTER. Checks-effects-interactions: a re-entrant
 *    execution observes a counter that has already moved, so an off-chain signer that pinned
 *    `state` cannot have its intent replayed inside its own call.
 *
 * 3. SELLING A CRYSTAL MID-MATCH HANDS OVER ITS ACCOUNT. Already documented in `ArenaSystem`
 *    security note 6, but it becomes concrete here: the buyer can immediately drive the account,
 *    including revealing a move the seller committed. Escrowed wagers cannot be pulled back out,
 *    but the upside moves with the token. A transfer lock during a match remains unimplemented.
 *
 * 4. THIS ACCOUNT HOLDS NO GAME STATE. Mana lives in `ManaBalance` keyed by this address, not in
 *    this contract's balance. Destroying or upgrading the implementation would not move a crystal's
 *    mana — but it WOULD change the derived address for future crystals, which is precisely why
 *    `ForgeConfig` freezes at the first mint.
 */
contract AtlantysmAccount is IERC6551Account, IERC6551Executable, IERC1271, IERC165 {
  /// @dev ERC-6551 defines operation 0 as a plain CALL. Delegatecall and create are out of scope:
  /// an account that can delegatecall can be made to rewrite its own behaviour.
  uint8 internal constant OPERATION_CALL = 0;

  uint256 internal _state;

  error AtlantysmAccount_NotAuthorized(address caller);
  error AtlantysmAccount_UnsupportedOperation(uint8 operation);
  error AtlantysmAccount_ForeignChainToken(uint256 chainId);

  event AccountExecuted(address indexed to, uint256 value, bytes data);

  receive() external payable {}

  // -----------------------------------------------------------------------------------------
  // Identity
  // -----------------------------------------------------------------------------------------

  /**
   * @notice The NFT this account belongs to.
   * @dev ERC-6551 appends `(salt, chainId, tokenContract, tokenId)` after the ERC-1167 proxy body,
   * so the three values live at offset 0x4d of this account's own runtime code. Reading them from
   * code rather than storage is what makes every account a bare 173-byte proxy with no constructor.
   */
  function token() public view returns (uint256 chainId, address tokenContract, uint256 tokenId) {
    bytes memory footer = new bytes(0x60);
    assembly {
      extcodecopy(address(), add(footer, 0x20), 0x4d, 0x60)
    }
    return abi.decode(footer, (uint256, address, uint256));
  }

  /**
   * @notice Whoever currently owns the bound NFT, and therefore this account.
   * @dev Reverts for a token bound on another chain rather than returning a misleading owner: the
   * `ownerOf` call would resolve against a contract at the same address on THIS chain, which is a
   * different token entirely.
   */
  function owner() public view returns (address) {
    (uint256 chainId, address tokenContract, uint256 tokenId) = token();
    if (chainId != block.chainid) revert AtlantysmAccount_ForeignChainToken(chainId);
    return IERC721(tokenContract).ownerOf(tokenId);
  }

  function state() public view returns (uint256) {
    return _state;
  }

  function isValidSigner(address signer, bytes calldata) external view returns (bytes4) {
    return signer == owner() ? IERC6551Account.isValidSigner.selector : bytes4(0);
  }

  // -----------------------------------------------------------------------------------------
  // Execution
  // -----------------------------------------------------------------------------------------

  /// @inheritdoc IERC6551Executable
  function execute(
    address to,
    uint256 value,
    bytes calldata data,
    uint8 operation
  ) external payable returns (bytes memory) {
    if (operation != OPERATION_CALL) revert AtlantysmAccount_UnsupportedOperation(operation);
    return _execute(to, value, data);
  }

  /// @notice Owner-only call forwarding, in the shape most callers actually want.
  function executeCall(address to, uint256 value, bytes calldata data) external payable returns (bytes memory) {
    return _execute(to, value, data);
  }

  /**
   * @notice Call a MUD System through the World, as this crystal.
   * @dev Sugar over `executeCall(world, 0, callData)` — it confers no extra authority. Its purpose
   * is to make the intended usage obvious at the call site, because THIS is the call that makes the
   * whole identity model work: `msg.sender` at the World is this account, so MUD appends it as
   * `_msgSender()` and every System sees the crystal rather than the human behind it.
   *
   * Example: `account.callSystem(world, abi.encodeCall(IWorld.app__claimStarterMana, ()))`
   */
  function callSystem(address world, bytes memory callData) external returns (bytes memory) {
    return _execute(world, 0, callData);
  }

  function _execute(address to, uint256 value, bytes memory data) internal returns (bytes memory result) {
    address currentOwner = owner();
    if (msg.sender != currentOwner) revert AtlantysmAccount_NotAuthorized(msg.sender);

    // Effects before interaction: a re-entrant execution must not see the pre-call counter.
    unchecked {
      ++_state;
    }

    bool success;
    (success, result) = to.call{ value: value }(data);
    if (!success) {
      // Bubble the callee's revert verbatim, so a System's custom error survives the hop and stays
      // decodable by the caller.
      assembly {
        revert(add(result, 0x20), mload(result))
      }
    }

    emit AccountExecuted(to, value, data);
  }

  // -----------------------------------------------------------------------------------------
  // Interoperability
  // -----------------------------------------------------------------------------------------

  /// @notice ERC-1271. Lets the crystal itself be a signer for off-chain flows, delegating the
  /// decision to whoever owns it.
  function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
    return
      SignatureChecker.isValidSignatureNow(owner(), hash, signature) ? IERC1271.isValidSignature.selector : bytes4(0);
  }

  /// @notice A crystal must be able to receive NFTs, otherwise a safe transfer into it would revert.
  function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
    return this.onERC721Received.selector;
  }

  function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
    return
      interfaceId == type(IERC6551Account).interfaceId ||
      interfaceId == type(IERC6551Executable).interfaceId ||
      interfaceId == type(IERC1271).interfaceId ||
      interfaceId == type(IERC165).interfaceId;
  }
}
