// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FHE, euint8, euint64} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {Vm} from "forge-std/Vm.sol";
import {Garden} from "../src/Garden.sol";
import {GardenFixture} from "./utils/GardenFixture.sol";

/// The ACL lets an account allowed on a handle allow another one.
interface IAclAllow {
    function allow(bytes32 handle, address account) external;
}

/// Any contract: it encrypts the public facts a crystal is born with, and grants them to whoever it likes.
contract Mimic is ZamaEthereumConfig {
    function encryptBirthValues(address to) external returns (euint8 level, euint64 mana) {
        level = FHE.allow(FHE.asEuint8(1), to);
        mana = FHE.allow(FHE.asEuint64(0), to);
    }
}

/// A shatterer's helper. Allowed on the crystal's MANA, it recomputes in the shattering's block what a season's first
/// pot would be if it started from an encrypted plaintext 0, and grants the result to the shatterer.
contract PotRecomputer is ZamaEthereumConfig {
    function recompute(euint64 mana, uint64 accrued, address to) external returns (euint64 pot) {
        pot = FHE.allow(FHE.add(euint64.wrap(0), FHE.add(mana, accrued)), to);
    }
}

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

    /// A player cannot decrypt another player's crystal, even one forged in the same block, when the two crystals
    /// hold the same level and MANA.
    function testAnotherPlayerCannotDecryptACrystal() public {
        Garden.CrystalView memory aliceCrystal = garden.crystalOf(_forge(alice));
        Garden.CrystalView memory bobCrystal = garden.crystalOf(_forge(bob));

        _assertCannotDecrypt(aliceCrystal.element, bob, bobKey);
        _assertCannotDecrypt(aliceCrystal.level, bob, bobKey);
        _assertCannotDecrypt(aliceCrystal.mana, bob, bobKey);
        _assertCannotDecrypt(bobCrystal.element, alice, aliceKey);
        _assertCannotDecrypt(bobCrystal.level, alice, aliceKey);
        _assertCannotDecrypt(bobCrystal.mana, alice, aliceKey);
    }

    /// SEASON0.md §2.2, Handles: no two crystals share a handle, even when forged in the same block with the same
    /// level and MANA. A grant for one crystal never opens another.
    function testNoTwoCrystalsShareAHandle() public {
        uint256[3] memory tokenIds = [_forge(alice), _forge(bob), _forge(alice)];
        _wait(1);
        bytes32[] memory handles = new bytes32[](12);
        for (uint256 i; i < 4; i++) {
            Garden.CrystalView memory crystal = garden.crystalOf(i < 3 ? tokenIds[i] : _forge(bob));
            handles[3 * i] = euint8.unwrap(crystal.element);
            handles[3 * i + 1] = euint8.unwrap(crystal.level);
            handles[3 * i + 2] = euint64.unwrap(crystal.mana);
        }
        for (uint256 i; i < handles.length; i++) {
            for (uint256 j = i + 1; j < handles.length; j++) {
                assertNotEq(handles[i], handles[j], "a shared handle");
            }
        }
    }

    /// SEASON0.md §2.2, Handles: a contract that encrypts level 1 and 0 MANA in the forging block gets handles of its
    /// own, so it cannot hand out the crystal's.
    function testAContractEncryptingTheSameValuesCannotHandOutACrystal() public {
        Garden.CrystalView memory crystal = garden.crystalOf(_forge(alice));
        (euint8 level, euint64 mana) = new Mimic().encryptBirthValues(stranger);

        assertNotEq(euint8.unwrap(level), euint8.unwrap(crystal.level));
        assertNotEq(euint64.unwrap(mana), euint64.unwrap(crystal.mana));
        _assertCannotDecrypt(crystal.level, stranger, strangerKey);
        _assertCannotDecrypt(crystal.mana, stranger, strangerKey);
    }

    /// RULES.md §8 and §9: nobody can read the centre's total, not even the owner whose crystal filled it.
    /// Shattering grants only to the contract, the credited balance as accrual keeps it and then the pot, and makes
    /// nothing publicly decryptable.
    function testNobodyCanDecryptTheCentre() public {
        uint256 tokenId = _forge(alice);
        _wait(1 days);

        vm.recordLogs();
        _shatter(alice, tokenId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        euint64 pot = garden.potOf(garden.currentSeason());
        bytes32[] memory granted = _assertGrantsOnlyTo(logs, address(garden));
        assertEq(granted.length, 2, "number of grants");
        assertEq(granted[1], euint64.unwrap(pot), "the pot, last");
        _assertNothingPublic(logs);

        _assertCannotDecrypt(pot, alice, aliceKey);
        _assertCannotDecrypt(pot, stranger, strangerKey);
        _assertNotPublic(pot);
    }

    /// SEASON0.md §2.2, Handles: a shatterer holds the crystal's MANA handle, and can recompute in the same block
    /// anything made from it and from plaintexts. A season's first pot starts from the contract's own zero, so the
    /// shatterer cannot recompute it.
    function testAShattererCannotRecomputeTheCentre() public {
        uint256 tokenId = _forge(alice);
        _wait(1 days);
        Garden.CrystalView memory crystal = garden.crystalOf(tokenId);
        PotRecomputer recomputer = new PotRecomputer();
        vm.prank(alice);
        IAclAllow(getCoprocessorConfig(address(garden)).ACLAddress)
            .allow(euint64.unwrap(crystal.mana), address(recomputer));

        _shatter(alice, tokenId);
        euint64 recomputed = recomputer.recompute(crystal.mana, crystal.pendingMana, alice);

        euint64 pot = garden.potOf(garden.currentSeason());
        assertEq(plaintextOf(recomputed), plaintextOf(pot), "the same value");
        assertNotEq(euint64.unwrap(recomputed), euint64.unwrap(pot), "another handle");
        _assertCannotDecrypt(pot, alice, aliceKey);
    }
}
