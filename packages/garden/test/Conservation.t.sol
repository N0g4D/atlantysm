// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ebool, euint64, externalEbool} from "@fhevm/solidity/lib/FHE.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Vm} from "forge-std/Vm.sol";
import {Garden} from "../src/Garden.sol";
import {GardenFixture} from "./utils/GardenFixture.sol";

/**
 * @dev Drives Garden through random sequences of forging, attuning, shattering, opening, cancelling and joining lobbies,
 *      publishing duels and waiting, one transaction per call. It keeps its own plaintext model of what should hold,
 *      worked out from the rules alone: which crystals are live, the level and MANA of each, what each season's pot
 *      holds, which lobbies are open and what their creators put up, and every crystal's record. Two inputs come from
 *      Garden's draws, because only Garden makes them: each crystal's element, and the coin of a mirror between equal
 *      levels, read from the executor's event rather than from the outcome.
 */
contract GardenHandler is CommonBase, StdUtils {
    /// RULES.md §12. Copies rather than Garden's own values, so that what the handler expects does not rest on the
    /// contract's arithmetic.
    uint256 internal constant SECONDS_PER_MANA = 864;
    uint256 internal constant SEASON_LENGTH = 3 days;
    uint256 internal constant LEVEL_COST = 50;
    uint256 internal constant MAX_LEVEL = 10;
    uint64 internal constant MIN_STAKE = 10;
    uint64 internal constant MAX_STAKE = 100;
    uint256 internal constant LOBBY_TIMEOUT = 24 hours;
    /// The executor's event for a random value: the coprocessor draws the coin from it, and the handler reads it back.
    bytes32 internal constant FHE_RAND = keccak256("FheRand(address,uint8,bytes16,bytes32)");

    struct Lobby {
        uint256 crystal;
        uint64 stake;
        uint256 openedAt;
        bool paid;
    }

    Garden internal immutable garden;
    /// Encrypts each choice, as the owner's client would.
    GardenFixture internal immutable fixture;
    /// When season 1 started: the deployment.
    uint256 internal immutable genesis;
    address[] internal actors;
    uint256[] internal live;
    mapping(uint256 tokenId => uint256) internal forgedAt;
    mapping(uint256 tokenId => uint256) internal lastCreditAt;
    /// What accrual credited to crystals that have since been shattered, each up to its shattering.
    uint256 internal creditedToShattered;

    mapping(uint256 tokenId => uint256) internal elementOf;
    /// The lobby each crystal waits in, 0 when none.
    mapping(uint256 tokenId => uint256) internal waitingIn;
    mapping(uint256 lobbyId => Lobby) internal lobbies;
    uint256[] internal openLobbies;
    /// The duels not yet published, and who should have won each.
    uint256[] internal pendingDuels;
    mapping(uint256 duelId => bool) internal creatorShouldWin;

    mapping(uint256 tokenId => uint256) public levelOf;
    mapping(uint256 tokenId => uint256) public manaOf;
    mapping(uint256 season => uint256) public potOf;
    mapping(uint256 tokenId => uint256) public winsOf;
    mapping(uint256 tokenId => uint256) public lossesOf;
    /// What the open lobbies hold: the stakes their creators put up.
    uint256 public staked;
    uint256 public rises;
    uint256 public duels;
    /// The duels whose stakes changed hands, because both crystals covered them.
    uint256 public stakesMoved;
    uint256 public published;

    constructor(Garden garden_, GardenFixture fixture_, address[] memory actors_) {
        garden = garden_;
        fixture = fixture_;
        genesis = block.timestamp;
        actors = actors_;
    }

    function forge(uint256 actorSeed) external {
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];
        uint256 charge = garden.CHARGE();
        vm.prank(actor);
        uint256 tokenId = garden.forge{value: charge}();
        live.push(tokenId);
        forgedAt[tokenId] = block.timestamp;
        lastCreditAt[tokenId] = block.timestamp;
        levelOf[tokenId] = 1;
        elementOf[tokenId] = fixture.plaintextElement(tokenId);
    }

    /// RULES.md §6: a rise that the MANA covers, below the maximum level, pays the cost into the season's pot.
    /// Anything else changes nothing but the credit.
    function attune(uint256 crystalSeed, bool rise) external {
        if (live.length == 0) return;
        uint256 tokenId = live[bound(crystalSeed, 0, live.length - 1)];
        address owner = garden.ownerOf(tokenId);
        (externalEbool choice, bytes memory proof) = fixture.encryptChoice(rise, owner);
        vm.prank(owner);
        garden.attune(tokenId, choice, proof);

        _credit(tokenId);
        uint256 cost = LEVEL_COST * levelOf[tokenId] * levelOf[tokenId];
        if (rise && levelOf[tokenId] < MAX_LEVEL && manaOf[tokenId] >= cost) {
            levelOf[tokenId]++;
            manaOf[tokenId] -= cost;
            potOf[_season()] += cost;
            rises++;
        }
    }

    /// RULES.md §4: a crystal waiting in a lobby cannot be shattered, so the handler only shatters free ones.
    function shatter(uint256 crystalSeed) external {
        (uint256 index, bool found) = _free(crystalSeed);
        if (!found) return;
        uint256 tokenId = live[index];
        live[index] = live[live.length - 1];
        live.pop();
        _credit(tokenId);
        potOf[_season()] += manaOf[tokenId];
        creditedToShattered += (block.timestamp - forgedAt[tokenId]) / SECONDS_PER_MANA;

        vm.prank(garden.ownerOf(tokenId));
        garden.shatter(tokenId);
    }

    /// RULES.md §7: the creator puts up the stake if its MANA covers it, and nothing otherwise.
    function openLobby(uint256 crystalSeed, uint256 stakeSeed) external {
        (uint256 index, bool found) = _free(crystalSeed);
        if (!found) return;
        uint256 tokenId = live[index];
        uint64 stake = uint64(bound(stakeSeed, MIN_STAKE, MAX_STAKE));
        vm.prank(garden.ownerOf(tokenId));
        uint256 lobbyId = garden.openLobby(tokenId, stake);

        _credit(tokenId);
        bool paid = manaOf[tokenId] >= stake;
        if (paid) {
            manaOf[tokenId] -= stake;
            staked += stake;
        }
        lobbies[lobbyId] = Lobby({crystal: tokenId, stake: stake, openedAt: block.timestamp, paid: paid});
        waitingIn[tokenId] = lobbyId;
        openLobbies.push(lobbyId);
    }

    /// RULES.md §7: from a day after opening, the creator cancels and takes back what it put up.
    function cancelLobby(uint256 lobbySeed) external {
        if (openLobbies.length == 0) return;
        uint256 index = bound(lobbySeed, 0, openLobbies.length - 1);
        uint256 lobbyId = openLobbies[index];
        Lobby memory lobby = lobbies[lobbyId];
        if (block.timestamp < lobby.openedAt + LOBBY_TIMEOUT) return;
        vm.prank(garden.ownerOf(lobby.crystal));
        garden.cancelLobby(lobbyId);

        _credit(lobby.crystal);
        if (lobby.paid) {
            manaOf[lobby.crystal] += lobby.stake;
            staked -= lobby.stake;
        }
        _close(index, lobby.crystal);
    }

    /**
     * @notice RULES.md §7: elements and levels decide, whoever covers the stake: the triangle, then the higher level in
     *         a mirror, then the coin. The challenger covers the stake if its MANA does. The stake changes hands only
     *         if both covered it, and then the winner takes both. Otherwise the creator takes back what it put up.
     */
    function joinLobby(uint256 lobbySeed, uint256 crystalSeed) external {
        if (openLobbies.length == 0) return;
        // A waiting crystal cannot join, the creator's own included.
        (uint256 crystalIndex, bool found) = _free(crystalSeed);
        if (!found) return;
        uint256 b = live[crystalIndex];
        uint256 index = bound(lobbySeed, 0, openLobbies.length - 1);
        uint256 lobbyId = openLobbies[index];
        Lobby memory lobby = lobbies[lobbyId];
        uint256 a = lobby.crystal;
        vm.recordLogs();
        vm.prank(garden.ownerOf(b));
        uint256 duelId = garden.joinLobby(lobbyId, b);
        bool coin = _coinOf(vm.getRecordedLogs());

        _close(index, a);
        _credit(a);
        _credit(b);
        bool aWins;
        if (elementOf[a] != elementOf[b]) {
            aWins = _beats(elementOf[a], elementOf[b]);
        } else if (levelOf[a] != levelOf[b]) {
            aWins = levelOf[a] > levelOf[b];
        } else {
            // The coin the join drew, read from the executor's event, not from the outcome.
            aWins = coin;
        }
        // The creator's stake, if it put one up, leaves the lobby either way.
        if (lobby.paid) staked -= lobby.stake;
        if (lobby.paid && manaOf[b] >= lobby.stake) {
            // Both covered the stake: the winner takes both.
            if (aWins) {
                manaOf[a] += 2 * lobby.stake;
                manaOf[b] -= lobby.stake;
            } else {
                manaOf[b] += lobby.stake;
            }
            stakesMoved++;
        } else if (lobby.paid) {
            manaOf[a] += lobby.stake;
        }
        creatorShouldWin[duelId] = aWins;
        pendingDuels.push(duelId);
        duels++;
    }

    /// RULES.md §7: anyone publishes, here an outsider, and the result the model expects counts in both records.
    function publish(uint256 duelSeed) external {
        if (pendingDuels.length == 0) return;
        uint256 index = bound(duelSeed, 0, pendingDuels.length - 1);
        uint256 duelId = pendingDuels[index];
        pendingDuels[index] = pendingDuels[pendingDuels.length - 1];
        pendingDuels.pop();
        (bool creatorWon, bytes memory proof) = fixture.outcomeWithProof(duelId);
        vm.prank(address(0xBEEF));
        garden.publish(duelId, creatorWon, proof);

        Garden.Duel memory duel = garden.duelOf(duelId);
        bool aWins = creatorShouldWin[duelId];
        winsOf[aWins ? duel.creatorCrystal : duel.challengerCrystal]++;
        lossesOf[aWins ? duel.challengerCrystal : duel.creatorCrystal]++;
        published++;
    }

    /// Up to two days at a time, so that runs cross from one season into the next.
    function wait(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 2 days));
        vm.roll(block.number + 1);
    }

    function liveCrystals() external view returns (uint256[] memory) {
        return live;
    }

    function lobbiesOpen() external view returns (uint256[] memory) {
        return openLobbies;
    }

    function paidOf(uint256 lobbyId) external view returns (bool) {
        return lobbies[lobbyId].paid;
    }

    /**
     * @notice The MANA accrual should have credited so far. A crystal last credited at `t` holds
     *         `(t - forgedAt) / SECONDS_PER_MANA` whole MANA in all, however many credits it took, because the remainder
     *         of each credit waits for the next.
     */
    function credited() external view returns (uint256 total) {
        total = creditedToShattered;
        for (uint256 i; i < live.length; i++) {
            total += (lastCreditAt[live[i]] - forgedAt[live[i]]) / SECONDS_PER_MANA;
        }
    }

    /// Credits what the crystal accrued since its last credit, in the same whole MANA as `credited`.
    function _credit(uint256 tokenId) internal {
        uint256 before = (lastCreditAt[tokenId] - forgedAt[tokenId]) / SECONDS_PER_MANA;
        manaOf[tokenId] += (block.timestamp - forgedAt[tokenId]) / SECONDS_PER_MANA - before;
        lastCreditAt[tokenId] = block.timestamp;
    }

    function _season() internal view returns (uint256) {
        return (block.timestamp - genesis) / SEASON_LENGTH + 1;
    }

    /// The index of a live crystal that waits in no lobby: the one the seed picks, or the next free one after it.
    function _free(uint256 seed) internal view returns (uint256 index, bool found) {
        if (live.length == 0) return (0, false);
        uint256 start = bound(seed, 0, live.length - 1);
        for (uint256 i; i < live.length; i++) {
            index = (start + i) % live.length;
            if (waitingIn[live[index]] == 0) return (index, true);
        }
        return (0, false);
    }

    /// The one random value a join draws, read from the executor's event as the coprocessor reads it.
    function _coinOf(Vm.Log[] memory logs) internal returns (bool) {
        bytes32 handle;
        uint256 draws;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == FHE_RAND) {
                (,, handle) = abi.decode(logs[i].data, (uint8, bytes16, bytes32));
                draws++;
            }
        }
        require(draws == 1, "one random value per join");
        return fixture.plaintextBool(ebool.wrap(handle));
    }

    /// The lobby at `index` is no longer open, and its crystal no longer waits.
    function _close(uint256 index, uint256 crystal) internal {
        openLobbies[index] = openLobbies[openLobbies.length - 1];
        openLobbies.pop();
        waitingIn[crystal] = 0;
    }

    /// RULES.md §7, as written there: Water beats Fire, Fire beats Earth, Earth beats Water. Fire is 0, Earth 1 and
    /// Water 2 (SEASON0.md §2.1).
    function _beats(uint256 x, uint256 y) internal pure returns (bool) {
        return (x == 2 && y == 0) || (x == 0 && y == 1) || (x == 1 && y == 2);
    }
}

/// SEASON0.md §5, Conservation: the ETH balance and the MANA, fuzzed over sequences of calls.
contract ConservationTest is GardenFixture {
    GardenHandler internal handler;

    function setUp() public override {
        super.setUp();
        // Many handler calls share a block, and the per-block HCU cap would bind on the scaffolding. Hcu.t.sol
        // measures each function against the real caps.
        disableHCULimits();

        address[] memory actors = new address[](3);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = makeAddr("carol");
        for (uint256 i; i < actors.length; i++) {
            vm.deal(actors[i], 1_000 ether);
        }
        handler = new GardenHandler(garden, this, actors);
        targetContract(address(handler));
    }

    /// SEASON0.md §2.1 and RULES.md §3, invariant 1: the contract holds exactly the charge of every live crystal.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_theBalanceIsTheChargeOfEveryLiveCrystal() public view {
        uint256 live = handler.liveCrystals().length;
        assertEq(garden.totalSupply(), live, "live crystals");
        assertEq(address(garden).balance, CHARGE * live, "ETH held");
    }

    /// RULES.md §3, invariant 5: MANA comes only from accrual, and none is created or lost, whatever is spent in the
    /// Sanctuary or staked in the Arena. What the live crystals, the pots and the open lobbies hold, read from Garden
    /// with `plaintextOf`, is what accrual has credited, counted by the handler from the times alone.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_manaIsConserved() public {
        uint256 held;
        uint256[] memory live = handler.liveCrystals();
        for (uint256 i; i < live.length; i++) {
            held += plaintextOf(garden.crystalOf(live[i]).mana);
        }
        for (uint256 season = 1; season <= garden.currentSeason(); season++) {
            held += _pot(season);
        }
        held += _stakesHeld();
        assertEq(held, handler.credited());
    }

    /// RULES.md §6 and §8: every crystal's level and MANA, and every season's pot, are what the rules give for the
    /// same sequence of calls, worked out by the handler in plaintext.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_levelsManaAndPotsFollowTheRules() public {
        uint256[] memory live = handler.liveCrystals();
        for (uint256 i; i < live.length; i++) {
            Garden.CrystalView memory crystal = garden.crystalOf(live[i]);
            assertEq(plaintextOf(crystal.level), handler.levelOf(live[i]), "level");
            assertEq(plaintextOf(crystal.mana), handler.manaOf(live[i]), "MANA");
        }
        for (uint256 season = 1; season <= garden.currentSeason(); season++) {
            assertEq(_pot(season), handler.potOf(season), "pot");
        }
    }

    /// RULES.md §4 and §7: the open lobbies, what each creator put up, and every crystal's record, shattered crystals'
    /// included, are what the rules give for the same sequence of calls, worked out by the handler.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_lobbiesAndRecordsFollowTheRules() public {
        uint256[] memory expected = handler.lobbiesOpen();
        (uint256[] memory open,) = garden.openLobbies(0, garden.lastLobbyId());
        assertEq(open.length, expected.length, "open lobbies");
        for (uint256 i; i < open.length; i++) {
            assertTrue(_contains(expected, open[i]), "an open lobby");
            Garden.Lobby memory lobby = garden.lobbyOf(open[i]);
            assertEq(plaintextOf(lobby.creatorPaid), handler.paidOf(open[i]), "what the creator put up");
            assertEq(garden.crystalOf(lobby.crystal).openLobby, open[i], "the crystal waits in it");
        }
        assertEq(_stakesHeld(), handler.staked(), "the stakes held");

        for (uint256 id = 1; id <= garden.lastTokenId(); id++) {
            (uint32 wins, uint32 losses) = garden.recordOf(id);
            assertEq(wins, handler.winsOf(id), "wins");
            assertEq(losses, handler.lossesOf(id), "losses");
        }
    }

    /// The invariants hold on a known sequence through the handler, one that takes every path of its model: a rise,
    /// a refused rise, a hold, a rise into the next season's pot, and a shatter after a rise. Random runs explore
    /// further, but nothing guarantees that a given run reaches a rise.
    function testTheInvariantsHoldOnAKnownSequence() public {
        handler.forge(0);
        handler.forge(1);
        handler.wait(1 days);
        handler.attune(0, true);
        handler.attune(1, false);
        handler.attune(0, true);
        handler.wait(2 days);
        handler.attune(0, true);
        handler.attune(1, true);
        handler.shatter(0);
        assertEq(garden.currentSeason(), 2);
        assertEq(handler.rises(), 3, "rises");
        assertEq(handler.levelOf(2), 2, "the crystal left");

        invariant_theBalanceIsTheChargeOfEveryLiveCrystal();
        invariant_manaIsConserved();
        invariant_levelsManaAndPotsFollowTheRules();
        invariant_lobbiesAndRecordsFollowTheRules();
    }

    /// The same for the Arena: a duel whose stakes move, one where only the creator covers the stake, one where neither
    /// does, one where only the challenger does, a cancel that gives the stake back and one with nothing to give back,
    /// and a duel published after one of its crystals was shattered. Each crystal is picked by its index among the live ones, in forging order until the
    /// shatter.
    function testTheInvariantsHoldOnAKnownArenaSequence() public {
        handler.forge(0);
        handler.forge(1);
        handler.forge(2);
        handler.wait(1 days);
        // Crystals 1, 2 and 3 hold 100 MANA each. Lobby 1 and duel 1: both cover 40, and the winner takes both.
        handler.openLobby(0, 40);
        handler.joinLobby(0, 1);
        // Lobby 2 and duel 2: crystal 3 puts up 40, and crystal 4, just forged, cannot cover it. The stakes stay, whoever
        // wins.
        handler.forge(0);
        handler.openLobby(2, 40);
        handler.joinLobby(0, 3);
        // Lobby 3 and duel 3: crystals 5 and 6, just forged, cannot cover 10. The duel is decided as usual, and no MANA
        // moves.
        handler.forge(1);
        handler.forge(2);
        handler.openLobby(4, 10);
        handler.joinLobby(0, 5);
        // Lobby 4 and duel 4: crystal 5, still empty, opens at 10, and crystal 2 covers it. The stakes stay.
        handler.openLobby(4, 10);
        handler.joinLobby(0, 1);
        // Lobby 5: crystal 3, which took back its 40, puts up 100. Lobby 6: crystal 4, empty, puts up nothing.
        handler.openLobby(2, 100);
        handler.openLobby(3, 10);
        handler.wait(1 days);
        handler.cancelLobby(0);
        handler.cancelLobby(0);
        // Duel 1 is published, then crystal 6 is shattered, then duels 4, 3 and 2 are published.
        handler.publish(0);
        handler.shatter(5);
        handler.publish(0);
        handler.publish(0);
        handler.publish(0);

        assertEq(handler.duels(), 4, "duels");
        assertEq(handler.stakesMoved(), 1, "stakes moved in duel 1 only");
        assertEq(handler.published(), 4, "published");
        assertEq(garden.lastLobbyId(), 6, "lobbies");
        assertEq(handler.lobbiesOpen().length, 0, "every lobby closed");
        assertEq(handler.staked(), 0, "no stake held");
        (uint32 wins, uint32 losses) = garden.recordOf(6);
        assertEq(wins + losses, 1, "the shattered crystal's duel counts");

        invariant_theBalanceIsTheChargeOfEveryLiveCrystal();
        invariant_manaIsConserved();
        invariant_levelsManaAndPotsFollowTheRules();
        invariant_lobbiesAndRecordsFollowTheRules();
    }

    /// The stakes the open lobbies hold, read from Garden: each creator's stake if it put it up.
    function _stakesHeld() internal returns (uint256 held) {
        (uint256[] memory open,) = garden.openLobbies(0, garden.lastLobbyId());
        for (uint256 i; i < open.length; i++) {
            Garden.Lobby memory lobby = garden.lobbyOf(open[i]);
            if (plaintextOf(lobby.creatorPaid)) held += lobby.stake;
        }
    }

    function _contains(uint256[] memory ids, uint256 id) internal pure returns (bool) {
        for (uint256 i; i < ids.length; i++) {
            if (ids[i] == id) return true;
        }
        return false;
    }
}
