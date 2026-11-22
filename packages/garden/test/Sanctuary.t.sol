// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FHE, ebool, euint8, euint64, externalEbool, externalEuint8} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {FhevmHCUMeter} from "@fhevm/forge/FhevmVm.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Vm} from "forge-std/Vm.sol";
import {Garden} from "../src/Garden.sol";
import {GardenFixture} from "./utils/GardenFixture.sol";

/// Any contract: it makes an encrypted choice of its own and lets an owner and Garden use it.
contract ChoiceMaker is ZamaEthereumConfig {
    function rise(address owner, address garden) external returns (ebool choice) {
        choice = FHE.allow(FHE.allow(FHE.asEbool(true), owner), garden);
    }
}

/// RULES.md §6, the Sanctuary: attunement, its cost, the maximum level, and where spent MANA goes.
contract SanctuaryTest is GardenFixture {
    /// The input verifier's error for a proof that its signers did not sign.
    bytes4 internal constant INVALID_SIGNER = bytes4(keccak256("InvalidSigner(address)"));

    /// What an outsider can observe of one attunement, and what its owner reads afterwards.
    struct Trace {
        Vm.Log[] logs;
        /// Garden's storage slots written, in order.
        bytes32[] writes;
        /// What the call cost, as its receipt would show.
        uint256 gas;
        FhevmHCUMeter hcu;
        /// Whether the level, the MANA and the pot each got a new handle.
        bool newLevel;
        bool newMana;
        bool newPot;
        uint8 level;
        uint64 mana;
        /// What the pot gained.
        uint64 spent;
    }

    function setUp() public override {
        super.setUp();
        // A forge test is one transaction, so successive attunes of a crystal chain their handles within it and the
        // depth cap would bind on the scaffolding. On chain each attune is a transaction of its own, which Hcu.t.sol
        // measures against the real caps.
        disableHCULimits();
    }

    // -- Attunement -----------------------------------------------------------------------------------------

    /// RULES.md §6: on a rise that its MANA covers, the crystal pays the cost and rises one level. Accrual runs first
    /// (SEASON0.md §2.2), so MANA accrued and not yet credited pays too.
    function testARiseTheManaCoversPaysTheCostAndRisesOneLevel() public {
        uint256 tokenId = _forge(alice);
        _wait(1 days);
        assertEq(garden.crystalOf(tokenId).pendingMana, MANA_PER_DAY, "accrued, not credited");

        _attune(alice, tokenId, true);

        _assertCrystal(tokenId, 2, MANA_PER_DAY - LEVEL_COST);
        assertEq(garden.crystalOf(tokenId).pendingMana, 0);
        assertEq(_pot(1), LEVEL_COST, "the cost went to the centre");
    }

    /// RULES.md §6: a rise the MANA cannot cover changes nothing.
    function testARiseTheManaCannotCoverChangesNothing() public {
        uint256 tokenId = _forge(alice);
        _wait((LEVEL_COST - 1) * SECONDS_PER_MANA);

        _attune(alice, tokenId, true);

        _assertCrystal(tokenId, 1, LEVEL_COST - 1);
        assertEq(_pot(1), 0, "nothing spent");
    }

    /// RULES.md §6: a hold changes nothing, however much MANA the crystal holds.
    function testAHoldChangesNothing() public {
        uint256 tokenId = _forge(alice);
        _wait(10 days);

        _attune(alice, tokenId, false);

        _assertCrystal(tokenId, 1, 10 * MANA_PER_DAY);
        assertEq(_pot(1), 0, "nothing spent");
    }

    /// RULES.md §6: a balance equal to the cost covers it.
    function testABalanceEqualToTheCostCoversIt() public {
        uint256 tokenId = _forge(alice);
        _wait(LEVEL_COST * SECONDS_PER_MANA);

        _attune(alice, tokenId, true);

        _assertCrystal(tokenId, 2, 0);
        assertEq(_pot(1), LEVEL_COST);
    }

    /// RULES.md §6, Cost: rising from L to L + 1 costs 50 × L² MANA, at every level below the maximum. Before each
    /// rise the crystal holds one MANA less than the cost and is refused, then exactly the cost, which the rise spends
    /// in full. The climb takes 142 days, so each cost goes to the pot of the season in progress at the time.
    function testEachRiseCostsFiftyTimesTheSquareOfTheLevel() public {
        uint256 tokenId = _forge(alice);
        for (uint8 level = 1; level < MAX_LEVEL; level++) {
            uint64 cost = LEVEL_COST * level * level;
            string memory from = string.concat("from level ", vm.toString(level));

            _wait((cost - 1) * SECONDS_PER_MANA);
            uint256 season = garden.currentSeason();
            uint64 pot = _pot(season);
            _attune(alice, tokenId, true);
            _assertCrystal(tokenId, level, cost - 1);
            assertEq(_pot(season), pot, string.concat(from, ": a refused rise spends nothing"));

            _wait(SECONDS_PER_MANA);
            season = garden.currentSeason();
            pot = _pot(season);
            _attune(alice, tokenId, true);
            _assertCrystal(tokenId, level + 1, 0);
            assertEq(_pot(season), pot + cost, string.concat(from, ": the cost went to the season in progress"));
        }
    }

    /// RULES.md §6: the maximum level is 10. A crystal there is refused a rise however much MANA it holds, more than
    /// the 50 × 10² a rise from 10 would cost, and keeps that MANA.
    function testTheMaximumLevelIsTen() public {
        uint256 tokenId = _forge(alice);
        for (uint8 level = 1; level < MAX_LEVEL; level++) {
            _wait(uint256(LEVEL_COST) * level * level * SECONDS_PER_MANA);
            _attune(alice, tokenId, true);
        }
        _assertCrystal(tokenId, MAX_LEVEL, 0);

        uint64 plenty = 2 * LEVEL_COST * uint64(MAX_LEVEL) * MAX_LEVEL;
        _wait(plenty * SECONDS_PER_MANA);
        uint256 season = garden.currentSeason();
        uint64 pot = _pot(season);
        _attune(alice, tokenId, true);

        _assertCrystal(tokenId, MAX_LEVEL, plenty);
        assertEq(_pot(season), pot, "nothing spent");
    }

    /// The level is squared in a euint8. At the largest maximum the constructor accepts, 15, every rise still costs
    /// exactly LEVEL_COST × L²: here 1 × L² MANA at one MANA a second, up to 14² = 196.
    function testEveryRiseCostsExactlyItsPriceUpToTheLargestMaximum() public {
        Garden.Params memory params = _seasonZero();
        params.manaPerDay = 1 days;
        params.levelCost = 1;
        params.maxLevel = 15;
        garden = new Garden(params);
        uint256 tokenId = _forge(alice);

        for (uint8 level = 1; level < 15; level++) {
            _wait(uint256(level) * level);
            _attune(alice, tokenId, true);
            _assertCrystal(tokenId, level + 1, 0);
        }
        _wait(1000);
        _attune(alice, tokenId, true);
        _assertCrystal(tokenId, 15, 1000);
    }

    /// RULES.md §6 and §8: spent MANA flows to the pot of the season in progress, with shattered MANA. An earlier pot
    /// is left as it was.
    function testSpentManaFlowsToThePotOfTheSeasonInProgress() public {
        uint256 first = _forge(alice);
        uint256 second = _forge(bob);
        _wait(1 days);
        _attune(alice, first, true);
        _attune(bob, second, true);
        assertEq(_pot(1), 2 * LEVEL_COST, "two rises from level 1");

        // Season 2. Each crystal holds 50 MANA left from day one and 200 more: Alice's rise from level 2 costs 200,
        // and Bob's 250 go to the centre with his crystal.
        vm.warp(garden.GENESIS() + SEASON_LENGTH);
        assertEq(garden.currentSeason(), 2);
        _attune(alice, first, true);
        _shatter(bob, second);

        _assertCrystal(first, 3, 50);
        assertEq(_pot(2), 4 * LEVEL_COST + 250, "a rise from level 2 and a shattered crystal");
        assertEq(_pot(1), 2 * LEVEL_COST, "season 1 is left as it was");
    }

    /// RULES.md §4: the element never changes. Attuning gives the level and MANA new handles and leaves the
    /// element's as it was.
    function testAttuningNeverChangesTheElement() public {
        uint256 tokenId = _forge(alice);
        Garden.CrystalView memory before = garden.crystalOf(tokenId);
        _wait(1 days);
        _attune(alice, tokenId, true);
        _attune(alice, tokenId, false);

        Garden.CrystalView memory afterwards = garden.crystalOf(tokenId);
        assertEq(euint8.unwrap(afterwards.element), euint8.unwrap(before.element));
        assertNotEq(euint8.unwrap(afterwards.level), euint8.unwrap(before.level));
        assertNotEq(euint64.unwrap(afterwards.mana), euint64.unwrap(before.mana));
    }

    // -- Who attunes, and with what ---------------------------------------------------------------------------

    /// RULES.md §6: the owner attunes, and nobody else, not even an account the owner approved. A crystal that does
    /// not exist cannot be attuned.
    function testOnlyTheOwnerCanAttune() public {
        uint256 tokenId = _forge(alice);
        _wait(1 days);
        Garden.CrystalView memory before = garden.crystalOf(tokenId);

        _expectAttuneReverts(bob, tokenId, abi.encodeWithSelector(Garden.NotOwner.selector));
        vm.prank(alice);
        garden.approve(bob, tokenId);
        _expectAttuneReverts(bob, tokenId, abi.encodeWithSelector(Garden.NotOwner.selector));
        vm.prank(alice);
        garden.setApprovalForAll(bob, true);
        _expectAttuneReverts(bob, tokenId, abi.encodeWithSelector(Garden.NotOwner.selector));

        Garden.CrystalView memory afterwards = garden.crystalOf(tokenId);
        assertEq(euint8.unwrap(afterwards.level), euint8.unwrap(before.level), "level untouched");
        assertEq(euint64.unwrap(afterwards.mana), euint64.unwrap(before.mana), "MANA untouched");

        bytes memory missing = abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, tokenId + 1);
        _expectAttuneReverts(alice, tokenId + 1, missing);
        _shatter(alice, tokenId);
        missing = abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, tokenId);
        _expectAttuneReverts(alice, tokenId, missing);
    }

    /// RULES.md §6: the choice is encrypted. Without a proof, FHE.fromExternal would take the zero handle as a
    /// plaintext `false`, or any ebool the owner and Garden may use, such as one a contract made in the clear. The
    /// choice would then be public, so Garden refuses an empty proof.
    function testAChoiceMustComeWithItsProof() public {
        uint256 tokenId = _forge(alice);
        _wait(1 days);
        (externalEbool encrypted,) = encryptBool(true, address(garden), alice);
        ebool clear = new ChoiceMaker().rise(alice, address(garden));

        externalEbool[3] memory choices = [encrypted, externalEbool.wrap(0), externalEbool.wrap(ebool.unwrap(clear))];
        for (uint256 i; i < choices.length; i++) {
            vm.expectRevert(Garden.MissingProof.selector);
            vm.prank(alice);
            garden.attune(tokenId, choices[i], "");
        }
        _assertCrystal(tokenId, 1, 0);
    }

    /// An encrypted input belongs to one contract and one user, and has a type. Garden refuses a choice encrypted for
    /// another player, or for another contract, and a number in place of a choice.
    function testAChoiceEncryptedForAnotherPlayerOrContractIsRefused() public {
        uint256 aliceCrystal = _forge(alice);
        uint256 bobCrystal = _forge(bob);
        _wait(1 days);

        // The input verifier recovers the signer from a digest that names the contract and the user, so with any
        // other pair it recovers an address that signs nothing. The selector is all a test can name.
        (externalEbool aliceChoice, bytes memory aliceProof) = encryptBool(true, address(garden), alice);
        vm.expectPartialRevert(INVALID_SIGNER);
        vm.prank(bob);
        garden.attune(bobCrystal, aliceChoice, aliceProof);

        (externalEbool elsewhere, bytes memory elsewhereProof) = encryptBool(true, address(this), alice);
        vm.expectPartialRevert(INVALID_SIGNER);
        vm.prank(alice);
        garden.attune(aliceCrystal, elsewhere, elsewhereProof);

        (externalEuint8 number, bytes memory numberProof) = encryptUint8(1, address(garden), alice);
        vm.expectRevert(abi.encodeWithSignature("InvalidType()"));
        vm.prank(alice);
        garden.attune(aliceCrystal, externalEbool.wrap(externalEuint8.unwrap(number)), numberProof);

        _assertCrystal(aliceCrystal, 1, 0);
        _assertCrystal(bobCrystal, 1, 0, bobKey);
    }

    // -- What others see ------------------------------------------------------------------------------------

    /**
     * RULES.md §6 and §9: a rise, a refused rise and a hold look the same from outside. All three run from the same
     * state, on the same crystal, with the same public history: an attunement half a day after forging, then the
     * measured one a day later. Only the encrypted choices differ:
     * - rise: hold, then rise. 150 MANA at level 1 cover the 50.
     * - refused: rise, then rise. 100 MANA at level 2 fall short of the 200.
     * - hold: hold, then hold.
     * Outside they are the same: Garden's event, the storage slots it writes, every log in order with its emitter,
     * signature and size, every grant, the gas and the HCU. Only handles differ, and each attunement gives the level,
     * the MANA and the pot new ones.
     */
    function testARiseARefusedRiseAndAHoldLookTheSameFromOutside() public {
        uint256 tokenId = _forge(alice);
        uint256 forged = vm.snapshotState();

        Trace memory rise = _trace(tokenId, false, true);
        assertTrue(vm.revertToState(forged));
        Trace memory refused = _trace(tokenId, true, true);
        assertTrue(vm.revertToState(forged));
        Trace memory hold = _trace(tokenId, false, false);

        // The cases are what they claim.
        assertEq(rise.level, 2, "rise: level");
        assertEq(rise.spent, LEVEL_COST, "rise: spent");
        assertEq(refused.level, 2, "refused: level");
        assertEq(refused.mana, MANA_PER_DAY, "refused: MANA");
        assertEq(refused.spent, 0, "refused: spent");
        assertEq(hold.level, 1, "hold: level");
        assertEq(hold.spent, 0, "hold: spent");

        _assertSameFromOutside(rise, refused);
        _assertSameFromOutside(rise, hold);
    }

    // -- Helpers --------------------------------------------------------------------------------------------

    /// What Alice, the owner, reads.
    function _assertCrystal(uint256 tokenId, uint8 level, uint64 mana) internal {
        _assertCrystal(tokenId, level, mana, aliceKey);
    }

    function _assertCrystal(uint256 tokenId, uint8 level, uint64 mana, uint256 ownerKey) internal {
        Garden.CrystalView memory crystal = garden.crystalOf(tokenId);
        assertEq(decrypt(crystal.level, address(garden), ownerKey), level, "level");
        assertEq(decrypt(crystal.mana, address(garden), ownerKey), mana, "MANA");
    }

    function _expectAttuneReverts(address caller, uint256 tokenId, bytes memory reason) internal {
        (externalEbool choice, bytes memory proof) = encryptBool(true, address(garden), caller);
        vm.expectRevert(reason);
        vm.prank(caller);
        garden.attune(tokenId, choice, proof);
    }

    /// Two attunements of the crystal, half a day and a day and a half after its forging, and what the second showed.
    function _trace(uint256 tokenId, bool first, bool second) internal returns (Trace memory t) {
        uint256 forgedAt = garden.crystalOf(tokenId).lastAccrual;
        vm.warp(forgedAt + 0.5 days);
        vm.roll(block.number + 1);
        _attune(alice, tokenId, first);
        vm.warp(forgedAt + 1.5 days);
        vm.roll(block.number + 1);

        (externalEbool choice, bytes memory proof) = encryptBool(second, address(garden), alice);
        Garden.CrystalView memory before = garden.crystalOf(tokenId);
        euint64 pot = garden.potOf(1);
        uint64 potBefore = _pot(1);

        vm.recordLogs();
        vm.record();
        resetHCU();
        vm.prank(alice);
        garden.attune(tokenId, choice, proof);
        t.gas = vm.lastCallGas().gasTotalUsed;
        t.hcu = lastHCU();
        (, t.writes) = vm.accesses(address(garden));
        t.logs = vm.getRecordedLogs();

        // Garden's one event, whatever happened: Attuned(tokenId).
        uint256 events;
        for (uint256 i; i < t.logs.length; i++) {
            if (t.logs[i].emitter != address(garden)) continue;
            events++;
            assertEq(t.logs[i].topics.length, 2, "Attuned: topics");
            assertEq(t.logs[i].topics[0], Garden.Attuned.selector, "Attuned");
            assertEq(t.logs[i].topics[1], bytes32(tokenId), "Attuned: token id");
            assertEq(t.logs[i].data.length, 0, "Attuned: data");
        }
        assertEq(events, 1, "Garden's events");

        Garden.CrystalView memory afterwards = garden.crystalOf(tokenId);
        t.newLevel = euint8.unwrap(afterwards.level) != euint8.unwrap(before.level);
        t.newMana = euint64.unwrap(afterwards.mana) != euint64.unwrap(before.mana);
        t.newPot = euint64.unwrap(garden.potOf(1)) != euint64.unwrap(pot);
        t.level = decrypt(afterwards.level, address(garden), aliceKey);
        t.mana = decrypt(afterwards.mana, address(garden), aliceKey);
        t.spent = _pot(1) - potBefore;
    }

    function _assertSameFromOutside(Trace memory a, Trace memory b) internal view {
        address acl = getCoprocessorConfig(address(garden)).ACLAddress;
        assertTrue(a.newLevel && a.newMana && a.newPot && b.newLevel && b.newMana && b.newPot, "new handles");
        assertEq(a.writes, b.writes, "storage slots written");
        assertEq(a.gas, b.gas, "gas");
        assertEq(a.hcu.transaction, b.hcu.transaction, "HCU per transaction");
        assertEq(a.hcu.maxHandle, b.hcu.maxHandle, "HCU depth");

        assertEq(a.logs.length, b.logs.length, "number of logs");
        for (uint256 i; i < a.logs.length; i++) {
            Vm.Log memory x = a.logs[i];
            Vm.Log memory y = b.logs[i];
            string memory at = string.concat("log ", vm.toString(i));
            assertEq(x.emitter, y.emitter, string.concat(at, ": emitter"));
            assertEq(x.topics.length, y.topics.length, string.concat(at, ": topics"));
            assertEq(x.topics[0], y.topics[0], string.concat(at, ": event"));
            assertEq(x.data.length, y.data.length, string.concat(at, ": data size"));
            // Garden's own events carry public data only, so they are identical. The ACL's name the accounts granted.
            if (x.emitter == address(garden)) assertEq(x.data, y.data, string.concat(at, ": Garden's data"));
            if (x.emitter == address(garden) || x.emitter == acl) {
                assertEq(x.topics, y.topics, string.concat(at, ": indexed fields"));
            }
        }
    }
}
