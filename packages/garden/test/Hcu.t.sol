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

    uint256 internal crystal;
    externalEbool internal rise;
    bytes internal riseProof;

    /**
     * @dev Everything a measured call reads is made here. A forge test is one transaction, so a handle made in the
     *      test itself would bring its own chain to the measured call's depth. setUp is a transaction of its own,
     *      like an earlier transaction on chain (SEASON0.md §2.6).
     */
    function setUp() public override {
        super.setUp();
        crystal = _forge(alice);
        // A day later, so that shattering credits real MANA, and a rise is paid for.
        _wait(1 days);
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
