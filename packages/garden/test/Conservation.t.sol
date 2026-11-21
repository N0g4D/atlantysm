// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {euint64} from "@fhevm/solidity/lib/FHE.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Garden} from "../src/Garden.sol";
import {GardenFixture} from "./utils/GardenFixture.sol";

/**
 * @dev Drives Garden through random sequences of forging, shattering and waiting. Each call is a transaction, and
 *      it keeps its own account of what should hold: which crystals are live, and how much MANA accrual has credited.
 */
contract GardenHandler is CommonBase, StdUtils {
    Garden internal immutable garden;
    address[] internal actors;
    uint256[] internal live;
    mapping(uint256 tokenId => uint256) internal forgedAt;

    /**
     * @notice The MANA accrual has credited, worked out from forging and shattering times alone. A crystal shattered
     *         at `t` has accrued `(t - forgedAt) / SECONDS_PER_MANA` whole MANA, all of it credited by then. Nothing
     *         else in T03 credits MANA.
     */
    uint256 public credited;

    constructor(Garden garden_, address[] memory actors_) {
        garden = garden_;
        actors = actors_;
    }

    function forge(uint256 actorSeed) external {
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];
        uint256 charge = garden.CHARGE();
        vm.prank(actor);
        uint256 tokenId = garden.forge{value: charge}();
        live.push(tokenId);
        forgedAt[tokenId] = block.timestamp;
    }

    function shatter(uint256 crystalSeed) external {
        if (live.length == 0) return;
        uint256 index = bound(crystalSeed, 0, live.length - 1);
        uint256 tokenId = live[index];
        live[index] = live[live.length - 1];
        live.pop();
        credited += (block.timestamp - forgedAt[tokenId]) / garden.SECONDS_PER_MANA();

        vm.prank(garden.ownerOf(tokenId));
        garden.shatter(tokenId);
    }

    /// Up to two days at a time, so that runs cross from one season into the next.
    function wait(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 2 days));
        vm.roll(block.number + 1);
    }

    function liveCrystals() external view returns (uint256[] memory) {
        return live;
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
        handler = new GardenHandler(garden, actors);
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

    /// RULES.md §3, invariant 5: MANA comes only from accrual, and none is created or lost. What the crystals and
    /// the pots hold, read with `plaintextOf`, is what accrual has credited.
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
            euint64 pot = garden.potOf(season);
            if (euint64.unwrap(pot) != 0) held += plaintextOf(pot);
        }
        assertEq(held, handler.credited());
    }
}
