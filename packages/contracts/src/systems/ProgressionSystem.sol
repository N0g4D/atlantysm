// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import { System } from "@latticexyz/world/src/System.sol";

import { CrystalData, ManaBalance, StarterManaClaimed } from "../codegen/index.sol";

/**
 * @title ProgressionSystem
 * @notice The economic loop: a crystal draws a one-time mana grant, then spends mana to raise its
 * level. Stateless, like every other System here — all state lives in MUD tables.
 *
 * Mana is settled exclusively against `ManaBalance`, which is the single source of truth. There is
 * no ERC-20 anywhere in this contract, by design: the token interface is a facade to be built on
 * top of this table, never a thing to keep in sync with it.
 *
 * ---------------------------------------------------------------------------------------------
 * IDENTITY: WHY `_requireCrystal` IS THE TBA CHECK
 * ---------------------------------------------------------------------------------------------
 *
 * Both entry points must establish that the caller is the crystal's ERC-6551 account. They do it
 * the same way `ArenaSystem` does, and that is already sufficient:
 *
 *   entity = bytes32(uint256(uint160(_msgSender())))   // the caller, widened
 *   require CrystalData.level(entity) != 0             // a crystal lives at that entity
 *
 * The second line IS the identity proof, not a mere existence check. `CrystalForgeSystem` only ever
 * writes `CrystalData` at `_entityOf(_accountOf(tokenId))` — a token bound account address and
 * nothing else. So an address at which crystal data exists is, by construction, a TBA. An EOA that
 * calls here derives an entity with no crystal record and is rejected.
 *
 * The stronger round-trip — read the stored `tokenId`, re-derive the account through `ForgeConfig`,
 * compare against `_msgSender()` — was deliberately not used. It costs a three-slot config read plus
 * a keccak on every call, it couples progression to forge configuration (progression would break if
 * the config were ever cleared), and the only thing it additionally catches is `CrystalData` written
 * at a non-TBA entity, which requires namespace-owner privileges and therefore sits inside the trust
 * boundary already.
 *
 * ---------------------------------------------------------------------------------------------
 * SECURITY NOTES
 * ---------------------------------------------------------------------------------------------
 *
 * 1. REENTRANCY IN `claimStarterMana` IS FULLY CLOSED. The claim flag is written BEFORE the mana is
 *    credited, so a store hook that re-enters during the credit observes `claimed == true` and
 *    reverts. This is the same "terminal state before the value moves" rule `ArenaSystem` uses.
 *
 * 2. REENTRANCY IN `levelUp` CANNOT BE FULLY CLOSED, AND FAILS SAFE INSTEAD. Levelling is
 *    repeatable by design, so there is no terminal state to close the door with, and a System must
 *    stay storage-free so a mutex is not available. Both writes read-then-write, so whichever runs
 *    first leaves the other's input stale for a re-entrant call. The ordering here is chosen so the
 *    stale read can only ever hurt the caller, never the protocol:
 *      - Mana is debited FIRST, the level is raised SECOND.
 *      - A re-entrant `levelUp` therefore reads an already-debited balance and a not-yet-raised
 *        level: it pays the current level's price again for the same level. The caller overpays.
 *      - The opposite order would let a re-entrant call read the raised level against an
 *        undebited balance, and the outer write would then overwrite the inner debit — two levels
 *        for one payment. That is the exploit this ordering exists to rule out.
 *    Installing a hook requires namespace-owner privileges, i.e. an actor that can already rewrite
 *    these tables directly, so the residual sits inside the trust boundary exactly as in
 *    `ArenaSystem` note 1.
 *
 * 3. THE LEVEL CEILING IS GUARDED — BUT NOT AGAINST A SILENT WRAP, WHICH CANNOT HAPPEN HERE.
 *    `CrystalData.level` is a `uint8`, and Solidity 0.8 checked arithmetic already makes `level + 1`
 *    revert at 255, so the genuinely dangerous outcome — wrapping to 0, which every System reads as
 *    "no such crystal" — is unreachable as written. The explicit guard buys two lesser but real
 *    things: a named `Progression_MaxLevelReached` instead of an opaque `Panic(0x11)`, and a check
 *    that survives a future refactor into an `unchecked` block, where the silent wrap WOULD become
 *    reachable and would strand the crystal permanently.
 *
 * 4. THE FAUCET MINTS AND LEVELLING BURNS, SO GLOBAL MANA IS NO LONGER CONSERVED. This is
 *    deliberate — it is what makes an economy rather than a closed ledger — but it invalidates any
 *    assumption of a fixed supply. Note that `ArenaSystem`'s conservation invariant is unaffected:
 *    it asserts that *settlement* neither mints nor burns, which remains true. Only the global
 *    supply moves, and only through this System.
 *
 * 5. THE FAUCET IS FREE AND UNGATED BEYOND ONE-PER-CRYSTAL. Minting is itself permissionless and
 *    free (see `CrystalForgeSystem` note 1), so anyone can forge N crystals and drain N grants.
 *    The one-shot flag bounds mana per crystal, not per human. Sybil resistance has to come from
 *    gating the forge, not from here.
 */
contract ProgressionSystem is System {
  /// @dev One-time grant. Sized in the same 18-decimal scale as every other mana amount.
  uint128 internal constant STARTER_MANA = 100 ether;

  /// @dev Cost of the next level is this times the CURRENT level, so the ladder steepens linearly.
  uint128 internal constant LEVEL_UP_COST_PER_LEVEL = 50 ether;

  /// @dev `CrystalData.level` is a uint8; raising this would wrap it to 0. See security note 3.
  uint8 internal constant MAX_LEVEL = type(uint8).max;

  /// @notice Emitted when a crystal draws its one and only starter grant.
  event StarterManaGranted(bytes32 indexed entity, uint128 amount, uint128 newBalance);

  /// @notice Emitted on a successful level up. `cost` is the mana burned to get there.
  event CrystalLeveledUp(bytes32 indexed entity, uint8 newLevel, uint128 cost, uint128 newBalance);

  error Progression_UnknownCrystal(bytes32 entity);
  error Progression_StarterManaAlreadyClaimed(bytes32 entity);
  error Progression_InsufficientMana(bytes32 entity, uint128 balance, uint128 required);
  error Progression_MaxLevelReached(bytes32 entity, uint8 level);
  error Progression_ManaOverflow(bytes32 entity);

  // -----------------------------------------------------------------------------------------
  // Faucet
  // -----------------------------------------------------------------------------------------

  /**
   * @notice Draw the one-time starter grant. Callable by the crystal's token bound account only,
   * and exactly once for the life of that crystal.
   * @return amount The mana granted.
   */
  function claimStarterMana() public returns (uint128 amount) {
    bytes32 entity = _entityOf(_msgSender());
    _requireCrystal(entity);

    if (StarterManaClaimed.getClaimed(entity)) revert Progression_StarterManaAlreadyClaimed(entity);

    uint256 credited = uint256(ManaBalance.getAmount(entity)) + STARTER_MANA;
    if (credited > type(uint128).max) revert Progression_ManaOverflow(entity);

    // Flag first, mana second: a hook re-entering during the credit sees the claim already spent
    // and reverts (security note 1).
    StarterManaClaimed.setClaimed(entity, true);

    // Bounded by the check above.
    // forge-lint: disable-next-line(unsafe-typecast)
    uint128 newBalance = uint128(credited);
    ManaBalance.setAmount(entity, newBalance);

    amount = STARTER_MANA;
    emit StarterManaGranted(entity, amount, newBalance);
  }

  // -----------------------------------------------------------------------------------------
  // Levelling
  // -----------------------------------------------------------------------------------------

  /**
   * @notice Spend mana to raise this crystal's level by one. Callable by the crystal's token bound
   * account only. The mana is burned, not transferred.
   * @return newLevel The level after the increase.
   */
  function levelUp() public returns (uint8 newLevel) {
    bytes32 entity = _entityOf(_msgSender());

    uint8 level = CrystalData.getLevel(entity);
    if (level == 0) revert Progression_UnknownCrystal(entity);
    if (level >= MAX_LEVEL) revert Progression_MaxLevelReached(entity, level);

    uint128 cost = _levelUpCost(level);
    uint128 balance = ManaBalance.getAmount(entity);
    if (balance < cost) revert Progression_InsufficientMana(entity, balance, cost);

    // Checks are done; every write below is an effect. Debit BEFORE raising the level, so a
    // re-entrant call can only overpay and never gain a free level (security note 2).
    uint128 newBalance = balance - cost;
    ManaBalance.setAmount(entity, newBalance);

    newLevel = level + 1;
    CrystalData.setLevel(entity, newLevel);

    emit CrystalLeveledUp(entity, newLevel, cost, newBalance);
  }

  // -----------------------------------------------------------------------------------------
  // Views
  // -----------------------------------------------------------------------------------------

  /**
   * @notice What the next level would cost this crystal right now. Reverts for an unknown crystal
   * rather than returning 0, which would read as "free".
   */
  function levelUpCost(bytes32 entity) public view returns (uint128) {
    uint8 level = CrystalData.getLevel(entity);
    if (level == 0) revert Progression_UnknownCrystal(entity);
    return _levelUpCost(level);
  }

  /// @notice Whether this crystal can still draw its starter grant.
  function canClaimStarterMana(bytes32 entity) public view returns (bool) {
    return CrystalData.getLevel(entity) != 0 && !StarterManaClaimed.getClaimed(entity);
  }

  // -----------------------------------------------------------------------------------------
  // Internals
  // -----------------------------------------------------------------------------------------

  /// @dev Cannot overflow: level is a uint8, so the product peaks at 50e18 * 255 ~= 1.3e22, far
  /// below the uint128 ceiling of ~3.4e38.
  function _levelUpCost(uint8 level) internal pure returns (uint128) {
    return LEVEL_UP_COST_PER_LEVEL * uint128(level);
  }

  /// @dev Must stay bit-identical to `ArenaSystem._entityOf` and `CrystalForgeSystem._entityOf`.
  function _entityOf(address account) internal pure returns (bytes32) {
    return bytes32(uint256(uint160(account)));
  }

  /**
   * @dev The identity check. A crystal record can only exist at a token bound account address, so
   * this simultaneously proves existence and that the caller is that account. See the identity
   * section above.
   */
  function _requireCrystal(bytes32 entity) internal view {
    if (CrystalData.getLevel(entity) == 0) revert Progression_UnknownCrystal(entity);
  }
}
