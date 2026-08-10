// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import { ForgeConfig, ForgeConfigData } from "../codegen/index.sol";

/**
 * @title CrystalIdentityLib
 * @notice The one definition of how a crystal's identity is derived.
 *
 * Extracted in phase 7 because a second System (`TokenBridgeSystem`) now needs the same
 * `tokenId -> account -> entity` mapping that `CrystalForgeSystem` performs at mint. Two
 * independent copies of an ERC-6551 CREATE2 derivation is precisely the kind of duplication that
 * diverges silently: a mismatch would not fail loudly, it would key transfers against entities that
 * do not exist while minting keyed them somewhere else.
 *
 * Every consumer MUST route through here. See architecture.md §3 for the ratified identity model.
 */
library CrystalIdentityLib {
  /**
   * @dev ERC-6551 account address, per the final spec (registry v0.3.1). The account need not be
   * deployed: CREATE2 makes the address deterministic, which is what lets identity exist before any
   * code does.
   *
   * creationCode = ERC-1167 header ++ implementation ++ ERC-1167 footer
   *                ++ abi.encode(salt, chainId, tokenContract, tokenId)
   * address      = CREATE2(registry, salt, keccak256(creationCode))
   */
  function accountOf(ForgeConfigData memory config, uint256 tokenId) internal view returns (address) {
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

  /// @dev An entity is an address widened to the ECS key type. Must stay bit-identical everywhere.
  function entityOf(address account) internal pure returns (bytes32) {
    return bytes32(uint256(uint160(account)));
  }

  /// @dev Convenience for callers that only hold a token id. Reads `ForgeConfig` from the store.
  function entityOfToken(uint256 tokenId) internal view returns (bytes32) {
    return entityOf(accountOf(ForgeConfig.get(), tokenId));
  }
}
