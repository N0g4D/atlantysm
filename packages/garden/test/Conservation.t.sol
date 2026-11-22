// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {euint64, externalEbool} from "@fhevm/solidity/lib/FHE.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Garden} from "../src/Garden.sol";
import {GardenFixture} from "./utils/GardenFixture.sol";

/**
 * @dev Drives Garden through random sequences of forging, attuning, shattering and waiting, one transaction per call.
 *      It keeps its own plaintext model of what should hold, worked out from the rules alone: which crystals are live,
 *      the level and MANA of each, and what each season's pot holds.
 */
contract GardenHandler is CommonBase, StdUtils {
    /// RULES.md §12. Copies rather than Garden's own values, so that what the handler expects does not rest on the
    /// contract's arithmetic.
    uint256 internal constant SECONDS_PER_MANA = 864;
    uint256 internal constant SEASON_LENGTH = 3 days;
    uint256 internal constant LEVEL_COST = 50;
    uint256 internal constant MAX_LEVEL = 10;

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

    mapping(uint256 tokenId => uint256) public levelOf;
    mapping(uint256 tokenId => uint256) public manaOf;
    mapping(uint256 season => uint256) public potOf;
    uint256 public rises;

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

    function shatter(uint256 crystalSeed) external {
        if (live.length == 0) return;
        uint256 index = bound(crystalSeed, 0, live.length - 1);
        uint256 tokenId = live[index];
        live[index] = live[live.length - 1];
        live.pop();
        _credit(tokenId);
        potOf[_season()] += manaOf[tokenId];
        creditedToShattered += (block.timestamp - forgedAt[tokenId]) / SECONDS_PER_MANA;

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
    /// Sanctuary. What the live crystals and the pots hold, read with `plaintextOf`, is what accrual has credited,
    /// counted by the handler from the times alone.
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
    }
}
