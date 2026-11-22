// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {euint16} from "@fhevm/solidity/lib/FHE.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Vm} from "forge-std/Vm.sol";
import {Garden} from "../src/Garden.sol";
import {GardenFixture} from "./utils/GardenFixture.sol";

/// An owner that cannot take ETH.
contract ChargeRefuser {
    Garden internal immutable garden;

    constructor(Garden garden_) payable {
        garden = garden_;
    }

    function forge() external returns (uint256) {
        return garden.forge{value: garden.CHARGE()}();
    }

    function shatter(uint256 tokenId) external {
        garden.shatter(tokenId);
    }
}

/// An owner that tries to shatter a second crystal while the first one's charge is on its way back.
contract Reenterer {
    Garden internal immutable garden;
    uint256 internal second;
    bytes public reentryError;

    constructor(Garden garden_) payable {
        garden = garden_;
    }

    function forgeTwo() external returns (uint256 first) {
        first = garden.forge{value: garden.CHARGE()}();
        second = garden.forge{value: garden.CHARGE()}();
    }

    function shatter(uint256 tokenId) external {
        garden.shatter(tokenId);
    }

    receive() external payable {
        try garden.shatter(second) {}
        catch (bytes memory reason) {
            reentryError = reason;
        }
    }
}

/// RULES.md §4, Crystals: forging, the element, shattering, and the ERC-721.
contract CrystalsTest is GardenFixture {
    // -- Forging --------------------------------------------------------------------------------------------

    /// RULES.md §4, Forging: anyone forges a crystal by paying the charge, and the charge is held against it.
    function testForgingTakesTheCharge() public {
        uint256 balance = alice.balance;

        vm.expectEmit(address(garden));
        emit Garden.Forged(1, alice);
        uint256 tokenId = _forge(alice);

        assertEq(tokenId, 1);
        assertEq(garden.ownerOf(tokenId), alice);
        assertEq(garden.balanceOf(alice), 1);
        assertEq(alice.balance, balance - CHARGE);
        assertEq(address(garden).balance, CHARGE);
        assertEq(garden.totalSupply(), 1);
        assertEq(garden.lastTokenId(), 1);
    }

    /// RULES.md §4: the charge is the same for everyone, so no other amount forges.
    function testForgingTakesExactlyTheCharge() public {
        uint256[3] memory amounts = [uint256(0), CHARGE - 1, CHARGE + 1];
        for (uint256 i; i < amounts.length; i++) {
            vm.expectRevert(Garden.WrongCharge.selector);
            vm.prank(alice);
            garden.forge{value: amounts[i]}();
        }
        assertEq(address(garden).balance, 0);
        assertEq(garden.totalSupply(), 0);
    }

    /// SEASON0.md §2.1: `forge` is the only way in for ETH. Garden has no `receive` and no `fallback`.
    function testGardenRefusesAnyOtherEth() public {
        vm.startPrank(alice);
        (bool plain,) = address(garden).call{value: CHARGE}("");
        (bool unknown,) = address(garden).call{value: CHARGE}(abi.encodeWithSignature("deposit()"));
        vm.stopPrank();
        assertFalse(plain, "a plain transfer");
        assertFalse(unknown, "a call to no function");
        assertEq(address(garden).balance, 0);
    }

    /// RULES.md §3, invariant 2, and §4: every crystal is born equal, at level 1 with no MANA, whoever forges it
    /// and whenever. The forger can read all three secrets from the start.
    function testEveryCrystalIsBornEqual() public {
        _assertNewborn(_forge(alice), alice, aliceKey);
        _wait(5 days);
        _assertNewborn(_forge(bob), bob, bobKey);
        _assertNewborn(_forge(alice), alice, aliceKey);
    }

    /// RULES.md §3, invariant 6, and §4: the element is drawn by encrypted on-chain randomness, and `forge` takes
    /// nothing the forger could choose it with. It is the forge's one random draw, reduced modulo 3 (SEASON0.md
    /// §2.2), read from the executor's event as the coprocessor reads it.
    function testTheElementIsTheRandomDrawModuloThree() public {
        for (uint256 i; i < 6; i++) {
            vm.recordLogs();
            uint256 tokenId = _forge(alice);
            uint16 draw = _drawOf(vm.getRecordedLogs());
            assertEq(decrypt(garden.crystalOf(tokenId).element, address(garden), aliceKey), draw % 3);
        }
    }

    /// RULES.md §4: Fire, Water or Earth, one chance in three each. Over 300 forges each element should come up
    /// about 100 times.
    function testElementsSpreadEvenlyOverThreeHundredForges() public {
        // One test is one transaction, and 300 forges in one transaction pass its HCU cap. On chain each forge is
        // a transaction of its own, which Hcu.t.sol measures against the caps.
        disableHCULimits();
        uint256[3] memory counts;
        for (uint256 i; i < 300; i++) {
            uint8 element = plaintextOf(garden.crystalOf(_forge(alice)).element);
            assertLt(element, 3, "an element");
            counts[element]++;
        }

        uint256 squares;
        for (uint256 e; e < 3; e++) {
            emit log_named_uint(_name(e), counts[e]);
            uint256 gap = counts[e] > 100 ? counts[e] - 100 : 100 - counts[e];
            squares += gap * gap;
        }
        // Pearson's chi-squared is squares / 100, with two degrees of freedom, where P(chi-squared > x) = e^(-x/2).
        // A fair draw goes past 13.8 once in a thousand runs.
        assertLe(squares, 1381, "chi-squared at most 13.81");
    }

    // -- Shattering -----------------------------------------------------------------------------------------

    /// RULES.md §3, invariant 1, and §4, Shattering: the crystal is burned and its charge returns to the owner.
    /// Ids are never reused.
    function testShatteringBurnsTheCrystalAndReturnsItsCharge() public {
        uint256 kept = _forge(alice);
        uint256 tokenId = _forge(alice);
        uint256 balance = alice.balance;

        vm.expectEmit(address(garden));
        emit Garden.Shattered(tokenId);
        _shatter(alice, tokenId);

        assertEq(alice.balance, balance + CHARGE, "the charge returns to the owner");
        assertEq(address(garden).balance, CHARGE, "the other crystal's charge stays");
        assertEq(garden.totalSupply(), 1);
        assertEq(garden.balanceOf(alice), 1);
        assertEq(garden.ownerOf(kept), alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, tokenId));
        garden.ownerOf(tokenId);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, tokenId));
        garden.crystalOf(tokenId);

        assertEq(_forge(bob), 3, "a new id");
    }

    /// RULES.md §4: in Season 0 a shattered crystal's unspent MANA returns to the centre, accrued up to the
    /// shattering (SEASON0.md §2.2).
    function testShatteringSendsTheUnspentManaToTheCentre() public {
        uint256 tokenId = _forge(alice);
        // A day, and a remainder too short for one more MANA.
        _wait(1 days + SECONDS_PER_MANA - 1);
        _shatter(alice, tokenId);
        assertEq(plaintextOf(garden.potOf(1)), MANA_PER_DAY);
    }

    /// RULES.md §4: the owner shatters, and nobody else, not even an account the owner approved. The charge goes to
    /// whoever shatters.
    function testOnlyTheOwnerCanShatter() public {
        uint256 tokenId = _forge(alice);
        vm.expectRevert(Garden.NotOwner.selector);
        _shatter(bob, tokenId);

        vm.prank(alice);
        garden.approve(bob, tokenId);
        vm.expectRevert(Garden.NotOwner.selector);
        _shatter(bob, tokenId);

        vm.prank(alice);
        garden.setApprovalForAll(bob, true);
        vm.expectRevert(Garden.NotOwner.selector);
        _shatter(bob, tokenId);

        assertEq(garden.ownerOf(tokenId), alice);
        assertEq(address(garden).balance, CHARGE);
    }

    /// A crystal is shattered once, and one that was never forged cannot be.
    function testACrystalIsShatteredOnce() public {
        uint256 tokenId = _forge(alice);
        _shatter(alice, tokenId);

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, tokenId));
        _shatter(alice, tokenId);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, tokenId + 1));
        _shatter(alice, tokenId + 1);
        assertEq(address(garden).balance, 0);
    }

    /// The charge goes back with a plain call. An owner that refuses it cannot shatter, and keeps its crystal.
    function testAnOwnerThatRefusesTheChargeCannotShatter() public {
        ChargeRefuser refuser = new ChargeRefuser{value: CHARGE}(garden);
        uint256 tokenId = refuser.forge();

        vm.expectRevert(Garden.ChargeNotReturned.selector);
        refuser.shatter(tokenId);

        assertEq(garden.ownerOf(tokenId), address(refuser));
        assertEq(address(garden).balance, CHARGE);
        assertEq(garden.totalSupply(), 1);
    }

    /// SEASON0.md §2 and §2.3, rule 6: `shatter` is `nonReentrant`, so an owner cannot shatter again from inside the
    /// call that returns a charge.
    function testShatteringCannotBeReentered() public {
        Reenterer reenterer = new Reenterer{value: 2 * CHARGE}(garden);
        uint256 first = reenterer.forgeTwo();

        reenterer.shatter(first);

        assertEq(
            reenterer.reentryError(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(garden.ownerOf(first + 1), address(reenterer), "the second crystal is whole");
        assertEq(address(garden).balance, CHARGE);
        assertEq(address(reenterer).balance, CHARGE);
    }

    // -- Ownership ------------------------------------------------------------------------------------------

    /// RULES.md §4, Ownership: crystals are ERC-721 tokens.
    function testCrystalsAreErc721Tokens() public view {
        assertEq(garden.name(), "Atlantysm Crystal");
        assertEq(garden.symbol(), "CRYSTAL");
        assertTrue(garden.supportsInterface(0x80ac58cd), "ERC-721");
        assertTrue(garden.supportsInterface(0x5b5e139f), "ERC-721 metadata");
    }

    /// RULES.md §4, Ownership: a transfer must seal the level and MANA again for the new owner. Until it does (T07),
    /// every transfer is refused, from the owner or from an approved account.
    function testTransfersAreRefusedUntilTheySealTheCrystalAgain() public {
        uint256 tokenId = _forge(alice);
        vm.prank(alice);
        garden.approve(bob, tokenId);

        vm.expectRevert(Garden.TransfersNotOpen.selector);
        vm.prank(alice);
        garden.transferFrom(alice, bob, tokenId);
        vm.expectRevert(Garden.TransfersNotOpen.selector);
        vm.prank(alice);
        garden.safeTransferFrom(alice, bob, tokenId);
        vm.expectRevert(Garden.TransfersNotOpen.selector);
        vm.prank(bob);
        garden.safeTransferFrom(alice, bob, tokenId, "");

        assertEq(garden.ownerOf(tokenId), alice);
    }

    /// SEASON0.md §2.4: an owner's crystals, a page at a time. Shattered crystals drop out.
    function testCrystalsOfPagesThroughAnOwnersCrystals() public {
        // Ids 1 to 7: Alice holds 1, 2, 4, 6 and 7, Bob 3 and 5. Then Alice shatters 6.
        for (uint256 i = 1; i <= 7; i++) {
            _forge(i == 3 || i == 5 ? bob : alice);
        }
        _shatter(alice, 6);

        _assertPage(alice, 1, 100, _ids(1, 2, 4, 7), 0);
        _assertPage(bob, 1, 100, _ids(3, 5), 0);
        _assertPage(stranger, 1, 100, new uint256[](0), 0);

        // Pages of three ids, found or not.
        _assertPage(alice, 1, 3, _ids(1, 2), 4);
        _assertPage(alice, 4, 3, _ids(4), 7);
        _assertPage(alice, 7, 3, _ids(7), 0);
        _assertPage(bob, 4, 3, _ids(5), 7);

        // A cursor of 0 starts from the first crystal. Past the last id there is nothing left, and a page of no ids
        // stays where it is.
        _assertPage(alice, 0, 2, _ids(1, 2), 3);
        _assertPage(alice, 8, 3, new uint256[](0), 0);
        _assertPage(alice, 2, 0, new uint256[](0), 2);

        // Shattered crystals belong to the zero address, which owns nothing, as for `balanceOf`.
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidOwner.selector, address(0)));
        garden.crystalsOf(address(0), 1, 100);
    }

    // -- Deployment -----------------------------------------------------------------------------------------

    /// SEASON0.md §2: every parameter of RULES.md §12 is fixed at deployment.
    function testTheParametersAreFixedAtDeployment() public view {
        assertEq(garden.CHARGE(), CHARGE);
        assertEq(garden.MANA_PER_DAY(), MANA_PER_DAY);
        assertEq(garden.SECONDS_PER_MANA(), SECONDS_PER_MANA);
        assertEq(garden.SEASON_LENGTH(), SEASON_LENGTH);
        assertEq(garden.LEVEL_COST(), LEVEL_COST);
        assertEq(garden.MAX_LEVEL(), MAX_LEVEL);
        assertEq(garden.MIN_STAKE(), MIN_STAKE);
        assertEq(garden.MAX_STAKE(), MAX_STAKE);
        assertEq(garden.LOBBY_TIMEOUT(), LOBBY_TIMEOUT);
        assertEq(garden.GENESIS(), block.timestamp);
        assertEq(garden.currentSeason(), 1);
    }

    /// The constructor refuses parameters the rules cannot run on. Accrual needs a day to divide into whole MANA
    /// (SEASON0.md §2.2), from one a day to one a second.
    function testTheConstructorRefusesUnusableParameters() public {
        Garden.Params memory params = _seasonZero();
        params.charge = 0;
        _assertRefused(params);

        params = _seasonZero();
        params.seasonLength = 0;
        _assertRefused(params);

        uint64[3] memory flows = [uint64(0), 7, 1 days + 1];
        for (uint256 i; i < flows.length; i++) {
            params = _seasonZero();
            params.manaPerDay = flows[i];
            _assertRefused(params);
        }

        params = _seasonZero();
        params.manaPerDay = 1 days;
        assertEq(new Garden(params).SECONDS_PER_MANA(), 1);
        params.manaPerDay = 1;
        assertEq(new Garden(params).SECONDS_PER_MANA(), 1 days);
    }

    /// The constructor refuses levels `attune` cannot compute: a free rise, a maximum that leaves no level above the
    /// first, a maximum whose square does not fit in the euint8 that holds the level, and a cost that would wrap in
    /// its euint64. Each bound is checked from both sides.
    function testTheConstructorRefusesUnusableLevels() public {
        Garden.Params memory params = _seasonZero();
        params.levelCost = 0;
        _assertRefused(params);

        uint8[4] memory refused = [uint8(0), 1, 16, type(uint8).max];
        for (uint256 i; i < refused.length; i++) {
            params = _seasonZero();
            params.maxLevel = refused[i];
            _assertRefused(params);
        }

        params = _seasonZero();
        params.maxLevel = 2;
        assertEq(new Garden(params).MAX_LEVEL(), 2);

        // 15² = 225: the highest cost a maximum of 15 can compute must fit in 64 bits.
        params.maxLevel = 15;
        params.levelCost = type(uint64).max / 225;
        assertEq(new Garden(params).LEVEL_COST(), type(uint64).max / 225);
        params.levelCost++;
        _assertRefused(params);
    }

    /// The constructor refuses stakes the Arena cannot run on: a zero minimum, which would make a stake symbolic
    /// (RULES.md §7), and a minimum above the maximum, which leaves no stake to choose. A single allowed stake is fine.
    function testTheConstructorRefusesUnusableStakes() public {
        Garden.Params memory params = _seasonZero();
        params.minStake = 0;
        _assertRefused(params);

        params = _seasonZero();
        params.minStake = params.maxStake + 1;
        _assertRefused(params);

        params.minStake = params.maxStake;
        Garden single = new Garden(params);
        assertEq(single.MIN_STAKE(), single.MAX_STAKE());
    }

    // -- Helpers --------------------------------------------------------------------------------------------

    function _assertNewborn(uint256 tokenId, address owner, uint256 ownerKey) internal {
        Garden.CrystalView memory crystal = garden.crystalOf(tokenId);
        assertEq(crystal.owner, owner);
        assertLt(decrypt(crystal.element, address(garden), ownerKey), 3, "an element");
        assertEq(decrypt(crystal.level, address(garden), ownerKey), 1, "level 1");
        assertEq(decrypt(crystal.mana, address(garden), ownerKey), 0, "no MANA");
        assertEq(crystal.lastAccrual, block.timestamp, "accrues from its forging");
        assertEq(crystal.pendingMana, 0);
    }

    /// The one random value a forge draws, read from the executor's event.
    function _drawOf(Vm.Log[] memory logs) internal returns (uint16) {
        bytes32 handle;
        uint256 draws;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == FHE_RAND) {
                (,, handle) = abi.decode(logs[i].data, (uint8, bytes16, bytes32));
                draws++;
            }
        }
        assertEq(draws, 1, "one random draw per forge");
        return plaintextOf(euint16.wrap(handle));
    }

    function _assertPage(address owner, uint256 cursor, uint256 count, uint256[] memory ids, uint256 next)
        internal
        view
    {
        (uint256[] memory found, uint256 actualNext) = garden.crystalsOf(owner, cursor, count);
        assertEq(found, ids, "ids");
        assertEq(actualNext, next, "next cursor");
    }

    function _assertRefused(Garden.Params memory params) internal {
        vm.expectRevert(Garden.InvalidParams.selector);
        new Garden(params);
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = a;
    }

    function _ids(uint256 a, uint256 b) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        (ids[0], ids[1]) = (a, b);
    }

    function _ids(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](4);
        (ids[0], ids[1], ids[2], ids[3]) = (a, b, c, d);
    }
}
