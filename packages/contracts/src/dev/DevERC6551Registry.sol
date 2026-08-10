// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

/**
 * @title DevERC6551Registry
 * @notice Spec-compliant ERC-6551 registry (v0.3.1), deployed by `PostDeploy` on a LOCAL DEV CHAIN
 * ONLY so that the address the game derives identities from actually has code behind it.
 *
 * On any real network the canonical registry must be supplied through the `ERC6551_REGISTRY`
 * environment variable instead — `PostDeploy` reverts rather than silently freezing a throwaway
 * address into `ForgeConfig`, which is immutable after the first mint.
 *
 * The creation code below is the one the spec mandates, and the same one `CrystalIdentityLib`
 * hashes when it predicts an account address. The two must agree bit for bit, which is exactly what
 * `testEntityMatchesTheDeployedTokenBoundAccount` verifies by deploying through a registry and
 * comparing against the prediction.
 */
contract DevERC6551Registry {
  error AccountCreationFailed();

  event ERC6551AccountCreated(
    address account,
    address indexed implementation,
    bytes32 salt,
    uint256 chainId,
    address indexed tokenContract,
    uint256 indexed tokenId
  );

  function createAccount(
    address implementation,
    bytes32 salt,
    uint256 chainId,
    address tokenContract,
    uint256 tokenId
  ) external returns (address deployed) {
    bytes memory code = _creationCode(implementation, salt, chainId, tokenContract, tokenId);

    address predicted = _addressOf(keccak256(code), salt);
    if (predicted.code.length != 0) return predicted;

    assembly {
      deployed := create2(0, add(code, 0x20), mload(code), salt)
    }
    if (deployed == address(0)) revert AccountCreationFailed();

    emit ERC6551AccountCreated(deployed, implementation, salt, chainId, tokenContract, tokenId);
  }

  function account(
    address implementation,
    bytes32 salt,
    uint256 chainId,
    address tokenContract,
    uint256 tokenId
  ) external view returns (address) {
    return _addressOf(keccak256(_creationCode(implementation, salt, chainId, tokenContract, tokenId)), salt);
  }

  function _creationCode(
    address implementation,
    bytes32 salt,
    uint256 chainId,
    address tokenContract,
    uint256 tokenId
  ) internal pure returns (bytes memory) {
    return
      abi.encodePacked(
        hex"3d60ad80600a3d3981f3363d3d373d3d3d363d73",
        implementation,
        hex"5af43d82803e903d91602b57fd5bf3",
        abi.encode(salt, chainId, tokenContract, tokenId)
      );
  }

  function _addressOf(bytes32 codeHash, bytes32 salt) internal view returns (address) {
    // forge-lint: disable-next-line(unsafe-typecast)
    return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, codeHash)))));
  }
}

/**
 * @title DevERC6551AccountImpl
 * @notice Placeholder account implementation for local development.
 *
 * IT CANNOT ACT. It exists so the implementation address in `ForgeConfig` points at real code
 * rather than at nothing; account addresses are derived from it either way, since CREATE2 only
 * hashes the address. Making a token bound account able to CALL the World — so a crystal's owner
 * can drive it — remains phase 4 open point 2 and is deliberately not attempted here.
 */
contract DevERC6551AccountImpl {
  /// @notice The ERC-6551 immutable args are appended to the proxy's code, after the ERC-1167 body.
  function token() external view returns (uint256 chainId, address tokenContract, uint256 tokenId) {
    bytes memory footer = new bytes(0x60);
    assembly {
      extcodecopy(address(), add(footer, 0x20), 0x4d, 0x60)
    }
    return abi.decode(footer, (uint256, address, uint256));
  }
}
