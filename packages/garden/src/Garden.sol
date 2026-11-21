// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FHE, euint8, euint64} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/**
 * @title Garden
 * @notice Atlantysm Season 0 (docs/RULES.md). Every crystal is an ERC-721 token whose element, level and MANA only
 *         its owner can read.
 * @dev One contract holds every encrypted value, and nobody can change it (docs/SEASON0.md §2): no owner, no admin,
 *      no proxy, no pause, no setter. A fix is a new deployment. Every rule parameter is fixed at construction.
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
    /// The deployment time, when season 1 starts.
    uint256 public immutable GENESIS;

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

    error InvalidParams();
    error WrongCharge();
    error NotOwner();
    error ChargeNotReturned();
    error TransfersNotOpen();

    constructor(Params memory params) ERC721("Atlantysm Crystal", "CRYSTAL") {
        // Accrual credits one MANA every SECONDS_PER_MANA, so a day must divide into whole steps (SEASON0.md §2.2).
        bool wholeSteps = params.manaPerDay != 0 && 1 days % params.manaPerDay == 0;
        if (params.charge == 0 || !wholeSteps || params.seasonLength == 0) revert InvalidParams();
        CHARGE = params.charge;
        MANA_PER_DAY = params.manaPerDay;
        SECONDS_PER_MANA = uint64(1 days / params.manaPerDay);
        SEASON_LENGTH = params.seasonLength;
        GENESIS = block.timestamp;
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
        // One chance in three each, from encrypted on-chain randomness. 65,536 mod 3 = 1, so Fire (0) has one more
        // draw than Earth or Water out of 65,536.
        crystal.element = _seal(FHE.asEuint8(FHE.rem(FHE.randEuint16(), 3)), msg.sender);
        // Every crystal starts at level 1 with no MANA. Both are public facts, so encrypting them from plaintext
        // reveals nothing (SEASON0.md §2.3, rule 3).
        crystal.level = _seal(FHE.asEuint8(1), msg.sender);
        crystal.mana = _seal(FHE.asEuint64(0), msg.sender);
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
        _pots[season] = FHE.allowThis(FHE.add(_pots[season], _accrue(_crystals[tokenId])));

        delete _crystals[tokenId];
        --totalSupply;
        _burn(tokenId);
        emit Shattered(tokenId);

        // Last, after every effect (SEASON0.md §2.3, rule 6). RULES.md §3, invariant 1: the charge always returns.
        (bool sent,) = msg.sender.call{value: CHARGE}("");
        if (!sent) revert ChargeNotReturned();
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
     *      whole MANA accrued since `lastAccrual` and returns the new balance, for the caller to store or spend.
     *      `lastAccrual` moves by whole MANA, not to now, so the remainder waits for the next call.
     */
    function _accrue(Crystal storage crystal) internal returns (euint64) {
        uint64 units = _pendingMana(crystal);
        crystal.lastAccrual += units * SECONDS_PER_MANA;
        return FHE.add(crystal.mana, units);
    }

    function _pendingMana(Crystal storage crystal) internal view returns (uint64) {
        return (uint64(block.timestamp) - crystal.lastAccrual) / SECONDS_PER_MANA;
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
