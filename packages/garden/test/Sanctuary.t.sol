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

    /// Each attunement takes a fresh encryption. A handle sits in the calldata, so the same input twice would show
    /// everyone that two attunements made the same choice. Garden refuses it again, on the same crystal or another
    /// one, and takes a new encryption of the same choice.
    function testAChoiceIsUsedOnce() public {
        uint256 first = _forge(alice);
        uint256 second = _forge(alice);
        _wait(1 days);
        (externalEbool choice, bytes memory proof) = encryptBool(true, address(garden), alice);
        vm.prank(alice);
        garden.attune(first, choice, proof);

        uint256[2] memory crystals = [first, second];
        for (uint256 i; i < crystals.length; i++) {
            vm.expectRevert(Garden.ChoiceReused.selector);
            vm.prank(alice);
            garden.attune(crystals[i], choice, proof);
        }

        _attune(alice, second, true);
        _assertCrystal(first, 2, MANA_PER_DAY - LEVEL_COST);
        _assertCrystal(second, 2, MANA_PER_DAY - LEVEL_COST);
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
     * signature and size, every grant, the gas and the HCU. Only handles differ, with the slot that marks each input
     * used, and each attunement gives the level, the MANA and the pot new handles.
     */
    function testARiseARefusedRiseAndAHoldLookTheSameFromOutside() public {
        uint256 tokenId = _forge(alice);
        uint256 forged = vm.snapshotState();

        Trace memory rise = _afterHalfADay(tokenId, false, true);
        assertTrue(vm.revertToState(forged));
        Trace memory refused = _afterHalfADay(tokenId, true, true);
        assertTrue(vm.revertToState(forged));
        Trace memory hold = _afterHalfADay(tokenId, false, false);

        // The cases are what they claim.
        _assertOutcome(rise, 2, 150 - LEVEL_COST, LEVEL_COST, "rise");
        _assertOutcome(refused, 2, 100, 0, "refused");
        _assertOutcome(hold, 1, 150, 0, "hold");

        _assertSameFromOutside(rise, refused);
        _assertSameFromOutside(rise, hold);
    }

    /**
     * RULES.md §6: a rise refused at the maximum level looks the same as well. Three branches share one public
     * history, 200 days of MANA and then ten attunements in a row, of which the tenth is measured. Their MANA never
     * runs short:
     * - rise: a hold, eight rises to level 9, then the rise to 10, which costs 4,050.
     * - refused: nine rises to level 10, then a rise, refused at the maximum although 5,750 MANA would cover 5,000.
     * - hold: nine rises to level 10, then a hold.
     */
    function testARiseRefusedAtTheMaximumLooksTheSameFromOutside() public {
        uint256 tokenId = _forge(alice);
        _wait(200 days);
        uint256 rich = vm.snapshotState();

        Trace memory rise = _afterNineAttunements(tokenId, false, true);
        assertTrue(vm.revertToState(rich));
        Trace memory refused = _afterNineAttunements(tokenId, true, true);
        assertTrue(vm.revertToState(rich));
        Trace memory hold = _afterNineAttunements(tokenId, true, false);

        _assertOutcome(rise, MAX_LEVEL, 5750, 4050, "rise");
        _assertOutcome(refused, MAX_LEVEL, 5750, 0, "refused");
        _assertOutcome(hold, MAX_LEVEL, 5750, 0, "hold");

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

    /// An attunement half a day after forging, then the one observed, a day later.
    function _afterHalfADay(uint256 tokenId, bool first, bool observed) internal returns (Trace memory) {
        uint256 forgedAt = garden.crystalOf(tokenId).lastAccrual;
        vm.warp(forgedAt + 0.5 days);
        vm.roll(block.number + 1);
        _attune(alice, tokenId, first);
        vm.warp(forgedAt + 1.5 days);
        vm.roll(block.number + 1);
        return _observe(tokenId, observed);
    }

    /// A first attunement, eight rises, then the one observed.
    function _afterNineAttunements(uint256 tokenId, bool first, bool observed) internal returns (Trace memory) {
        _attune(alice, tokenId, first);
        for (uint256 i; i < 8; i++) {
            _attune(alice, tokenId, true);
        }
        return _observe(tokenId, observed);
    }

    /// One attunement of Alice's crystal, as an outsider sees it, and what Alice reads afterwards.
    function _observe(uint256 tokenId, bool rise) internal returns (Trace memory t) {
        (externalEbool choice, bytes memory proof) = encryptBool(rise, address(garden), alice);
        Garden.CrystalView memory before = garden.crystalOf(tokenId);
        uint256 season = garden.currentSeason();
        euint64 pot = garden.potOf(season);
        uint64 potBefore = _pot(season);

        vm.recordLogs();
        vm.record();
        resetHCU();
        vm.prank(alice);
        garden.attune(tokenId, choice, proof);
        t.gas = vm.lastCallGas().gasTotalUsed;
        t.hcu = lastHCU();
        (, bytes32[] memory writes) = vm.accesses(address(garden));
        t.logs = vm.getRecordedLogs();

        // The slot that marks the input used comes from the input's handle, which every encryption makes anew, so it
        // differs between any two attunements. Every other write must be the same.
        t.writes = _without(writes, _usedSlot(externalEbool.unwrap(choice)));
        assertEq(t.writes.length, writes.length - 1, "the input marked used, once");

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
        t.newPot = euint64.unwrap(garden.potOf(season)) != euint64.unwrap(pot);
        t.level = decrypt(afterwards.level, address(garden), aliceKey);
        t.mana = decrypt(afterwards.mana, address(garden), aliceKey);
        t.spent = _pot(season) - potBefore;
    }

    /// The storage slot where Garden marked `input` used. Found by probing for the mapping's slot rather than written
    /// down, so that a change to Garden's layout cannot make the comparison drop the wrong write.
    function _usedSlot(bytes32 input) internal view returns (bytes32 slot) {
        for (uint256 base; base < 64; base++) {
            slot = keccak256(abi.encode(input, base));
            if (vm.load(address(garden), slot) == bytes32(uint256(1))) return slot;
        }
        revert("the input is not marked used");
    }

    function _without(bytes32[] memory slots, bytes32 dropped) internal pure returns (bytes32[] memory kept) {
        kept = new bytes32[](slots.length);
        uint256 n;
        for (uint256 i; i < slots.length; i++) {
            if (slots[i] != dropped) kept[n++] = slots[i];
        }
        assembly ("memory-safe") {
            mstore(kept, n)
        }
    }

    function _assertOutcome(Trace memory t, uint8 level, uint64 mana, uint64 spent, string memory name) internal pure {
        assertEq(t.level, level, string.concat(name, ": level"));
        assertEq(t.mana, mana, string.concat(name, ": MANA"));
        assertEq(t.spent, spent, string.concat(name, ": spent"));
    }

    function _assertSameFromOutside(Trace memory a, Trace memory b) internal view {
        assertTrue(a.newLevel && a.newMana && a.newPot && b.newLevel && b.newMana && b.newPot, "new handles");
        assertEq(a.writes, b.writes, "storage slots written");
        assertEq(a.gas, b.gas, "gas");
        assertEq(a.hcu.transaction, b.hcu.transaction, "HCU per transaction");
        assertEq(a.hcu.maxHandle, b.hcu.maxHandle, "HCU depth");
        _assertSameLogs(a.logs, b.logs);
    }
}
