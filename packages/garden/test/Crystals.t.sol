// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FHE, euint8, euint16, euint64, externalEbool} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
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

/// A contract that takes crystals by `safeTransferFrom`, and notes whether, when called, it may already use the
/// crystal's level and MANA.
contract CrystalReceiver is ZamaEthereumConfig, IERC721Receiver {
    Garden internal immutable garden;
    bool public mayUseLevel;
    bool public mayUseMana;

    constructor(Garden garden_) {
        garden = garden_;
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        Garden.CrystalView memory crystal = garden.crystalOf(tokenId);
        mayUseLevel = FHE.isAllowed(crystal.level, address(this));
        mayUseMana = FHE.isAllowed(crystal.mana, address(this));
        return IERC721Receiver.onERC721Received.selector;
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

    /// RULES.md §4, Ownership: crystals are transferable tokens, and their secrets travel with them. The new owner reads
    /// the element, the level and the MANA the crystal had, and finds it among its crystals. The charge stays in the
    /// contract, held against the crystal.
    function testACrystalsSecretsTravelWithIt() public {
        uint256 tokenId = _forge(alice);
        _wait(1 days);
        _attune(alice, tokenId, true);
        Garden.CrystalView memory before = garden.crystalOf(tokenId);
        uint8 element = decrypt(before.element, address(garden), aliceKey);

        vm.expectEmit(address(garden));
        emit IERC721.Transfer(alice, bob, tokenId);
        _transfer(alice, bob, tokenId);

        Garden.CrystalView memory crystal = garden.crystalOf(tokenId);
        assertEq(crystal.owner, bob, "Bob's now");
        assertEq(decrypt(crystal.element, address(garden), bobKey), element, "the element");
        assertEq(decrypt(crystal.level, address(garden), bobKey), 2, "the level");
        assertEq(decrypt(crystal.mana, address(garden), bobKey), MANA_PER_DAY - LEVEL_COST, "the MANA");
        assertEq(crystal.lastAccrual, before.lastAccrual, "accruing as before");
        assertEq(garden.balanceOf(alice), 0);
        assertEq(garden.balanceOf(bob), 1);
        _assertPage(bob, 0, 10, _ids(tokenId), 0);
        _assertPage(alice, 0, 10, new uint256[](0), 0);
        assertEq(garden.totalSupply(), 1);
        assertEq(address(garden).balance, CHARGE);
    }

    /**
     * RULES.md §4, Ownership: every way an ERC-721 changes hands seals the crystal again for its new owner:
     * `transferFrom` and both `safeTransferFrom`, by the owner, by an account it approved or by an operator for all its
     * crystals, and a transfer to oneself. After each one the level and MANA keep their values under new handles, which
     * the new owner reads and the previous owner does not. The element keeps its handle, and everyone who has ever
     * owned the crystal reads it. The operator that moved it for others reads nothing.
     */
    function testEveryWayToTransferSealsTheCrystalAgain() public {
        (address carol, uint256 carolKey) = makeAddrAndKey("carol");
        (address operator, uint256 operatorKey) = makeAddrAndKey("operator");
        uint256 tokenId = _forge(alice);
        _wait(1 days);
        _attune(alice, tokenId, true);
        uint8 element = decrypt(garden.crystalOf(tokenId).element, address(garden), aliceKey);

        Garden.CrystalView memory before = garden.crystalOf(tokenId);
        _transfer(alice, bob, tokenId);
        _assertSealedAgain(tokenId, before, bobKey, alice, aliceKey);

        before = garden.crystalOf(tokenId);
        vm.prank(bob);
        garden.safeTransferFrom(bob, carol, tokenId);
        _assertSealedAgain(tokenId, before, carolKey, bob, bobKey);

        before = garden.crystalOf(tokenId);
        vm.prank(carol);
        garden.safeTransferFrom(carol, alice, tokenId, "a gift");
        _assertSealedAgain(tokenId, before, aliceKey, carol, carolKey);

        vm.prank(alice);
        garden.approve(operator, tokenId);
        before = garden.crystalOf(tokenId);
        vm.prank(operator);
        garden.transferFrom(alice, bob, tokenId);
        _assertSealedAgain(tokenId, before, bobKey, alice, aliceKey);

        vm.prank(bob);
        garden.setApprovalForAll(operator, true);
        before = garden.crystalOf(tokenId);
        vm.prank(operator);
        garden.safeTransferFrom(bob, carol, tokenId);
        _assertSealedAgain(tokenId, before, carolKey, bob, bobKey);

        // To oneself: sealed again, and still the owner's.
        before = garden.crystalOf(tokenId);
        _transfer(carol, carol, tokenId);
        Garden.CrystalView memory crystal = garden.crystalOf(tokenId);
        assertEq(crystal.owner, carol);
        assertNotEq(euint8.unwrap(crystal.level), euint8.unwrap(before.level), "to oneself: a new level handle");
        assertNotEq(euint64.unwrap(crystal.mana), euint64.unwrap(before.mana), "to oneself: a new MANA handle");
        assertEq(decrypt(crystal.level, address(garden), carolKey), 2, "to oneself: the level");
        assertEq(decrypt(crystal.mana, address(garden), carolKey), MANA_PER_DAY - LEVEL_COST, "to oneself: the MANA");

        assertEq(decrypt(crystal.element, address(garden), aliceKey), element, "Alice still knows the element");
        assertEq(decrypt(crystal.element, address(garden), bobKey), element, "so does Bob");
        assertEq(decrypt(crystal.element, address(garden), carolKey), element, "and Carol");
        _assertCannotDecrypt(crystal.element, operator, operatorKey);
        _assertCannotDecrypt(crystal.level, operator, operatorKey);
        _assertCannotDecrypt(crystal.mana, operator, operatorKey);
    }

    /// RULES.md §3, invariant 1, and §4: a transferred crystal is its new owner's to attune, to bring to the Arena and to
    /// shatter, and its charge returns to the new owner. Its previous owner can do none of it, nor take it back.
    function testTheNewOwnerActsAndThePreviousOneCannot() public {
        uint256 tokenId = _forge(alice);
        uint256 other = _forge(alice);
        _wait(1 days);
        _transfer(alice, bob, tokenId);

        (externalEbool choice, bytes memory proof) = encryptBool(true, address(garden), alice);
        vm.startPrank(alice);
        vm.expectRevert(Garden.NotOwner.selector);
        garden.attune(tokenId, choice, proof);
        vm.expectRevert(Garden.NotOwner.selector);
        garden.openLobby(tokenId, MIN_STAKE);
        vm.expectRevert(Garden.NotOwner.selector);
        garden.shatter(tokenId);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, alice, tokenId));
        garden.transferFrom(bob, alice, tokenId);
        vm.stopPrank();

        _attune(bob, tokenId, true);
        assertEq(decrypt(garden.crystalOf(tokenId).level, address(garden), bobKey), 2, "Bob's rise");
        uint256 duelId = _duel(tokenId, other, MIN_STAKE);
        assertEq(garden.duelOf(duelId).creatorCrystal, tokenId, "Bob's lobby");
        _publish(duelId);

        uint256 balance = bob.balance;
        _shatter(bob, tokenId);
        assertEq(bob.balance, balance + CHARGE, "the charge returns to the new owner");
        assertEq(address(garden).balance, CHARGE, "the other crystal's charge stays");
    }

    /// RULES.md §4: a contract that takes a crystal by `safeTransferFrom` is called once the crystal is sealed for it,
    /// so it may already use the level and MANA when it is called.
    function testAReceivingContractMayUseTheCrystalWhenCalled() public {
        uint256 tokenId = _forge(alice);
        CrystalReceiver receiver = new CrystalReceiver(garden);
        _wait(1 days);

        vm.prank(alice);
        garden.safeTransferFrom(alice, address(receiver), tokenId);

        assertEq(garden.ownerOf(tokenId), address(receiver));
        assertTrue(receiver.mayUseLevel(), "the level");
        assertTrue(receiver.mayUseMana(), "the MANA");
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
        assertEq(garden.SEASON_CLOSE_DELAY(), SEASON_CLOSE_DELAY);
        assertEq(garden.FIRST_SHARE(), FIRST_SHARE);
        assertEq(garden.SECOND_SHARE(), SECOND_SHARE);
        assertEq(garden.THIRD_SHARE(), THIRD_SHARE);
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

    /// The constructor refuses an Arena it cannot run: a zero minimum stake, which would make a stake symbolic
    /// (RULES.md §7), a minimum above the maximum, which leaves no stake to choose, a maximum whose double, what a
    /// duel's winner takes, does not fit in 64 bits, and a lobby timeout longer than a season, which could keep a
    /// waiting crystal from being shattered for longer. A single allowed stake is fine, and so are a timeout of a whole
    /// season and none at all.
    function testTheConstructorRefusesAnUnusableArena() public {
        Garden.Params memory params = _seasonZero();
        params.minStake = 0;
        _assertRefused(params);

        params = _seasonZero();
        params.minStake = params.maxStake + 1;
        _assertRefused(params);

        params.minStake = params.maxStake;
        Garden single = new Garden(params);
        assertEq(single.MIN_STAKE(), single.MAX_STAKE());

        params = _seasonZero();
        params.maxStake = type(uint64).max / 2;
        assertEq(new Garden(params).MAX_STAKE(), type(uint64).max / 2);
        params.maxStake++;
        _assertRefused(params);

        params = _seasonZero();
        params.lobbyTimeout = params.seasonLength + 1;
        _assertRefused(params);
        params.lobbyTimeout = params.seasonLength;
        assertEq(new Garden(params).LOBBY_TIMEOUT(), SEASON_LENGTH);
        params.lobbyTimeout = 0;
        assertEq(new Garden(params).LOBBY_TIMEOUT(), 0);
    }

    /**
     * The constructor refuses seasons it cannot close as RULES.md §8 says: shares that do not add up to the whole
     * centre, short of it or past it, where a closed season would keep back MANA forever or pay out more than it holds;
     * a place that takes more than the one above it; and a close delay longer than a season, which would hold a prize
     * back past the end of the next season. The shares 200, 100 and 56 add up to 100 in eight bits, so the sum must be
     * taken wider. A delay of a whole season and none at all are fine, and so is a split that gives everything to the
     * first place.
     */
    function testTheConstructorRefusesUnusableSeasons() public {
        uint8[3][5] memory refused = [[50, 30, 19], [50, 30, 21], [30, 50, 20], [50, 20, 30], [200, 100, 56]];
        for (uint256 i; i < refused.length; i++) {
            Garden.Params memory params = _seasonZero();
            params.prizeShares = refused[i];
            _assertRefused(params);
        }

        Garden.Params memory accepted = _seasonZero();
        accepted.prizeShares = [100, 0, 0];
        assertEq(new Garden(accepted).FIRST_SHARE(), 100);
        accepted.prizeShares = [34, 33, 33];
        assertEq(new Garden(accepted).THIRD_SHARE(), 33);

        accepted = _seasonZero();
        accepted.seasonCloseDelay = accepted.seasonLength + 1;
        _assertRefused(accepted);
        accepted.seasonCloseDelay = accepted.seasonLength;
        assertEq(new Garden(accepted).SEASON_CLOSE_DELAY(), SEASON_LENGTH);
        accepted.seasonCloseDelay = 0;
        assertEq(new Garden(accepted).SEASON_CLOSE_DELAY(), 0);
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

    /// After a transfer: the crystal is the owner's of `ownerKey`, and its level and MANA, 2 and 50 MANA in these tests,
    /// keep their values under new handles, which the new owner reads and the previous owner does not. The element
    /// keeps its handle.
    function _assertSealedAgain(
        uint256 tokenId,
        Garden.CrystalView memory before,
        uint256 ownerKey,
        address previous,
        uint256 previousKey
    ) internal {
        Garden.CrystalView memory crystal = garden.crystalOf(tokenId);
        assertEq(crystal.owner, vm.addr(ownerKey), "the new owner");
        assertNotEq(euint8.unwrap(crystal.level), euint8.unwrap(before.level), "a new level handle");
        assertNotEq(euint64.unwrap(crystal.mana), euint64.unwrap(before.mana), "a new MANA handle");
        assertEq(euint8.unwrap(crystal.element), euint8.unwrap(before.element), "the same element handle");
        assertEq(decrypt(crystal.level, address(garden), ownerKey), 2, "the new owner reads the level");
        assertEq(decrypt(crystal.mana, address(garden), ownerKey), MANA_PER_DAY - LEVEL_COST, "and the MANA");
        _assertCannotDecrypt(crystal.level, previous, previousKey);
        _assertCannotDecrypt(crystal.mana, previous, previousKey);
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
