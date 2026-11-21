// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FHE, ebool, euint8, euint64} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";

/**
 * @dev Throwaway (T02). The duel of SEASON0.md §2.2, written before Garden so that two questions are answered
 *      first: does it give the outcomes of RULES.md §7, and what does joining cost in HCU? T05 builds the real
 *      `joinLobby` and `publish` from it.
 *
 *      It keeps only what Join and Publish read: crystals with given elements, levels and MANA, accrual, a
 *      lobby that records whether its creator paid, and lifetime records. No ERC-721, no seasons, no cancel.
 */
contract DuelSpike is ZamaEthereumConfig {
    /// RULES.md §12: 100 MANA a day, so one MANA every 864 seconds.
    uint64 public constant SECONDS_PER_MANA = 1 days / 100;

    struct Crystal {
        address owner;
        euint8 element; // 0 = Fire, 1 = Earth, 2 = Water (SEASON0.md §2.1)
        euint8 level;
        euint64 mana;
        uint64 lastAccrual;
        uint256 openLobby;
        uint32 wins;
        uint32 losses;
    }

    struct Lobby {
        uint256 crystal;
        uint64 stake;
        ebool creatorPaid;
        bool open;
    }

    struct Duel {
        uint256 creatorCrystal;
        uint256 challengerCrystal;
        uint64 stake;
        ebool creatorWins;
        bool published;
    }

    mapping(uint256 tokenId => Crystal) internal crystals;
    mapping(uint256 lobbyId => Lobby) internal lobbies;
    mapping(uint256 duelId => Duel) internal duels;
    // Ids start at 1, so that 0 can mean "none".
    uint256 public crystalCount;
    uint256 public lobbyCount;
    uint256 public duelCount;

    // Public data only (SEASON0.md §2.3, rule 2).
    event LobbyOpened(uint256 lobbyId, uint256 tokenId, uint64 stake);
    event DuelFought(uint256 duelId, uint256 lobbyId, uint256 creatorCrystal, uint256 challengerCrystal);
    event DuelPublished(uint256 duelId, uint256 winner, uint256 loser);

    error NotOwner();
    error CrystalWaiting();
    error ZeroStake();
    error LobbyNotOpen();
    error SameCrystal();
    error UnknownDuel();
    error AlreadyPublished();

    /**
     * @dev Test fixture, standing in for `forge` and `attune`. Garden draws the element on-chain and raises the
     *      level through `attune`, and never encrypts a secret from a plaintext (SEASON0.md §2.3, rule 3).
     */
    function mint(address owner, uint8 element, uint8 level, uint64 mana) external returns (uint256 tokenId) {
        tokenId = ++crystalCount;
        Crystal storage crystal = crystals[tokenId];
        crystal.owner = owner;
        crystal.element = _keep(FHE.asEuint8(element), owner);
        crystal.level = _keep(FHE.asEuint8(level), owner);
        crystal.mana = _keep(FHE.asEuint64(mana), owner);
        crystal.lastAccrual = uint64(block.timestamp);
    }

    /// SEASON0.md §2.2, Open a lobby. Join reads the `creatorPaid` it stores.
    function openLobby(uint256 tokenId, uint64 stake) external returns (uint256 lobbyId) {
        Crystal storage crystal = crystals[tokenId];
        if (crystal.owner != msg.sender) revert NotOwner();
        if (crystal.openLobby != 0) revert CrystalWaiting();
        if (stake == 0) revert ZeroStake();

        euint64 mana = _accrue(crystal);
        ebool paid = FHE.ge(mana, stake);
        crystal.mana = _keep(FHE.sub(mana, FHE.select(paid, FHE.asEuint64(stake), FHE.asEuint64(0))), msg.sender);

        lobbyId = ++lobbyCount;
        lobbies[lobbyId] = Lobby({crystal: tokenId, stake: stake, creatorPaid: FHE.allowThis(paid), open: true});
        crystal.openLobby = lobbyId;
        emit LobbyOpened(lobbyId, tokenId, stake);
    }

    /// SEASON0.md §2.2, Join: the duel is fought here, and only its outcome is ever revealed.
    function joinLobby(uint256 lobbyId, uint256 tokenId) external returns (uint256 duelId) {
        Lobby storage lobby = lobbies[lobbyId];
        uint256 creatorCrystal = lobby.crystal;
        if (!lobby.open) revert LobbyNotOpen();
        if (crystals[tokenId].owner != msg.sender) revert NotOwner();
        if (tokenId == creatorCrystal) revert SameCrystal();
        if (crystals[tokenId].openLobby != 0) revert CrystalWaiting();

        // Closed before the duel calls into the FHE executor and the ACL: checks, effects, then interactions
        // (SEASON0.md §2.3, rule 6).
        lobby.open = false;
        crystals[creatorCrystal].openLobby = 0;
        ebool creatorWins = _fight(crystals[creatorCrystal], crystals[tokenId], lobby.stake, lobby.creatorPaid);

        duelId = ++duelCount;
        duels[duelId] = Duel({
            creatorCrystal: creatorCrystal,
            challengerCrystal: tokenId,
            stake: lobby.stake,
            creatorWins: creatorWins,
            published: false
        });
        emit DuelFought(duelId, lobbyId, creatorCrystal, tokenId);
    }

    /// SEASON0.md §2.2, Publish: anyone may submit the outcome, once, with the KMS proof of its decryption.
    function publish(uint256 duelId, bool creatorWon, bytes calldata proof) external {
        if (duelId == 0 || duelId > duelCount) revert UnknownDuel();
        Duel storage duel = duels[duelId];
        if (duel.published) revert AlreadyPublished();

        // The stored handle, never one the caller names: a proof then fits only the duel it was made for, and
        // only the value the KMS decrypted.
        bytes32[] memory handles = new bytes32[](1);
        handles[0] = FHE.toBytes32(duel.creatorWins);
        FHE.checkSignatures(handles, abi.encode(creatorWon), proof);

        duel.published = true;
        (uint256 winner, uint256 loser) =
            creatorWon ? (duel.creatorCrystal, duel.challengerCrystal) : (duel.challengerCrystal, duel.creatorCrystal);
        crystals[winner].wins++;
        crystals[loser].losses++;
        emit DuelPublished(duelId, winner, loser);
    }

    // -- Views ------------------------------------------------------------------------------------------------

    function manaOf(uint256 tokenId) external view returns (euint64) {
        return crystals[tokenId].mana;
    }

    function recordOf(uint256 tokenId) external view returns (uint32 wins, uint32 losses) {
        return (crystals[tokenId].wins, crystals[tokenId].losses);
    }

    function lobbyOf(uint256 tokenId) external view returns (uint256) {
        return crystals[tokenId].openLobby;
    }

    function creatorPaidOf(uint256 lobbyId) external view returns (ebool) {
        return lobbies[lobbyId].creatorPaid;
    }

    function creatorWinsOf(uint256 duelId) external view returns (ebool) {
        return duels[duelId].creatorWins;
    }

    function isPublished(uint256 duelId) external view returns (bool) {
        return duels[duelId].published;
    }

    // -- The duel ---------------------------------------------------------------------------------------------

    /**
     * @dev Join's encrypted lines, in the order SEASON0.md §2.2 writes them. A is the creator's crystal and B the
     *      challenger's. Every line runs on every join: nothing branches on a secret (SEASON0.md §2.3, rule 1),
     *      so a forfeit and a defeat cost the same and look the same from outside.
     */
    function _fight(Crystal storage a, Crystal storage b, uint64 stakeAmount, ebool paidA)
        private
        returns (ebool aWins)
    {
        euint64 manaA = _accrue(a);
        euint64 manaB = _accrue(b);
        // The stake is public, so encrypting it reveals nothing (SEASON0.md §2.3, rule 3).
        euint64 stake = FHE.asEuint64(stakeAmount);
        euint64 zero = FHE.asEuint64(0);

        ebool paidB = FHE.ge(manaB, stakeAmount);
        manaB = FHE.sub(manaB, FHE.select(paidB, stake, zero));

        // Exactly one side paid: the payer wins. Neither or both: elements and levels decide.
        aWins = FHE.select(FHE.xor(paidA, paidB), paidA, _normal(a, b));

        // Both stakes when both paid, the payer's own when the other forfeited, nothing when neither paid. No sum
        // here can wrap in Garden: each is at most the MANA in existence, which only accrual creates, at 100 a day
        // per crystal. The `mint` fixture is not bound by that.
        euint64 pot = FHE.add(FHE.select(paidA, stake, zero), FHE.select(paidB, stake, zero));
        a.mana = _keep(FHE.add(manaA, FHE.select(aWins, pot, zero)), a.owner);
        b.mana = _keep(FHE.add(manaB, FHE.select(aWins, zero, pot)), b.owner);

        FHE.allowThis(aWins);
        // The only value a duel reveals (SEASON0.md §2.3, rule 4).
        FHE.makePubliclyDecryptable(aWins);
    }

    /// Who wins on elements and levels alone: the triangle, then the higher level in a mirror, then a coin.
    function _normal(Crystal storage a, Crystal storage b) private returns (ebool) {
        ebool same = FHE.eq(a.element, b.element);
        // Fire > Earth > Water > Fire: with 0 = Fire, 1 = Earth, 2 = Water, each element beats the next one.
        ebool aBeatsB = FHE.eq(b.element, FHE.rem(FHE.add(a.element, 1), 3));
        // Drawn on every join, not only in a mirror of equal levels, so that nothing depends on the inputs.
        ebool coin = FHE.randEbool();
        ebool mirror = FHE.select(FHE.eq(a.level, b.level), coin, FHE.gt(a.level, b.level));
        return FHE.select(same, mirror, aBeatsB);
    }

    /**
     * @dev SEASON0.md §2.2, Accrual: plaintext, and first in every call that touches a crystal's MANA. It moves
     *      `lastAccrual` and returns the new balance, which the caller must store.
     */
    function _accrue(Crystal storage crystal) private returns (euint64) {
        uint64 units = (uint64(block.timestamp) - crystal.lastAccrual) / SECONDS_PER_MANA;
        // The remainder waits for the next call.
        crystal.lastAccrual += units * SECONDS_PER_MANA;
        return FHE.add(crystal.mana, units);
    }

    /// A stored handle is granted to the contract, to use it later, and to the crystal's owner, to read it, and
    /// to nobody else (SEASON0.md §2.3, rule 5).
    function _keep(euint64 value, address owner) private returns (euint64) {
        FHE.allowThis(value);
        FHE.allow(value, owner);
        return value;
    }

    function _keep(euint8 value, address owner) private returns (euint8) {
        FHE.allowThis(value);
        FHE.allow(value, owner);
        return value;
    }
}
