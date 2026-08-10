// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { IWorld } from "../codegen/world/IWorld.sol";

/**
 * @title ManaToken
 * @notice ERC-20 projection of the mana held in MUD. Holds NO balance state of its own.
 *
 * ---------------------------------------------------------------------------------------------
 * WHAT LIVES WHERE
 * ---------------------------------------------------------------------------------------------
 *
 *   Balances (`_balances`)      -> MUD `ManaBalance`, keyed by entity, read via `manaBalanceOf`
 *   Supply (`_totalSupply`)     -> MUD `ManaSupply`, read via `manaTotalSupply`
 *   Allowances                  -> STAY HERE, in the facade's own storage
 *
 * Allowances are a token-protocol concern the game never reads, so they do not earn a MUD table.
 *
 * An address's mana lives at its ENTITY, `bytes32(uint256(uint160(addr)))`. For a crystal that is
 * its ERC-6551 account; for an EOA it is simply an address at which no crystal stands. Such an
 * address can hold and move mana — otherwise this would not be a real ERC-20 — but it can never USE
 * it: `createLobby`, `claimStarterMana` and `levelUp` each independently require a crystal at the
 * caller's entity. The TBA identity model is enforced where it decides outcomes, not at the token
 * layer, so wrapping mana never becomes a way around it.
 *
 * ---------------------------------------------------------------------------------------------
 * A LIMIT WORTH READING BEFORE TRUSTING THE EVENT LOG
 * ---------------------------------------------------------------------------------------------
 *
 * `Transfer` events are emitted here for holder-to-holder movement only. They are NOT emitted for:
 *   - issuance by `ProgressionSystem.claimStarterMana`
 *   - destruction by `ProgressionSystem.levelUp`
 *   - arena settlement in `ArenaSystem`
 *
 * The reason is structural, not an oversight. Solidity events can only be emitted by the contract
 * that declares them, but those balance changes happen inside MUD Systems called directly by a
 * crystal's account — and they MUST be, because each is gated on the caller's identity. Routing
 * them through this contract would make `_msgSender()` the token rather than the crystal and break
 * the very check that protects them.
 *
 * Consequences for consumers, stated plainly:
 *   - `balanceOf` and `totalSupply` are ALWAYS correct: they are read straight from MUD.
 *   - An indexer that reconstructs balances from `Transfer` events alone WILL drift. The canonical
 *     stream is MUD's own `Store_SetRecord` / `Store_SpliceStaticData` on `ManaBalance`.
 *   - The framework-native fix, if event-completeness is ever required, is MUD's delegation
 *     mechanism (`world.callFrom`): a crystal account delegates to this contract, which then calls
 *     the System on its behalf, preserving `_msgSender()` while regaining the ability to emit.
 *     That is a design decision with its own trust implications and was left out of this phase.
 */
contract ManaToken is ERC20 {
  /// @notice The MUD World that owns all mana state.
  IWorld public immutable world;

  error ManaToken_IssuanceNotSupported();
  error ManaToken_BurnNotSupported();

  constructor(IWorld _world) ERC20("Atlantysm Mana", "MANA") {
    world = _world;
  }

  // -----------------------------------------------------------------------------------------
  // Projections of MUD state
  // -----------------------------------------------------------------------------------------

  function totalSupply() public view override returns (uint256) {
    return world.app__manaTotalSupply();
  }

  function balanceOf(address account) public view override returns (uint256) {
    return world.app__manaBalanceOf(account);
  }

  // -----------------------------------------------------------------------------------------
  // The single mutation seam
  // -----------------------------------------------------------------------------------------

  /**
   * @dev Delegates the ledger write to MUD. Issuance and destruction are rejected here on purpose:
   * mana enters circulation only through the faucet and leaves it only through levelling, both of
   * which are identity-gated game actions that cannot be reached from a token contract.
   */
  function _update(address from, address to, uint256 value) internal override {
    if (from == address(0)) revert ManaToken_IssuanceNotSupported();
    if (to == address(0)) revert ManaToken_BurnNotSupported();

    world.app__transferMana(from, to, value);

    emit Transfer(from, to, value);
  }
}
