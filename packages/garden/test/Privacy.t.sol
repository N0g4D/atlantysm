// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FHE, ebool, euint8, euint64, externalEbool} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {Vm} from "forge-std/Vm.sol";
import {Garden} from "../src/Garden.sol";
import {GardenFixture} from "./utils/GardenFixture.sol";

/// The ACL lets an account allowed on a handle allow another one, and says who is allowed, for now or for good.
interface IAcl {
    function allow(bytes32 handle, address account) external;
    function isAllowed(bytes32 handle, address account) external view returns (bool);
    function isAllowedForDecryption(bytes32 handle) external view returns (bool);
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
