// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FHE, ebool, euint8, euint16, euint64, externalEbool} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/**
 * @title Garden
 * @notice Atlantysm Season 0 (docs/RULES.md). Every crystal is an ERC-721 token whose element, level and MANA only
 *         its owner can read.
 * @dev One contract holds every encrypted value, and nobody can change it (docs/SEASON0.md §2): no owner, no admin,
 *      no proxy, no pause, no setter. A fix is a new deployment. Every rule parameter is fixed at construction.
 *
 *      The protocol derives a handle from its operation, its operands and the block, so whoever is allowed on every
 *      operand of an operation can recompute its result in that block and grant it to anyone, and anyone can
 *      recompute a trivial encryption. No handle this contract stores can be recomputed by anyone but itself and the
 *      crystal's owner (SEASON0.md §2.2, Handles).
 */
contract Garden is ZamaEthereumConfig, ERC721, ReentrancyGuardTransient {
    /// The parameters of RULES.md §12, fixed at deployment.
    struct Params {
        /// The ETH a crystal holds: paid to forge it, returned when it is shattered.
        uint256 charge;
        /// The MANA every crystal receives a day.
        uint64 manaPerDay;
        /// How long a season lasts, in seconds.
        uint256 seasonLength;
        /// A rise from level L to L + 1 costs `levelCost × L²` MANA.
        uint64 levelCost;
        /// The highest level a crystal can reach.
        uint8 maxLevel;
    }

    /// SEASON0.md §2.1. A crystal's handles are granted to this contract and to its owner only.
    struct Crystal {
        euint8 element; // 0 = Fire, 1 = Earth, 2 = Water
        euint8 level;
        euint64 mana; // whole MANA, credited up to lastAccrual
        uint64 lastAccrual;
    }

    /// What anyone can read about a crystal: its public fields, and the handles that only its owner can decrypt.
    struct CrystalView {
        address owner;
        euint8 element;
        euint8 level;
        euint64 mana;
        uint64 lastAccrual;
        /// The MANA accrued since `lastAccrual` and not yet credited. It joins `mana` when the crystal next acts, so
        /// the balance as of now is `mana` plus this.
        uint64 pendingMana;
    }

    uint256 public immutable CHARGE;
    uint64 public immutable MANA_PER_DAY;
    /// Accrual counts whole MANA, one every SECONDS_PER_MANA.
    uint64 public immutable SECONDS_PER_MANA;
    uint256 public immutable SEASON_LENGTH;
    /// A rise from level L to L + 1 costs LEVEL_COST × L² MANA (RULES.md §6).
    uint64 public immutable LEVEL_COST;
    uint8 public immutable MAX_LEVEL;
    /// The deployment time, when season 1 starts.
    uint256 public immutable GENESIS;
    /// An encrypted zero that only this contract holds, drawn at construction. A value that must be unreachable starts
    /// from it rather than from an encrypted plaintext 0, which anyone can reproduce.
    euint64 internal immutable GARDEN_ZERO;

    /// Live crystals: forged and not shattered.
    uint256 public totalSupply;
    /// The id of the latest crystal forged. Ids start at 1 and are never reused.
    uint256 public lastTokenId;

    mapping(uint256 tokenId => Crystal) internal _crystals;
    /// The centre (RULES.md §8), one pot per season. Only this contract can use a pot: nobody may read its total.
    mapping(uint256 season => euint64) internal _pots;

    // Public data only (SEASON0.md §2.3, rule 2).
    event Forged(uint256 indexed tokenId, address indexed owner);
    event Shattered(uint256 indexed tokenId);
    /// The same for a rise, a refused rise and a hold (RULES.md §6).
    event Attuned(uint256 indexed tokenId);

    error InvalidParams();
    error WrongCharge();
    error NotOwner();
    error ChargeNotReturned();
    error TransfersNotOpen();
    error MissingProof();

    constructor(Params memory params) ERC721("Atlantysm Crystal", "CRYSTAL") {
        // Accrual credits one MANA every SECONDS_PER_MANA, so a day must divide into whole steps (SEASON0.md §2.2).
        bool wholeSteps = params.manaPerDay != 0 && 1 days % params.manaPerDay == 0;
        // A crystal is born at level 1, so the maximum must leave a level to rise to, and a rise must cost something.
        // `attune` squares the level in a euint8, which holds 15² = 225 but not 16². And the cost it computes, up to
        // levelCost × maxLevel², must fit in a euint64, where it would wrap silently.
        bool levels = params.maxLevel >= 2 && params.maxLevel <= 15 && params.levelCost != 0
            && uint256(params.levelCost) * params.maxLevel * params.maxLevel <= type(uint64).max;
        if (params.charge == 0 || !wholeSteps || params.seasonLength == 0 || !levels) revert InvalidParams();
        CHARGE = params.charge;
        MANA_PER_DAY = params.manaPerDay;
        SECONDS_PER_MANA = uint64(1 days / params.manaPerDay);
        SEASON_LENGTH = params.seasonLength;
        LEVEL_COST = params.levelCost;
        MAX_LEVEL = params.maxLevel;
        GENESIS = block.timestamp;
        // Zero, whatever the draw. Nobody else is ever allowed on the draw, so nobody else can reproduce the handle.
        GARDEN_ZERO = FHE.allowThis(FHE.and(FHE.randEuint64(), 0));
    }

    // -- Crystals (RULES.md §4) --------------------------------------------------------------------------------

    /// Forges a crystal for the sender, who pays the charge. Its element is drawn here, and nobody chooses it.
    function forge() external payable returns (uint256 tokenId) {
        if (msg.value != CHARGE) revert WrongCharge();
        tokenId = ++lastTokenId;
        ++totalSupply;
        // `_mint`, not `_safeMint`: the forger is the caller, and a safe mint would call back into it mid-forge.
        _mint(msg.sender, tokenId);

        Crystal storage crystal = _crystals[tokenId];
        euint16 draw = FHE.randEuint16();
        // One chance in three each, from encrypted on-chain randomness. 65,536 mod 3 = 1, so Fire (0) has one more
        // draw than Earth or Water out of 65,536.
        crystal.element = _seal(FHE.asEuint8(FHE.rem(draw, 3)), msg.sender);
        // Level 1 and no MANA are public facts, but `asEuint8(1)` and `asEuint64(0)` would give every crystal forged
        // in this block the same two handles, which any contract could also make and grant to anyone. Computed from
        // the draw, which only this contract ever holds, they belong to this crystal alone. The zero runs beside the
        // element's `rem`, so it adds nothing to the depth.
        euint16 zero = FHE.and(draw, 0);
        crystal.level = _seal(FHE.asEuint8(FHE.or(zero, 1)), msg.sender);
        crystal.mana = _seal(FHE.asEuint64(zero), msg.sender);
        crystal.lastAccrual = uint64(block.timestamp);
        emit Forged(tokenId, msg.sender);
    }

    /**
     * @notice Burns the sender's crystal and returns its charge. In Season 0 the crystal's unspent MANA returns to
     *         the centre.
     */
    function shatter(uint256 tokenId) external nonReentrant {
        // `ownerOf` reverts for a crystal that was never forged or is already shattered.
        if (ownerOf(tokenId) != msg.sender) revert NotOwner();

        // The MANA accrued so far goes with the rest (SEASON0.md §2.2), into the pot of the season in progress.
        uint256 season = currentSeason();
        _pots[season] = FHE.allowThis(FHE.add(_potOf(season), _accrue(_crystals[tokenId])));

        delete _crystals[tokenId];
        --totalSupply;
        _burn(tokenId);
        emit Shattered(tokenId);

        // Last, after every effect (SEASON0.md §2.3, rule 6). RULES.md §3, invariant 1: the charge always returns.
        (bool sent,) = msg.sender.call{value: CHARGE}("");
        if (!sent) revert ChargeNotReturned();
    }

    // -- The Sanctuary (RULES.md §6) ---------------------------------------------------------------------------

    /**
     * @notice Attunes the sender's crystal with an encrypted choice, rise or hold. On a rise that its MANA covers,
     *         below MAX_LEVEL, the crystal pays LEVEL_COST × level² MANA into the centre and rises one level.
     *         Otherwise nothing changes. A rise, a refused rise and a hold look the same from outside.
     * @param rise  `true` to rise, encrypted by the owner's client for this contract and the sender.
     * @param proof The input's proof, which must not be empty.
     */
    function attune(uint256 tokenId, externalEbool rise, bytes calldata proof) external {
        // `ownerOf` reverts for a crystal that was never forged or is already shattered.
        address owner = ownerOf(tokenId);
        if (owner != msg.sender) revert NotOwner();
        // With an empty proof, `FHE.fromExternal` takes any ebool that the sender and this contract are allowed on,
        // and the zero handle as an encrypted plaintext `false`. Either way the choice could be public, a hold that
        // anyone reads in the calldata. With a proof, it was encrypted by the owner's client, and only this contract
        // can import it. The calldata is public, so the check reads no secret.
        if (proof.length == 0) revert MissingProof();

        Crystal storage crystal = _crystals[tokenId];
        euint64 mana = _accrue(crystal);
        euint8 level = crystal.level;
        // The level never exceeds MAX_LEVEL, at most 15, so its square fits in a euint8. The constructor keeps the
        // cost within a euint64.
        euint64 cost = FHE.mul(FHE.asEuint64(FHE.mul(level, level)), LEVEL_COST);
        // Every operation runs whatever the secrets are, and `select` keeps one side (SEASON0.md §2.3, rule 1). The
        // MANA check goes last because it waits on the cost, so only one `and` follows the cost.
        ebool rises = FHE.and(FHE.and(FHE.fromExternal(rise, proof), FHE.lt(level, MAX_LEVEL)), FHE.ge(mana, cost));
        // On a hold or a refused rise, `spent` is an encrypted 0 and the level keeps its value. Every value stored below
        // still gets a new handle: an unchanged handle would tell everyone that nothing had changed.
        euint64 spent = FHE.select(rises, cost, FHE.asEuint64(0));

        crystal.level = _seal(FHE.select(rises, FHE.add(level, 1), level), owner);
        crystal.mana = _seal(FHE.sub(mana, spent), owner);
        // RULES.md §3, invariant 5: what a rise spends goes to the centre, into the pot of the season in progress.
        uint256 season = currentSeason();
        _pots[season] = FHE.allowThis(FHE.add(_potOf(season), spent));
        emit Attuned(tokenId);
    }

    // -- Views -------------------------------------------------------------------------------------------------

    /// A live crystal's public fields and its handles. Reverts for a crystal that does not exist.
    function crystalOf(uint256 tokenId) external view returns (CrystalView memory) {
        address owner = _requireOwned(tokenId);
        Crystal storage crystal = _crystals[tokenId];
        return CrystalView({
            owner: owner,
            element: crystal.element,
            level: crystal.level,
            mana: crystal.mana,
            lastAccrual: crystal.lastAccrual,
            pendingMana: _pendingMana(crystal)
        });
    }

    /**
     * @notice The crystals `owner` holds among the ids from `cursor` to `cursor + count - 1`, and the id the next
     *         page starts from, 0 when no id is left. A cursor of 0 starts from the first crystal. A page scans
     *         `count` ids however many it finds, so its cost does not grow with the number of crystals.
     */
    function crystalsOf(address owner, uint256 cursor, uint256 count)
        external
        view
        returns (uint256[] memory tokenIds, uint256 next)
    {
        // Shattered crystals belong to the zero address, which owns nothing, as for `balanceOf`.
        if (owner == address(0)) revert ERC721InvalidOwner(address(0));
        uint256 last = lastTokenId;
        if (cursor == 0) cursor = 1;
        if (cursor > last) return (new uint256[](0), 0);
        // The last id this page scans. With `count` at 0 it falls just before `cursor`, so the page is empty and the
        // next one starts where this one did.
        uint256 end = count > last - cursor ? last : cursor + count - 1;

        tokenIds = new uint256[](end + 1 - cursor);
        uint256 found;
        for (uint256 id = cursor; id <= end; ++id) {
            if (_ownerOf(id) == owner) tokenIds[found++] = id;
        }
        // Trim the array to what was found.
        assembly ("memory-safe") {
            mstore(tokenIds, found)
        }
        next = end < last ? end + 1 : 0;
    }

    /// Seasons follow one another from the deployment, the first numbered 1.
    function currentSeason() public view returns (uint256) {
        return (block.timestamp - GENESIS) / SEASON_LENGTH + 1;
    }

    /// The handle of a season's pot, 0 until the pot receives MANA. Nobody can decrypt it.
    function potOf(uint256 season) external view returns (euint64) {
        return _pots[season];
    }

    // -- Internal ----------------------------------------------------------------------------------------------

    /**
     * @dev SEASON0.md §2.2, Accrual: plaintext, and first in every call that touches a crystal's MANA. Credits the
     *      whole MANA accrued since `lastAccrual` to `crystal.mana`, and returns the new balance. `lastAccrual` moves
     *      by whole MANA, not to now, so the remainder waits for the next call.
     *
     *      The credit is stored, and kept for this contract, at once. So a call that reads `crystal.mana` afterwards,
     *      or accrues twice, still finds it. And a call that ends without granting the owner its balance cannot lock
     *      the crystal: the next action, or a shatter, still computes on it. Granting the owner the balance the call
     *      ends with is the caller's part.
     */
    function _accrue(Crystal storage crystal) internal returns (euint64 mana) {
        uint64 units = _pendingMana(crystal);
        crystal.lastAccrual += units * SECONDS_PER_MANA;
        mana = FHE.allowThis(FHE.add(crystal.mana, units));
        crystal.mana = mana;
    }

    function _pendingMana(Crystal storage crystal) internal view returns (uint64) {
        return (uint64(block.timestamp) - crystal.lastAccrual) / SECONDS_PER_MANA;
    }

    /**
     * @dev A season's pot, from GARDEN_ZERO while it is empty. For an empty handle `FHE.add` would use an encrypted
     *      plaintext 0, and a shatterer holding the crystal's MANA handle could then recompute the season's first pot
     *      in the same block.
     */
    function _potOf(uint256 season) internal view returns (euint64 pot) {
        pot = _pots[season];
        if (!FHE.isInitialized(pot)) pot = GARDEN_ZERO;
    }

    /// A stored handle is granted to this contract, to use it later, and to the crystal's owner, to read it, and to
    /// nobody else (SEASON0.md §2.3, rule 5).
    function _seal(euint8 value, address owner) internal returns (euint8) {
        FHE.allowThis(value);
        FHE.allow(value, owner);
        return value;
    }

    function _seal(euint64 value, address owner) internal returns (euint64) {
        FHE.allowThis(value);
        FHE.allow(value, owner);
        return value;
    }

    /**
     * @dev Crystals only appear and disappear for now: forging mints, shattering burns. A transfer must seal the level
     *      and MANA again for the new owner, so that the previous owner loses sight of them (RULES.md §4). Until it
     *      does (T07), a transfer would leave them readable by the previous owner and unreadable by the new one, so
     *      it is refused.
     */
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (to != address(0) && _ownerOf(tokenId) != address(0)) revert TransfersNotOpen();
        return super._update(to, tokenId, auth);
    }
}
