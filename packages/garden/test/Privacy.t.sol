// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {euint64} from "@fhevm/solidity/lib/FHE.sol";
import {Vm} from "forge-std/Vm.sol";
import {Garden} from "../src/Garden.sol";
import {GardenFixture} from "./utils/GardenFixture.sol";

/// RULES.md §3, invariant 3, and §9: who must not be able to decrypt what.
contract PrivacyTest is GardenFixture {
    /// RULES.md §4: element, level and MANA are encrypted from the first block, and only the owner can read them.
    /// Read from the ACL's events, forging grants each to the contract and the forger and to nobody else, and makes
    /// nothing publicly decryptable (SEASON0.md §2.3, rules 4 and 5).
    function testForgingGrantsTheSecretsToTheForgerOnly() public {
        vm.recordLogs();
        uint256 tokenId = _forge(alice);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        Garden.CrystalView memory crystal = garden.crystalOf(tokenId);
        Grant[] memory grants = new Grant[](6);
        grants[0] = _grant(address(garden), crystal.element);
        grants[1] = _grant(alice, crystal.element);
        grants[2] = _grant(address(garden), crystal.level);
        grants[3] = _grant(alice, crystal.level);
        grants[4] = _grant(address(garden), crystal.mana);
        grants[5] = _grant(alice, crystal.mana);
        _assertGrants(logs, grants);
        _assertNothingPublic(logs);
    }

    /// A stranger, who owns nothing, cannot decrypt a crystal's element, level or MANA, and neither can the public.
    function testAStrangerCannotDecryptACrystal() public {
        uint256 tokenId = _forge(alice);
        _wait(1 days);
        Garden.CrystalView memory crystal = garden.crystalOf(tokenId);

        _assertCannotDecrypt(crystal.element, stranger, strangerKey);
        _assertCannotDecrypt(crystal.level, stranger, strangerKey);
        _assertCannotDecrypt(crystal.mana, stranger, strangerKey);
        _assertNotPublic(crystal.element);
        _assertNotPublic(crystal.level);
        _assertNotPublic(crystal.mana);
    }

    /**
     * @dev A player cannot decrypt the element of another player's crystal.
     *
     *      The level and MANA at birth are left out on purpose. The protocol derives a handle from its operation, its
     *      operands and the block, not from the contract or the caller, so crystals forged in the same block share
     *      those two handles, and each owner can decrypt the other's. Both values are public facts, level 1 and no
     *      MANA, so this reveals nothing (SEASON0.md §2.2). The element comes from a random draw, which no two
     *      crystals share.
     */
    function testAnotherPlayerCannotDecryptTheElement() public {
        uint256 aliceCrystal = _forge(alice);
        uint256 bobCrystal = _forge(bob);
        _assertCannotDecrypt(garden.crystalOf(aliceCrystal).element, bob, bobKey);
        _assertCannotDecrypt(garden.crystalOf(bobCrystal).element, alice, aliceKey);
    }

    /// RULES.md §8 and §9: nobody can read the centre's total, not even the owner whose crystal filled it.
    /// Shattering grants the pot to the contract alone, and makes nothing publicly decryptable.
    function testNobodyCanDecryptTheCentre() public {
        uint256 tokenId = _forge(alice);
        _wait(1 days);

        vm.recordLogs();
        _shatter(alice, tokenId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        euint64 pot = garden.potOf(garden.currentSeason());
        Grant[] memory grants = new Grant[](1);
        grants[0] = _grant(address(garden), pot);
        _assertGrants(logs, grants);
        _assertNothingPublic(logs);

        _assertCannotDecrypt(pot, alice, aliceKey);
        _assertCannotDecrypt(pot, stranger, strangerKey);
        _assertNotPublic(pot);
    }
}
