// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

/**
 * @notice ERC-6551 registry, final spec (reference deployment v0.3.1).
 * @dev `createAccount` is idempotent: it returns the existing address when the account has already
 * been deployed, which is what lets a mint call it unconditionally.
 */
interface IERC6551Registry {
  function createAccount(
    address implementation,
    bytes32 salt,
    uint256 chainId,
    address tokenContract,
    uint256 tokenId
  ) external returns (address account);

  function account(
    address implementation,
    bytes32 salt,
    uint256 chainId,
    address tokenContract,
    uint256 tokenId
  ) external view returns (address account);
}

/// @notice The account interface every ERC-6551 account must implement.
interface IERC6551Account {
  receive() external payable;

  /// @notice The NFT this account is bound to. Read from the proxy's own appended immutable args.
  function token() external view returns (uint256 chainId, address tokenContract, uint256 tokenId);

  /// @notice Monotonic counter that MUST change on every state-changing operation, so that
  /// signature-based flows can detect that the account moved underneath them.
  function state() external view returns (uint256);

  /// @notice `IERC6551Account.isValidSigner.selector` when `signer` may act for this account.
  function isValidSigner(address signer, bytes calldata context) external view returns (bytes4 magicValue);
}

/// @notice The optional execution interface. `operation` 0 is CALL; anything else is out of scope.
interface IERC6551Executable {
  function execute(
    address to,
    uint256 value,
    bytes calldata data,
    uint8 operation
  ) external payable returns (bytes memory);
}
