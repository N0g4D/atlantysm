// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {euint8, euint64} from "@fhevm/solidity/lib/FHE.sol";
import {Vm} from "forge-std/Vm.sol";
import {Garden} from "../src/Garden.sol";
import {GardenFixture} from "./utils/GardenFixture.sol";
import {GardenHarness} from "./utils/GardenHarness.sol";

/// RULES.md §5, MANA: the flow, accrual, and where a shattered crystal's MANA goes.
contract ManaTest is GardenFixture {
    GardenHarness internal harness;

    function _deploy(Garden.Params memory params) internal override returns (Garden) {
        harness = new GardenHarness(params);
        return harness;
    }

    // -- The flow -------------------------------------------------------------------------------------------

    /// RULES.md §5: every crystal receives the same flow, 100 MANA a day, whoever owns it and whenever it was
    /// forged.
    function testEveryCrystalReceivesTheSameFlow() public {
        uint256 first = _forge(alice);
        _wait(2 days);
        uint256 second = _forge(bob);
        _wait(1 days);
        assertEq(garden.crystalOf(first).pendingMana, 3 * MANA_PER_DAY);
        assertEq(garden.crystalOf(second).pendingMana, MANA_PER_DAY);

        _wait(1 days);
        assertEq(garden.crystalOf(first).pendingMana, 4 * MANA_PER_DAY);
        assertEq(garden.crystalOf(second).pendingMana, 2 * MANA_PER_DAY);
    }

    /// RULES.md §5: MANA accrues continuously, a whole MANA every 864 seconds.
    function testManaAccruesContinuouslyInWholeUnits() public {
        uint256 tokenId = _forge(alice);
        uint256 forgedAt = block.timestamp;
        uint256[7] memory elapsed = [uint256(0), 863, 864, 1 days - 1, 1 days, 1.5 days, 30 days];
        uint64[7] memory accrued = [uint64(0), 0, 1, 99, 100, 150, 3000];
        for (uint256 i; i < elapsed.length; i++) {
            vm.warp(forgedAt + elapsed[i]);
            assertEq(garden.crystalOf(tokenId).pendingMana, accrued[i], vm.toString(elapsed[i]));
        }
    }

    // -- Credit when the crystal acts ----------------------------------------------------------------------

    /// RULES.md §5: accrued MANA is credited whenever the crystal acts. Until then the stored balance stays where it
    /// was, and afterwards it holds everything accrued.
    function testManaIsCreditedWhenTheCrystalActs() public {
        uint256 tokenId = _forge(alice);
        _wait(2 days);
        assertEq(decrypt(garden.crystalOf(tokenId).mana, address(garden), aliceKey), 0, "not credited yet");

        harness.act(tokenId);

        Garden.CrystalView memory crystal = garden.crystalOf(tokenId);
        assertEq(decrypt(crystal.mana, address(garden), aliceKey), 2 * MANA_PER_DAY);
        assertEq(crystal.pendingMana, 0);
        assertEq(crystal.lastAccrual, block.timestamp);
    }

    /// SEASON0.md §2.2, Accrual: a remainder shorter than a MANA waits for the next action. `lastAccrual` moves by
    /// whole MANA, not to now.
    function testTheRemainderWaitsForTheNextAction() public {
        uint256 tokenId = _forge(alice);
        uint256 forgedAt = block.timestamp;
        _wait(3 * SECONDS_PER_MANA + 500);
        harness.act(tokenId);

        Garden.CrystalView memory crystal = garden.crystalOf(tokenId);
        assertEq(decrypt(crystal.mana, address(garden), aliceKey), 3);
        assertEq(crystal.lastAccrual, forgedAt + 3 * SECONDS_PER_MANA, "credited up to the last whole MANA");

        // The 500 seconds kept count: 364 more complete the fourth MANA.
        _wait(SECONDS_PER_MANA - 500 - 1);
        assertEq(garden.crystalOf(tokenId).pendingMana, 0);
        _wait(1);
        assertEq(garden.crystalOf(tokenId).pendingMana, 1);
        harness.act(tokenId);
        assertEq(decrypt(garden.crystalOf(tokenId).mana, address(garden), aliceKey), 4);
    }

    /// Acting often loses nothing: a crystal that acts every 1,000 seconds, 87 times, is credited what one that acts
    /// once at the end is credited.
    function testActingOftenLosesNothing() public {
        // One test is one transaction, and 87 dependent additions on one balance pass the depth cap. On chain each
        // action is a transaction of its own.
        disableHCULimits();
        uint256 often = _forge(alice);
        uint256 once = _forge(alice);
        for (uint256 i; i < 87; i++) {
            _wait(1000);
            harness.act(often);
        }
        harness.act(once);

        // 87,000 seconds hold 100 whole MANA, with 600 seconds over.
        assertEq(plaintextOf(garden.crystalOf(once).mana), 100);
        assertEq(plaintextOf(garden.crystalOf(often).mana), 100);
    }

    /// RULES.md §4: the element never changes. Accrual touches the MANA only: the element and the level keep their
    /// handles.
    function testAccrualTouchesOnlyTheMana() public {
        uint256 tokenId = _forge(alice);
        Garden.CrystalView memory before = garden.crystalOf(tokenId);
        _wait(1 days);
        harness.act(tokenId);

        Garden.CrystalView memory afterwards = garden.crystalOf(tokenId);
        assertEq(euint8.unwrap(afterwards.element), euint8.unwrap(before.element), "element");
        assertEq(euint8.unwrap(afterwards.level), euint8.unwrap(before.level), "level");
        assertNotEq(euint64.unwrap(afterwards.mana), euint64.unwrap(before.mana), "MANA");
    }

    /// RULES.md §5: a crystal's balance is encrypted. The credited balance is granted to the contract and the
    /// owner, and to nobody else.
    function testOnlyTheOwnerCanReadTheBalance() public {
        uint256 tokenId = _forge(alice);
        _wait(1 days);

        vm.recordLogs();
        harness.act(tokenId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        euint64 mana = garden.crystalOf(tokenId).mana;
        Grant[] memory grants = new Grant[](2);
        grants[0] = _grant(address(garden), mana);
        grants[1] = _grant(alice, mana);
        _assertGrants(logs, grants);
        _assertNothingPublic(logs);

        assertEq(decrypt(mana, address(garden), aliceKey), MANA_PER_DAY);
        _assertCannotDecrypt(mana, stranger, strangerKey);
        _assertNotPublic(mana);
    }

    // -- The centre -----------------------------------------------------------------------------------------

    /// RULES.md §4 and §8: a shattered crystal's MANA joins the pot of the season in progress. Seasons follow one
    /// another from the deployment, and an earlier pot is left as it was.
    function testShatteredManaJoinsThePotOfTheSeasonInProgress() public {
        uint256 first = _forge(alice);
        uint256 second = _forge(bob);
        uint256 third = _forge(alice);

        _wait(1 days);
        _shatter(alice, first);
        _wait(1 days);
        _shatter(bob, second);
        assertEq(garden.currentSeason(), 1);
        assertEq(plaintextOf(garden.potOf(1)), 3 * MANA_PER_DAY, "one day and two days");

        vm.warp(garden.GENESIS() + SEASON_LENGTH - 1);
        assertEq(garden.currentSeason(), 1);
        vm.warp(garden.GENESIS() + SEASON_LENGTH);
        assertEq(garden.currentSeason(), 2);

        _shatter(alice, third);
        assertEq(plaintextOf(garden.potOf(2)), 3 * MANA_PER_DAY, "three days");
        assertEq(plaintextOf(garden.potOf(1)), 3 * MANA_PER_DAY, "season 1 is left as it was");
        assertEq(euint64.unwrap(garden.potOf(3)), 0, "a pot exists once it receives MANA");
    }

    /// RULES.md §4: what a crystal has been credited and what it accrued since both go to the centre.
    function testShatteringSendsCreditedAndPendingManaAlike() public {
        uint256 tokenId = _forge(alice);
        _wait(1 days);
        harness.act(tokenId);
        _wait(1 days);
        _shatter(alice, tokenId);
        assertEq(plaintextOf(garden.potOf(1)), 2 * MANA_PER_DAY);
    }
}
