// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {externalEbool} from "@fhevm/solidity/lib/FHE.sol";
import {FhevmHCUMeter} from "@fhevm/forge/FhevmVm.sol";
import {Garden} from "../src/Garden.sol";
import {GardenFixture} from "./utils/GardenFixture.sol";

/**
 * @dev SEASON0.md §2.3, rule 7: every external function stays below half of each HCU cap, the transaction total and
 *      the depth. The numbers go in SEASON0.md §2.6.
 */
contract HcuTest is GardenFixture {
    uint256 internal constant HCU_PER_TX_BUDGET = 20_000_000 / 2;
    uint256 internal constant HCU_DEPTH_BUDGET = 5_000_000 / 2;

    uint64 internal constant STAKE = 40;

    uint256 internal crystal;
    externalEbool internal rise;
    bytes internal riseProof;
    /// A lobby for Bob's crystal to join, one for its creator to cancel, and a duel to publish.
    uint256 internal challenger;
    uint256 internal lobbyToJoin;
    uint256 internal lobbyToCancel;
    uint256 internal duelToPublish;

    /**
     * @dev Everything a measured call reads is made here. A forge test is one transaction, so a handle made in the
     *      test itself would bring its own chain to the measured call's depth. setUp is a transaction of its own,
     *      like an earlier transaction on chain (SEASON0.md §2.6).
     */
    function setUp() public override {
        super.setUp();
        // setUp is one transaction, and the scaffolding below, thirteen forges and four duels, would outgrow the
        // per-transaction cap that several transactions on chain would share. The meter still runs, and every test
        // compares its one call with half of each cap, which is stricter than the cap itself.
        disableHCULimits();
        crystal = _forge(alice);
        challenger = _forge(bob);
        uint256 creator = _forge(alice);
        uint256 canceller = _forge(alice);
        uint256[2] memory duellists = [_forge(alice), _forge(bob)];
        uint256[6] memory ranked = [_forge(alice), _forge(bob), _forge(alice), _forge(bob), _forge(alice), _forge(bob)];
        // A day later, so that every crystal covers its stake and a rise is paid for.
        _wait(1 days);
        lobbyToJoin = _openLobby(creator, STAKE);
        lobbyToCancel = _openLobby(canceller, STAKE);
        duelToPublish = _duel(duellists[0], duellists[1], STAKE);
        // Three duels between six other crystals, published in season 1, give it three winners, and a rise puts MANA in
        // its centre: closing it pays all three shares, the most it can do.
        for (uint256 i; i < 3; i++) {
            _publish(_duel(ranked[2 * i], ranked[2 * i + 1], STAKE));
        }
        _attune(alice, ranked[0], true);
        // Another day, so that the lobby may be cancelled, and every measured call credits real MANA. Then season 1
        // may be closed, and every other call runs in season 2, whose centre is still empty.
        _wait(LOBBY_TIMEOUT);
        _waitUntilClosable(1);
        (rise, riseProof) = encryptBool(true, address(garden), alice);
    }

    function testForgingStaysUnderHalfOfEachCap() public {
        resetHCU();
        _forge(bob);
        _assertWithinBudget("forge", lastHCU());
    }

    /// The season's pot is still empty here, so it starts from GARDEN_ZERO. A later shatter adds to the pot instead,
    /// at the same cost.
    function testShatteringStaysUnderHalfOfEachCap() public {
        resetHCU();
        _shatter(alice, crystal);
        _assertWithinBudget("shatter", lastHCU());
    }

    /// A rise, a refused rise and a hold run the same operations (Sanctuary.t.sol shows the HCU is equal), so one
    /// rise measures them all. The season's pot is empty and starts from GARDEN_ZERO, at the same cost.
    function testAttuningStaysUnderHalfOfEachCap() public {
        resetHCU();
        vm.prank(alice);
        garden.attune(crystal, rise, riseProof);
        _assertWithinBudget("attune", lastHCU());
    }

    function testOpeningALobbyStaysUnderHalfOfEachCap() public {
        resetHCU();
        vm.prank(alice);
        garden.openLobby(crystal, STAKE);
        _assertWithinBudget("openLobby", lastHCU());
    }

    /// Both crystals cover the stake here, so it changes hands. A duel whose stakes stay runs the same operations at the
    /// same cost (Arena.t.sol shows it).
    function testJoiningStaysUnderHalfOfEachCap() public {
        resetHCU();
        vm.prank(bob);
        garden.joinLobby(lobbyToJoin, challenger);
        _assertWithinBudget("joinLobby", lastHCU());
    }

    function testCancellingStaysUnderHalfOfEachCap() public {
        resetHCU();
        vm.prank(alice);
        garden.cancelLobby(lobbyToCancel);
        _assertWithinBudget("cancelLobby", lastHCU());
    }

    /// Publishing checks the KMS signatures, which costs gas, not HCU: no encrypted operation runs.
    function testPublishingRunsNoEncryptedOperation() public {
        (bool creatorWon, bytes memory proof) = decryptPublicWithSignatures(garden.duelOf(duelToPublish).creatorWins);
        resetHCU();
        vm.prank(stranger);
        garden.publish(duelToPublish, creatorWon, proof);
        FhevmHCUMeter memory hcu = lastHCU();
        emit log_named_uint("publish: HCU per transaction", hcu.transaction);
        emit log_named_uint("publish: HCU depth", hcu.maxHandle);
        assertEq(hcu.transaction, 0);
        assertEq(hcu.maxHandle, 0);
    }

    /// The most a close can do: three living winners, each credited its share. Fewer winners run fewer operations, and
    /// what the centre holds changes nothing (Seasons.t.sol shows it).
    function testClosingASeasonStaysUnderHalfOfEachCap() public {
        uint256[3] memory top = _top(1);
        for (uint256 place; place < 3; place++) {
            assertTrue(top[place] != 0 && garden.ownerOf(top[place]) != address(0), "a living winner");
        }
        resetHCU();
        _closeSeason(1);
        _assertWithinBudget("closeSeason", lastHCU());
    }

    /// Not an external function, but a transaction with FHE work: the constructor draws GARDEN_ZERO.
    function testDeployingStaysUnderHalfOfEachCap() public {
        resetHCU();
        new Garden(_seasonZero());
        _assertWithinBudget("deployment", lastHCU());
    }

    function _assertWithinBudget(string memory name, FhevmHCUMeter memory hcu) internal {
        emit log_named_uint(string.concat(name, ": HCU per transaction"), hcu.transaction);
        emit log_named_uint(string.concat(name, ": HCU depth"), hcu.maxHandle);
        assertGt(hcu.transaction, 0);
        assertLt(hcu.transaction, HCU_PER_TX_BUDGET);
        assertLt(hcu.maxHandle, HCU_DEPTH_BUDGET);
    }
}
