// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FHE, ebool, euint8, euint64, externalEbool} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {Vm} from "forge-std/Vm.sol";
import {Garden} from "../src/Garden.sol";
import {GardenFixture, IAcl} from "./utils/GardenFixture.sol";

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

/**
 * @dev A contract that owns a crystal. It attunes it, then in the same transaction recomputes what `attune` computed,
 *      from the handles it holds: the crystal's, as its owner, and the choice, which importing the input left it
 *      allowed on until the transaction ends. It repeats `attune` operation by operation, so a change to those
 *      operations must be made here too: operands combined another way give other handles.
 */
contract AttuneRecomputer is ZamaEthereumConfig {
    function forge(Garden garden) external payable returns (uint256) {
        return garden.forge{value: msg.value}();
    }

    /// Returns the crystal's new MANA and what the season's first pot would be if it started from an encrypted
    /// plaintext 0, granted to `to`.
    function attuneAndRecompute(Garden garden, uint256 tokenId, externalEbool rise, bytes calldata proof, address to)
        external
        returns (euint64 mana, euint64 pot)
    {
        Garden.CrystalView memory before = garden.crystalOf(tokenId);
        garden.attune(tokenId, rise, proof);

        euint64 credited = FHE.add(before.mana, before.pendingMana);
        euint64 spent = _spent(garden, before.level, credited, ebool.wrap(externalEbool.unwrap(rise)));
        mana = FHE.sub(credited, spent);
        pot = FHE.allow(FHE.add(FHE.asEuint64(0), spent), to);
    }

    function _spent(Garden garden, euint8 level, euint64 credited, ebool choice) internal returns (euint64) {
        euint64 cost = FHE.mul(FHE.asEuint64(FHE.mul(level, level)), garden.LEVEL_COST());
        ebool rises = FHE.and(FHE.and(choice, FHE.lt(level, garden.MAX_LEVEL())), FHE.ge(credited, cost));
        return FHE.select(rises, cost, FHE.asEuint64(0));
    }
}

/// A contract that owns a crystal. It opens a lobby, then in the same transaction recomputes `creatorPaid` from what it
/// holds as the owner, the crystal's MANA, and the public stake, and grants the result to `to`.
contract PaidRecomputer is ZamaEthereumConfig {
    function forge(Garden garden) external payable returns (uint256) {
        return garden.forge{value: msg.value}();
    }

    function openAndRecompute(Garden garden, uint256 tokenId, uint64 stake, address to) external returns (ebool paid) {
        Garden.CrystalView memory before = garden.crystalOf(tokenId);
        garden.openLobby(tokenId, stake);
        paid = FHE.allow(FHE.ge(FHE.add(before.mana, before.pendingMana), stake), to);
    }
}

/// A contract that owns crystals and fights with them, then tries to compute on handles. In a forge test, which is one
/// transaction, it still holds every transient grant it was given along the way, so it probes with all it could have.
contract DuelProber is ZamaEthereumConfig {
    function forge(Garden garden) external payable returns (uint256) {
        return garden.forge{value: msg.value}();
    }

    function openLobby(Garden garden, uint256 tokenId, uint64 stake) external returns (uint256) {
        return garden.openLobby(tokenId, stake);
    }

    function joinLobby(Garden garden, uint256 lobbyId, uint256 tokenId) external returns (uint256) {
        return garden.joinLobby(lobbyId, tokenId);
    }

    function negate(ebool value) external returns (ebool) {
        return FHE.not(value);
    }

    function addOne(euint64 value) external returns (euint64) {
        return FHE.add(value, 1);
    }

    function grant(ebool value, address to) external {
        FHE.allow(value, to);
    }
}

/**
 * @dev A contract that owns a crystal. It transfers the crystal, then in the same transaction, so in the same block,
 *      tries to recompute the new level and MANA from what it still holds as their previous owner: the old handles. It
 *      repeats the reseal's operations, so a change to the reseal must be made here too.
 */
contract ResealRecomputer is ZamaEthereumConfig {
    function forge(Garden garden) external payable returns (uint256) {
        return garden.forge{value: msg.value}();
    }

    function attune(Garden garden, uint256 tokenId, externalEbool rise, bytes calldata proof) external {
        garden.attune(tokenId, rise, proof);
    }

    /// Transfers the crystal, then seals its old level and MANA again as Garden does, but with the zeros anyone can make,
    /// a plaintext one and an encrypted one, and grants the results to `to`: the level twice, then the MANA twice.
    /// Making the encrypted zeros leaves it allowed on them until the transaction ends.
    function transferAndRecompute(Garden garden, uint256 tokenId, address newOwner, address to)
        external
        returns (bytes32[4] memory handles)
    {
        Garden.CrystalView memory before = garden.crystalOf(tokenId);
        garden.transferFrom(address(this), newOwner, tokenId);
        handles[0] = euint8.unwrap(FHE.allow(FHE.or(before.level, 0), to));
        handles[1] = euint8.unwrap(FHE.allow(FHE.or(before.level, FHE.asEuint8(0)), to));
        handles[2] = euint64.unwrap(FHE.allow(FHE.or(before.mana, 0), to));
        handles[3] = euint64.unwrap(FHE.allow(FHE.or(before.mana, FHE.asEuint64(0)), to));
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
        IAcl(getCoprocessorConfig(address(garden)).ACLAddress).allow(euint64.unwrap(crystal.mana), address(recomputer));

        _shatter(alice, tokenId);
        euint64 recomputed = recomputer.recompute(crystal.mana, crystal.pendingMana, alice);

        euint64 pot = garden.potOf(garden.currentSeason());
        assertEq(plaintextOf(recomputed), plaintextOf(pot), "the same value");
        assertNotEq(euint64.unwrap(recomputed), euint64.unwrap(pot), "another handle");
        _assertCannotDecrypt(pot, alice, aliceKey);
    }

    // -- Attunement -----------------------------------------------------------------------------------------

    /// RULES.md §6 and §9: what an attunement did, only its owner can read. Read from the ACL's events, attuning
    /// grants the new level and MANA to the contract and the owner, the pot to the contract alone, and the credited
    /// balance, as accrual keeps it, to the contract. Nothing becomes publicly decryptable.
    function testAttuningGrantsTheNewValuesToTheOwnerOnly() public {
        uint256 tokenId = _forge(alice);
        _wait(1 days);
        (externalEbool choice, bytes memory proof) = encryptBool(true, address(garden), alice);

        vm.recordLogs();
        vm.prank(alice);
        garden.attune(tokenId, choice, proof);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertNothingPublic(logs);

        Garden.CrystalView memory crystal = garden.crystalOf(tokenId);
        euint64 pot = garden.potOf(1);
        // The credit is the first grant. Its handle is no longer stored, so it is checked by its value.
        bytes32 credit = _assertGrantsOnlyTo(_firstGrant(logs), address(garden))[0];
        assertEq(plaintextOf(euint64.wrap(credit)), MANA_PER_DAY, "the credited balance");

        Grant[] memory grants = new Grant[](6);
        grants[0] = Grant(address(garden), credit);
        grants[1] = _grant(address(garden), crystal.level);
        grants[2] = _grant(alice, crystal.level);
        grants[3] = _grant(address(garden), crystal.mana);
        grants[4] = _grant(alice, crystal.mana);
        grants[5] = _grant(address(garden), pot);
        _assertGrants(logs, grants);
    }

    /// RULES.md §6 and §9: after an attunement nobody else can read the crystal's level or MANA, and nobody at all,
    /// not even the owner who paid into it, can read the centre.
    function testNobodyElseCanReadAnAttunedCrystalOrTheCentre() public {
        uint256 tokenId = _forge(alice);
        _forge(bob);
        _wait(1 days);
        _attune(alice, tokenId, true);

        Garden.CrystalView memory crystal = garden.crystalOf(tokenId);
        assertEq(decrypt(crystal.level, address(garden), aliceKey), 2, "the owner reads the level");
        assertEq(decrypt(crystal.mana, address(garden), aliceKey), MANA_PER_DAY - LEVEL_COST, "and the MANA");
        _assertCannotDecrypt(crystal.level, bob, bobKey);
        _assertCannotDecrypt(crystal.mana, bob, bobKey);
        _assertCannotDecrypt(crystal.level, stranger, strangerKey);
        _assertCannotDecrypt(crystal.mana, stranger, strangerKey);
        _assertNotPublic(crystal.level);
        _assertNotPublic(crystal.mana);

        euint64 pot = garden.potOf(1);
        _assertCannotDecrypt(pot, alice, aliceKey);
        _assertCannotDecrypt(pot, bob, bobKey);
        _assertNotPublic(pot);
    }

    /// SEASON0.md §2.2, Handles: an owner can recompute what attune computed, because it holds the crystal's handles
    /// and, until the transaction ends, the choice. A contract that owns a crystal can do it in the same transaction.
    /// It gets the crystal's new MANA, which it may read anyway, but not the centre: a season's first pot starts from
    /// the contract's own zero.
    function testAnAttunerCannotRecomputeTheCentre() public {
        AttuneRecomputer recomputer = new AttuneRecomputer();
        uint256 tokenId = recomputer.forge{value: CHARGE}(garden);
        _wait(1 days);
        (externalEbool choice, bytes memory proof) = encryptBool(true, address(garden), address(recomputer));

        (euint64 mana, euint64 recomputed) = recomputer.attuneAndRecompute(garden, tokenId, choice, proof, alice);

        assertEq(euint64.unwrap(mana), euint64.unwrap(garden.crystalOf(tokenId).mana), "the recomputation is exact");
        euint64 pot = garden.potOf(1);
        // A forge test is one transaction, so the attacker still holds every grant it was given or made itself in this
        // one: the choice, and every handle it computed, the cost of the rise among them. The pot is none of them.
        IAcl acl = IAcl(getCoprocessorConfig(address(garden)).ACLAddress);
        assertFalse(acl.isAllowed(euint64.unwrap(pot), address(recomputer)), "the attacker may use the pot");
        assertEq(plaintextOf(recomputed), LEVEL_COST, "the cost of the rise");
        assertEq(plaintextOf(pot), LEVEL_COST, "the same value");
        assertNotEq(euint64.unwrap(recomputed), euint64.unwrap(pot), "another handle");
        _assertCannotDecrypt(pot, alice, aliceKey);
    }

    // -- The Arena -----------------------------------------------------------------------------------------------

    /// RULES.md §7 and §9: a lobby's stake is public, whether its creator could pay it is not. Read from the ACL's
    /// events, opening a lobby grants the credited balance to the contract, as accrual keeps it, the new balance to the
    /// contract and the owner, and `creatorPaid` to the contract alone. Nothing becomes publicly decryptable, and
    /// nobody else can read the balance or `creatorPaid`.
    function testOpeningALobbyGrantsTheNewBalanceToTheOwnerOnly() public {
        uint256 tokenId = _forge(alice);
        _forge(bob);
        _wait(1 days);

        vm.recordLogs();
        uint256 lobbyId = _openLobby(tokenId, 40);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertNothingPublic(logs);

        Grant[] memory grants = _grantsIn(logs);
        assertEq(grants.length, 4, "number of grants");
        _assertCredit(grants[0], MANA_PER_DAY);
        _assertGrant(grants[1], address(garden), euint64.unwrap(garden.crystalOf(tokenId).mana));
        _assertGrant(grants[2], alice, euint64.unwrap(garden.crystalOf(tokenId).mana));
        _assertGrant(grants[3], address(garden), ebool.unwrap(garden.lobbyOf(lobbyId).creatorPaid));

        euint64 mana = garden.crystalOf(tokenId).mana;
        ebool paid = garden.lobbyOf(lobbyId).creatorPaid;
        _assertCannotDecrypt(mana, bob, bobKey);
        _assertCannotDecrypt(mana, stranger, strangerKey);
        _assertNotPublic(mana);
        _assertCannotDecrypt(paid, bob, bobKey);
        _assertCannotDecrypt(paid, stranger, strangerKey);
        _assertNotPublic(paid);
    }

    /**
     * RULES.md §3, invariant 3, and §7: a duel publishes who won and nothing else. Read from the ACL's events, joining
     * grants both credited balances to the contract, each new balance to the contract and its own owner, and the
     * outcome to the contract, and makes the outcome, and only it, publicly decryptable. Each player reads its own
     * balance; the opponent, a stranger and the public read neither.
     */
    function testADuelRevealsOnlyItsOutcome() public {
        uint256 a = _forge(alice);
        uint256 b = _forge(bob);
        _wait(1 days);
        uint256 lobbyId = _openLobby(a, 40);
        _wait(1 days);

        vm.recordLogs();
        uint256 duelId = _join(lobbyId, b);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        euint64 manaA = garden.crystalOf(a).mana;
        euint64 manaB = garden.crystalOf(b).mana;
        ebool outcome = garden.duelOf(duelId).creatorWins;
        Grant[] memory grants = _grantsIn(logs);
        assertEq(grants.length, 7, "number of grants");
        _assertCredit(grants[0], MANA_PER_DAY - 40 + MANA_PER_DAY);
        _assertCredit(grants[1], 2 * MANA_PER_DAY);
        _assertGrant(grants[2], address(garden), euint64.unwrap(manaA));
        _assertGrant(grants[3], alice, euint64.unwrap(manaA));
        _assertGrant(grants[4], address(garden), euint64.unwrap(manaB));
        _assertGrant(grants[5], bob, euint64.unwrap(manaB));
        _assertGrant(grants[6], address(garden), ebool.unwrap(outcome));
        bytes32[] memory revealed = _madePublic(logs);
        assertEq(revealed.length, 1, "one handle made public");
        assertEq(revealed[0], ebool.unwrap(outcome), "the outcome");

        // The outcome is public. Each balance is its owner's alone.
        bool creatorWon = decryptPublic(outcome);
        uint64 expectedA = creatorWon ? 2 * MANA_PER_DAY + 40 : 2 * MANA_PER_DAY - 40;
        assertEq(decrypt(manaA, address(garden), aliceKey), expectedA, "Alice reads hers");
        assertEq(decrypt(manaB, address(garden), bobKey), 4 * MANA_PER_DAY - expectedA, "Bob reads his");
        _assertCannotDecrypt(manaA, bob, bobKey);
        _assertCannotDecrypt(manaA, stranger, strangerKey);
        _assertCannotDecrypt(manaB, alice, aliceKey);
        _assertCannotDecrypt(manaB, stranger, strangerKey);
        _assertNotPublic(manaA);
        _assertNotPublic(manaB);
        // Neither crystal's element or level was granted to anyone new.
        _assertCannotDecrypt(garden.crystalOf(a).element, bob, bobKey);
        _assertCannotDecrypt(garden.crystalOf(a).level, bob, bobKey);
        _assertCannotDecrypt(garden.crystalOf(b).element, alice, aliceKey);
        _assertCannotDecrypt(garden.crystalOf(b).level, alice, aliceKey);
    }

    /// RULES.md §7: cancelling grants the credited balance to the contract and the new balance to the contract and the
    /// owner, and reveals nothing.
    function testCancellingGrantsTheNewBalanceToTheOwnerOnly() public {
        uint256 tokenId = _forge(alice);
        _wait(1 days);
        uint256 lobbyId = _openLobby(tokenId, 40);
        _wait(LOBBY_TIMEOUT);

        vm.recordLogs();
        _cancel(lobbyId);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertNothingPublic(logs);

        euint64 mana = garden.crystalOf(tokenId).mana;
        Grant[] memory grants = _grantsIn(logs);
        assertEq(grants.length, 3, "number of grants");
        _assertCredit(grants[0], MANA_PER_DAY - 40 + MANA_PER_DAY);
        _assertGrant(grants[1], address(garden), euint64.unwrap(mana));
        _assertGrant(grants[2], alice, euint64.unwrap(mana));
        assertEq(decrypt(mana, address(garden), aliceKey), 2 * MANA_PER_DAY, "the stake came back");
        _assertCannotDecrypt(mana, stranger, strangerKey);
        _assertNotPublic(mana);
    }

    /// SEASON0.md §2.2, Handles: `creatorPaid` is granted to the contract alone, but the creator can recompute it in the
    /// opening block from its own MANA and the public stake, and learn whether it paid, which it knew. Nobody else holds
    /// the crystal's MANA, so nobody else can compute on it.
    function testOnlyTheCreatorCanRecomputeWhetherItPaid() public {
        PaidRecomputer creator = new PaidRecomputer();
        uint256 tokenId = creator.forge{value: CHARGE}(garden);
        _wait(1 days);

        ebool recomputed = creator.openAndRecompute(garden, tokenId, 40, alice);

        ebool paid = garden.lobbyOf(garden.lastLobbyId()).creatorPaid;
        assertEq(ebool.unwrap(recomputed), ebool.unwrap(paid), "the same handle");
        assertTrue(decrypt(paid, address(garden), aliceKey), "the creator's side reads that it paid");
        _assertCannotDecrypt(paid, stranger, strangerKey);
        _assertNotPublic(paid);

        DuelProber snoop = new DuelProber();
        euint64 mana = garden.crystalOf(tokenId).mana;
        vm.expectRevert(abi.encodeWithSignature("ACLNotAllowed(bytes32,address)", euint64.unwrap(mana), address(snoop)));
        snoop.addOne(mana);
    }

    /// A challenger's contract that has just fought holds no grant on the creator's handles: not `creatorPaid`, nor
    /// the creator's balance, element or level. It holds its own new balance, which shows that the probe can see a
    /// grant.
    function testAChallengerCannotComputeOnTheCreatorsHandles() public {
        uint256 a = _forge(alice);
        DuelProber challenger = new DuelProber();
        uint256 b = challenger.forge{value: CHARGE}(garden);
        _wait(1 days);
        uint256 lobbyId = _openLobby(a, 40);
        ebool paid = garden.lobbyOf(lobbyId).creatorPaid;

        challenger.joinLobby(garden, lobbyId, b);

        IAcl acl = IAcl(getCoprocessorConfig(address(garden)).ACLAddress);
        Garden.CrystalView memory creator = garden.crystalOf(a);
        assertFalse(acl.isAllowed(ebool.unwrap(paid), address(challenger)), "creatorPaid");
        assertFalse(acl.isAllowed(euint64.unwrap(creator.mana), address(challenger)), "the creator's MANA");
        assertFalse(acl.isAllowed(euint8.unwrap(creator.element), address(challenger)), "the creator's element");
        assertFalse(acl.isAllowed(euint8.unwrap(creator.level), address(challenger)), "the creator's level");
        assertTrue(acl.isAllowed(euint64.unwrap(garden.crystalOf(b).mana), address(challenger)), "its own MANA");
        vm.expectRevert(
            abi.encodeWithSignature("ACLNotAllowed(bytes32,address)", ebool.unwrap(paid), address(challenger))
        );
        challenger.negate(paid);
    }

    /**
     * SEASON0.md §2.2, Handles: the coin, which only Garden draws, enters the outcome and through it both new balances,
     * so nobody can recompute them, not even an owner holding both crystals' handles. Here a contract owns both crystals
     * and fights itself. The outcome is publicly decryptable, but decrypting is not computing: the owner may use
     * neither the outcome nor the coin, nor grant the outcome to anyone, and neither may anyone else.
     */
    function testNobodyCanComputeOnADuelsOutcomeOrItsCoin() public {
        DuelProber owner = new DuelProber();
        uint256 a = owner.forge{value: CHARGE}(garden);
        uint256 b = owner.forge{value: CHARGE}(garden);
        _wait(1 days);
        uint256 lobbyId = owner.openLobby(garden, a, 40);

        vm.recordLogs();
        uint256 duelId = owner.joinLobby(garden, lobbyId, b);
        bytes32 coin = _drawIn(vm.getRecordedLogs());
        ebool outcome = garden.duelOf(duelId).creatorWins;

        IAcl acl = IAcl(getCoprocessorConfig(address(garden)).ACLAddress);
        assertTrue(acl.isAllowedForDecryption(ebool.unwrap(outcome)), "the outcome is public");
        assertFalse(acl.isAllowed(ebool.unwrap(outcome), address(owner)), "the outcome");
        assertFalse(acl.isAllowed(coin, address(owner)), "the coin");
        assertTrue(acl.isAllowed(euint64.unwrap(garden.crystalOf(a).mana), address(owner)), "its own balance");

        vm.expectRevert(
            abi.encodeWithSignature("ACLNotAllowed(bytes32,address)", ebool.unwrap(outcome), address(owner))
        );
        owner.negate(outcome);
        vm.expectRevert(abi.encodeWithSignature("ACLNotAllowed(bytes32,address)", coin, address(owner)));
        owner.negate(ebool.wrap(coin));
        vm.expectRevert(abi.encodeWithSignature("SenderNotAllowed(address)", address(owner)));
        owner.grant(outcome, stranger);
        DuelProber snoop = new DuelProber();
        vm.expectRevert(
            abi.encodeWithSignature("ACLNotAllowed(bytes32,address)", ebool.unwrap(outcome), address(snoop))
        );
        snoop.negate(outcome);
    }

    /**
     * RULES.md §3, invariant 3, and SEASON0.md §2.3, rules 4 and 5: publishing a duel grants nothing and makes nothing
     * else public. Anyone can publish, so a grant here would hand secrets to whoever asks. Read from the ACL's events,
     * a result that counts for its season, which ranks the winner, and one that counts only in the records each grant
     * nothing and reveal nothing. Then the publisher may use none of the duel's handles, not even for the rest of the
     * transaction, which a forge test still is: both crystals', the outcome, what the creator put up, and the centre.
     */
    function testPublishingGrantsNothingAndRevealsNothing() public {
        uint256[4] memory crystals = [_forge(alice), _forge(bob), _forge(alice), _forge(bob)];
        _wait(1 days);
        // A rise puts MANA in season 1's centre, so that its pot has a handle to check.
        _attune(alice, crystals[2], true);
        uint256 lateLobby = _openLobby(crystals[2], 40);
        uint256 late = _join(lateLobby, crystals[3]);
        // Season 1 can be closed now, so its duel counts only in the records. The next one counts for season 2.
        _waitUntilClosable(1);
        uint256 countedLobby = _openLobby(crystals[0], 40);
        uint256 counted = _join(countedLobby, crystals[1]);

        _assertPublishingGrantsNothing(counted, countedLobby, "a result that counts");
        assertTrue(_top(2)[0] != 0, "the result counted for season 2");
        _assertPublishingGrantsNothing(late, lateLobby, "a result in the records only");
        assertEq(_top(1)[0], 0, "season 1's ranking did not move");
    }

    // -- Seasons --------------------------------------------------------------------------------------------------

    /**
     * RULES.md §8 and §9: closing a season credits each winner's share to its balance, which only its owner can read,
     * and keeps the centre unreadable. Read from the ACL's events, closing grants each winner's credited balance to the
     * contract, as accrual keeps it, each new balance to the contract and its own owner, and the new pot of the season in
     * progress to the contract alone. Nothing becomes publicly decryptable. Each winner reads its own balance; the other
     * winners' owners and a stranger read none, and nobody reads the centre, neither the closed one nor the new one.
     */
    function testClosingASeasonGrantsEachShareToItsWinnerOnly() public {
        // Forging, fighting and closing in one forge test, which is one transaction, would hit the HCU caps that
        // Hcu.t.sol measures each call against.
        disableHCULimits();
        (address carol, uint256 carolKey) = makeAddrAndKey("carol");
        vm.deal(carol, 1 ether);
        address[3] memory owners = [alice, bob, carol];
        uint256[3] memory keys = [aliceKey, bobKey, carolKey];
        uint256[3] memory top = _rankThree(owners);
        _fillThePot();

        _waitUntilClosable(1);
        uint64[3] memory credited;
        for (uint256 place; place < 3; place++) {
            credited[place] = _balanceOf(top[place], keys[place]);
        }
        euint64 closedPot = garden.potOf(1);
        vm.recordLogs();
        _closeSeason(1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertNothingPublic(logs);

        Grant[] memory grants = _grantsIn(logs);
        assertEq(grants.length, 10, "number of grants");
        euint64[3] memory mana;
        for (uint256 place; place < 3; place++) {
            mana[place] = garden.crystalOf(top[place]).mana;
            _assertCredit(grants[3 * place], credited[place]);
            _assertGrant(grants[3 * place + 1], address(garden), euint64.unwrap(mana[place]));
            _assertGrant(grants[3 * place + 2], owners[place], euint64.unwrap(mana[place]));
        }
        euint64 newPot = garden.potOf(2);
        _assertGrant(grants[9], address(garden), euint64.unwrap(newPot));

        for (uint256 place; place < 3; place++) {
            assertGt(decrypt(mana[place], address(garden), keys[place]), credited[place], "the owner reads its share");
            for (uint256 other; other < 3; other++) {
                if (other != place) _assertCannotDecrypt(mana[place], owners[other], keys[other]);
            }
            _assertCannotDecrypt(mana[place], stranger, strangerKey);
            _assertNotPublic(mana[place]);
            _assertCannotDecrypt(closedPot, owners[place], keys[place]);
            _assertCannotDecrypt(newPot, owners[place], keys[place]);
        }
        _assertCannotDecrypt(closedPot, stranger, strangerKey);
        _assertCannotDecrypt(newPot, stranger, strangerKey);
        _assertNotPublic(closedPot);
        _assertNotPublic(newPot);
    }

    /**
     * SEASON0.md §2.2, Handles: every share descends from the closed season's pot, which only the contract holds, so a
     * winner can compute on neither that pot nor the new pot of the season in progress, and so cannot recompute its
     * share or its new balance: it can only decrypt the balance. Here a contract owns the crystal that takes the first
     * place. In a forge test it still holds every transient grant it was given, and it holds its new balance, which
     * shows that the probe can see a grant.
     */
    function testAWinnerCannotComputeOnTheCentre() public {
        disableHCULimits();
        DuelProber winner = new DuelProber();
        uint256 water;
        for (uint256 i; i < 40 && water == 0; i++) {
            uint256 tokenId = winner.forge{value: CHARGE}(garden);
            if (plaintextOf(garden.crystalOf(tokenId).element) == WATER) water = tokenId;
        }
        uint256 fire = _forgeElement(alice, FIRE);
        uint256 lobbyId = winner.openLobby(garden, water, MIN_STAKE);
        _join(lobbyId, fire);
        _publish(garden.lastDuelId());
        _fillThePot();

        _waitUntilClosable(1);
        euint64 closedPot = garden.potOf(1);
        _closeSeason(1);

        IAcl acl = IAcl(getCoprocessorConfig(address(garden)).ACLAddress);
        euint64 newPot = garden.potOf(2);
        assertEq(_top(1)[0], water, "the contract's crystal takes the first place");
        assertTrue(acl.isAllowed(euint64.unwrap(garden.crystalOf(water).mana), address(winner)), "its own balance");
        assertFalse(acl.isAllowed(euint64.unwrap(closedPot), address(winner)), "the closed centre");
        assertFalse(acl.isAllowed(euint64.unwrap(newPot), address(winner)), "the new centre");
        vm.expectRevert(
            abi.encodeWithSignature("ACLNotAllowed(bytes32,address)", euint64.unwrap(closedPot), address(winner))
        );
        winner.addOne(closedPot);
        vm.expectRevert(
            abi.encodeWithSignature("ACLNotAllowed(bytes32,address)", euint64.unwrap(newPot), address(winner))
        );
        winner.addOne(newPot);
    }

    // -- Transfers ------------------------------------------------------------------------------------------------

    /**
     * RULES.md §4 and §9, and T07: on a transfer the level and MANA are sealed again for the new owner, so the previous
     * owner loses sight of them. She cannot decrypt the new handles, nor can a stranger, and nothing is public. The new
     * owner reads all three secrets. The element keeps its handle, which the previous owner still reads: she knew it,
     * and it never changes. What she read before the transfer she can still read, but those handles are no longer the
     * crystal's. And she loses sight for good: once the new owner attunes, she reads neither the new level nor the new
     * MANA.
     */
    function testThePreviousOwnerCannotDecryptTheNewLevelAndMana() public {
        uint256 tokenId = _forge(alice);
        _wait(1 days);
        _attune(alice, tokenId, true);
        Garden.CrystalView memory before = garden.crystalOf(tokenId);
        uint8 element = decrypt(before.element, address(garden), aliceKey);

        _transfer(alice, bob, tokenId);

        Garden.CrystalView memory crystal = garden.crystalOf(tokenId);
        assertNotEq(euint8.unwrap(crystal.level), euint8.unwrap(before.level), "a new level handle");
        assertNotEq(euint64.unwrap(crystal.mana), euint64.unwrap(before.mana), "a new MANA handle");
        assertEq(euint8.unwrap(crystal.element), euint8.unwrap(before.element), "the same element handle");
        assertEq(decrypt(crystal.element, address(garden), bobKey), element, "Bob reads the element");
        assertEq(decrypt(crystal.level, address(garden), bobKey), 2, "the level");
        assertEq(decrypt(crystal.mana, address(garden), bobKey), MANA_PER_DAY - LEVEL_COST, "and the MANA");

        _assertCannotDecrypt(crystal.level, alice, aliceKey);
        _assertCannotDecrypt(crystal.mana, alice, aliceKey);
        _assertCannotDecrypt(crystal.level, stranger, strangerKey);
        _assertCannotDecrypt(crystal.mana, stranger, strangerKey);
        _assertCannotDecrypt(crystal.element, stranger, strangerKey);
        _assertNotPublic(crystal.level);
        _assertNotPublic(crystal.mana);
        _assertNotPublic(crystal.element);
        assertEq(decrypt(crystal.element, address(garden), aliceKey), element, "Alice still knows the element");
        assertEq(decrypt(before.level, address(garden), aliceKey), 2, "and what she read before");

        // Two more days give Bob's crystal the 200 MANA a rise from level 2 costs.
        _wait(2 days);
        _attune(bob, tokenId, true);
        crystal = garden.crystalOf(tokenId);
        assertEq(decrypt(crystal.level, address(garden), bobKey), 3, "Bob's rise");
        _assertCannotDecrypt(crystal.level, alice, aliceKey);
        _assertCannotDecrypt(crystal.mana, alice, aliceKey);
    }

    /**
     * SEASON0.md §2.2, Handles and Transfer: the previous owner still holds the old level and MANA, and in the transfer's
     * block can compute on anything made from them. Here a contract that owns a crystal transfers it to Bob and at once
     * seals the old values again for Alice, as Garden does but with the zeros anyone can make: it gets the same values
     * under other handles, which open nothing of the crystal's. Nor could it make the new handles any other way: walked
     * back through the executor's events, each descends from GARDEN_ZERO, which it may not use, and which nobody but
     * Garden can make (`testOnlyGardenHoldsItsZero`). The logs start before the crystal is forged, so the walk sees all
     * of its history. A forge test is one transaction, so the attacker holds every transient grant it could have: the
     * choice of its own attunement, and the zeros it encrypted.
     */
    function testThePreviousOwnerCannotRecomputeTheReseal() public {
        vm.recordLogs();
        ResealRecomputer previous = new ResealRecomputer();
        uint256 tokenId = previous.forge{value: CHARGE}(garden);
        _wait(1 days);
        {
            (externalEbool choice, bytes memory proof) = encryptBool(true, address(garden), address(previous));
            previous.attune(garden, tokenId, choice, proof);
        }
        Garden.CrystalView memory before = garden.crystalOf(tokenId);

        bytes32[4] memory recomputed = previous.transferAndRecompute(garden, tokenId, bob, alice);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        Garden.CrystalView memory crystal = garden.crystalOf(tokenId);
        assertEq(plaintextOf(crystal.level), 2, "the level");
        assertEq(plaintextOf(crystal.mana), MANA_PER_DAY - LEVEL_COST, "the MANA");
        for (uint256 i; i < 2; i++) {
            assertEq(plaintextOf(euint8.wrap(recomputed[i])), 2, "a recomputed level");
            assertNotEq(recomputed[i], euint8.unwrap(crystal.level), "another level handle");
            assertEq(plaintextOf(euint64.wrap(recomputed[2 + i])), MANA_PER_DAY - LEVEL_COST, "a recomputed MANA");
            assertNotEq(recomputed[2 + i], euint64.unwrap(crystal.mana), "another MANA handle");
        }
        IAcl acl = IAcl(getCoprocessorConfig(address(garden)).ACLAddress);
        assertFalse(acl.isAllowed(euint8.unwrap(crystal.level), address(previous)), "the attacker may use the level");
        assertFalse(acl.isAllowed(euint64.unwrap(crystal.mana), address(previous)), "the attacker may use the MANA");
        _assertCannotDecrypt(crystal.level, alice, aliceKey);
        _assertCannotDecrypt(crystal.mana, alice, aliceKey);

        assertTrue(_withinReach(logs, euint8.unwrap(before.level), address(previous)), "the old level, within reach");
        assertTrue(_withinReach(logs, euint64.unwrap(before.mana), address(previous)), "the old MANA, within reach");
        assertFalse(_withinReach(logs, euint8.unwrap(crystal.level), address(previous)), "the new level, within reach");
        assertFalse(_withinReach(logs, euint64.unwrap(crystal.mana), address(previous)), "the new MANA, within reach");
        assertTrue(_withinReach(logs, euint8.unwrap(crystal.level), bob), "the new owner holds the level");
    }

    /**
     * The walk the two tests around this one rely on must see through operations, or it would find every handle out of
     * reach and pass anything. What an owner's own attunement spent is granted to Garden alone, yet the owner could make
     * it in that transaction from its level, its MANA and its choice: through a select, ands, comparisons, an addition
     * of a plaintext, a cast, multiplications with and without a plaintext, and a trivial encryption. A stranger could
     * not. The owner makes no handle of its own here, which would hand it grants that cut the walk short.
     */
    function testTheWalkSeesThroughOperations() public {
        vm.recordLogs();
        ResealRecomputer owner = new ResealRecomputer();
        uint256 tokenId = owner.forge{value: CHARGE}(garden);
        _wait(1 days);
        (externalEbool choice, bytes memory proof) = encryptBool(true, address(garden), address(owner));
        owner.attune(garden, tokenId, choice, proof);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // The attunement's last step on the MANA is `sub(credited, spent)`, read from the executor's event.
        bytes32 mana = euint64.unwrap(garden.crystalOf(tokenId).mana);
        bytes32 spent;
        address executor = getCoprocessorConfig(address(garden)).CoprocessorAddress;
        bytes32 fheSub = keccak256("FheSub(address,bytes32,bytes32,bytes1,bytes32)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != executor || logs[i].topics.length == 0 || logs[i].topics[0] != fheSub) continue;
            (, bytes32 rhs,, bytes32 result) = abi.decode(logs[i].data, (bytes32, bytes32, bytes1, bytes32));
            if (result == mana) spent = rhs;
        }
        assertNotEq(spent, bytes32(0), "the spent MANA");
        assertEq(plaintextOf(euint64.wrap(spent)), LEVEL_COST, "a rise");
        IAcl acl = IAcl(getCoprocessorConfig(address(garden)).ACLAddress);
        assertFalse(acl.isAllowed(spent, address(owner)), "granted to the owner");
        assertTrue(_withinReach(logs, spent, address(owner)), "within the owner's reach");
        assertFalse(_withinReach(logs, spent, stranger), "within a stranger's reach");
    }

    /// SEASON0.md §2.2, Handles, and §2.3, rule 5: GARDEN_ZERO, which every pot and every reseal start from, is granted
    /// to Garden alone, and not to its deployer. Read from the ACL's events of a deployment: one grant, to the new
    /// contract, and nothing public.
    function testOnlyGardenHoldsItsZero() public {
        vm.recordLogs();
        Garden deployed = new Garden(_seasonZero());
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32[] memory granted = _assertGrantsOnlyTo(logs, address(deployed));
        assertEq(granted.length, 1, "one grant, of GARDEN_ZERO");
        _assertNothingPublic(logs);
        IAcl acl = IAcl(getCoprocessorConfig(address(garden)).ACLAddress);
        assertFalse(acl.isAllowed(granted[0], address(this)), "the deployer may use it");
        assertFalse(_withinReach(logs, granted[0], address(this)), "the deployer could make it");
    }

    /// RULES.md §4 and §9, and SEASON0.md §2.3, rule 5. Read from the ACL's events, a transfer grants the new level and
    /// MANA to the contract and the new owner, and the element to the new owner, who joins its previous owners on it.
    /// It credits no MANA, so no credit is granted. The account that made the transfer, approved by the owner, gets
    /// nothing, and nothing becomes publicly decryptable.
    function testTransferringGrantsTheNewValuesToTheNewOwnerOnly() public {
        (address operator, uint256 operatorKey) = makeAddrAndKey("operator");
        uint256 tokenId = _forge(alice);
        _wait(1 days);
        vm.prank(alice);
        garden.approve(operator, tokenId);

        vm.recordLogs();
        vm.prank(operator);
        garden.transferFrom(alice, bob, tokenId);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertNothingPublic(logs);

        Garden.CrystalView memory crystal = garden.crystalOf(tokenId);
        Grant[] memory grants = new Grant[](5);
        grants[0] = _grant(address(garden), crystal.level);
        grants[1] = _grant(bob, crystal.level);
        grants[2] = _grant(address(garden), crystal.mana);
        grants[3] = _grant(bob, crystal.mana);
        grants[4] = _grant(bob, crystal.element);
        _assertGrants(logs, grants);

        _assertCannotDecrypt(crystal.element, operator, operatorKey);
        _assertCannotDecrypt(crystal.level, operator, operatorKey);
        _assertCannotDecrypt(crystal.mana, operator, operatorKey);
    }

    /// Three Water crystals of the given owners, ranked first, second and third in season 1: they beat a Fire crystal
    /// of Alice's three times, twice and once.
    function _rankThree(address[3] memory owners) internal returns (uint256[3] memory top) {
        uint256 fire = _forgeElement(alice, FIRE);
        for (uint256 place; place < 3; place++) {
            top[place] = _forgeElement(owners[place], WATER);
            for (uint256 i; i < 3 - place; i++) {
                _publish(_duel(top[place], fire, MIN_STAKE));
            }
        }
        _assertTop(1, top[0], top[1], top[2], "three ranked");
    }

    /// A crystal of Alice's that has accrued a day of MANA is shattered into season 1's centre.
    function _fillThePot() internal {
        uint256 donor = _forge(alice);
        _wait(1 days);
        _shatter(alice, donor);
        assertEq(plaintextOf(garden.potOf(1)), MANA_PER_DAY, "the centre");
    }

    /// The handle of the one random value drawn in these logs, read from the executor's event.
    function _drawIn(Vm.Log[] memory logs) internal pure returns (bytes32 handle) {
        uint256 draws;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == FHE_RAND) {
                (,, handle) = abi.decode(logs[i].data, (uint8, bytes16, bytes32));
                draws++;
            }
        }
        assertEq(draws, 1, "one random value");
    }

    /// The stranger publishes the duel fought in the lobby: no persistent grant, nothing made public, and no handle of
    /// the duel's that the stranger may use, persistently or for the transaction.
    function _assertPublishingGrantsNothing(uint256 duelId, uint256 lobbyId, string memory label) internal {
        (bool creatorWon, bytes memory proof) = decryptPublicWithSignatures(garden.duelOf(duelId).creatorWins);
        vm.recordLogs();
        vm.prank(stranger);
        garden.publish(duelId, creatorWon, proof);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_grantsIn(logs).length, 0, string.concat(label, ": a grant"));
        _assertNothingPublic(logs);

        Garden.Duel memory duel = garden.duelOf(duelId);
        Garden.CrystalView memory a = garden.crystalOf(duel.creatorCrystal);
        Garden.CrystalView memory b = garden.crystalOf(duel.challengerCrystal);
        bytes32[9] memory handles = [
            euint8.unwrap(a.element),
            euint8.unwrap(a.level),
            euint64.unwrap(a.mana),
            euint8.unwrap(b.element),
            euint8.unwrap(b.level),
            euint64.unwrap(b.mana),
            ebool.unwrap(duel.creatorWins),
            ebool.unwrap(garden.lobbyOf(lobbyId).creatorPaid),
            euint64.unwrap(garden.potOf(duel.season))
        ];
        IAcl acl = IAcl(getCoprocessorConfig(address(garden)).ACLAddress);
        for (uint256 i; i < handles.length; i++) {
            if (handles[i] == 0) continue;
            assertFalse(acl.isAllowed(handles[i], stranger), string.concat(label, ": the publisher may use a handle"));
        }
    }

    /// A grant to the contract of a credited balance, as accrual keeps it: no longer stored, so checked by its value.
    function _assertCredit(Grant memory grant, uint64 credited) internal {
        assertEq(grant.account, address(garden), "the credit is the contract's");
        assertEq(plaintextOf(euint64.wrap(grant.handle)), credited, "the credited balance");
    }

    function _assertGrant(Grant memory grant, address account, bytes32 handle) internal pure {
        assertEq(grant.account, account, "grantee");
        assertEq(grant.handle, handle, "handle");
    }

    /// The logs up to and including the first ACL grant.
    function _firstGrant(Vm.Log[] memory logs) internal view returns (Vm.Log[] memory first) {
        address acl = getCoprocessorConfig(address(garden)).ACLAddress;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == acl && logs[i].topics.length > 0 && logs[i].topics[0] == ACL_ALLOWED) {
                first = new Vm.Log[](i + 1);
                for (uint256 j; j <= i; j++) {
                    first[j] = logs[j];
                }
                return first;
            }
        }
    }
}
