// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FHE, ebool, euint64} from "@fhevm/solidity/lib/FHE.sol";
import {TestFhevm} from "@fhevm/forge/TestFhevm.sol";
import {FhevmHCUMeter} from "@fhevm/forge/FhevmVm.sol";
import {LibKmsVerifier} from "@fhevm/forge/_host/shared/LibKmsVerifier.sol";
import {Vm} from "forge-std/Vm.sol";
import {DuelSpike} from "./DuelSpike.sol";

/// Two players and a stranger, and a duel set up in one call: Alice opens the lobby, Bob joins it.
abstract contract DuelFixture is TestFhevm {
    uint8 internal constant FIRE = 0;
    uint8 internal constant EARTH = 1;
    uint8 internal constant WATER = 2;

    uint64 internal constant STAKE = 40;
    /// A balance that covers the stake, and one that falls short of it by a single MANA.
    uint64 internal constant FUNDED = 100;
    uint64 internal constant SHORT = STAKE - 1;

    struct Side {
        uint8 element;
        uint8 level;
        uint64 mana;
    }

    DuelSpike internal spike;
    address internal alice;
    uint256 internal aliceKey;
    address internal bob;
    uint256 internal bobKey;
    address internal carol;
    uint256 internal carolKey;

    function setUp() public virtual override {
        super.setUp();
        spike = new DuelSpike();
        (alice, aliceKey) = makeAddrAndKey("alice");
        (bob, bobKey) = makeAddrAndKey("bob");
        (carol, carolKey) = makeAddrAndKey("carol");
    }

    function _side(uint8 element, uint8 level, uint64 mana) internal pure returns (Side memory) {
        return Side({element: element, level: level, mana: mana});
    }

    function _openLobby(Side memory side) internal returns (uint256 lobbyId, uint256 crystal) {
        crystal = spike.mint(alice, side.element, side.level, side.mana);
        vm.prank(alice);
        lobbyId = spike.openLobby(crystal, STAKE);
    }

    function _duel(Side memory a, Side memory b) internal returns (uint256 duelId, uint256 crystalA, uint256 crystalB) {
        uint256 lobbyId;
        (lobbyId, crystalA) = _openLobby(a);
        crystalB = spike.mint(bob, b.element, b.level, b.mana);
        vm.prank(bob);
        duelId = spike.joinLobby(lobbyId, crystalB);
    }
}

/// RULES.md §7 and SEASON0.md §2.2: who wins, what moves, what is revealed, and what a proof must be.
contract DuelSpikeTest is DuelFixture {
    /// The executor's event for a random value: the coprocessor draws it from this, and a test reads it back.
    bytes32 internal constant FHE_RAND = keccak256("FheRand(address,uint8,bytes16,bytes32)");
    /// The ACL's events for a persistent grant, and for handles made publicly decryptable.
    bytes32 internal constant ACL_ALLOWED = keccak256("Allowed(address,address,bytes32)");
    bytes32 internal constant ACL_PUBLIC = keccak256("AllowedForDecryption(address,bytes32[])");

    /// A persistent ACL grant: `account` may use `handle`, and decrypt it if it is a user.
    struct Grant {
        address account;
        bytes32 handle;
    }

    function setUp() public override {
        super.setUp();
        // These tests fight many duels in one forge test, which is one transaction, so the per-transaction cap
        // would bind on the scaffolding. DuelSpikeHcuTest measures a single join against the real caps.
        disableHCULimits();
    }

    // -- Who wins -------------------------------------------------------------------------------------------

    /// RULES.md §7: all nine pairs, each with the creator's crystal at the higher level and then at the lower.
    /// Between different elements the level never matters; in a mirror it decides.
    function testEveryElementPair() public {
        for (uint8 ea; ea < 3; ea++) {
            for (uint8 eb; eb < 3; eb++) {
                for (uint256 round; round < 2; round++) {
                    (uint8 la, uint8 lb) = round == 0 ? (uint8(7), uint8(2)) : (uint8(2), uint8(7));
                    bool creatorWins = ea == eb ? la > lb : _beats(ea, eb);
                    _assertDuel(
                        _side(ea, la, FUNDED),
                        _side(eb, lb, FUNDED),
                        creatorWins,
                        creatorWins ? FUNDED + STAKE : FUNDED - STAKE,
                        creatorWins ? FUNDED - STAKE : FUNDED + STAKE,
                        string.concat(_name(ea), " ", vm.toString(la), " against ", _name(eb), " ", vm.toString(lb))
                    );
                }
            }
        }
    }

    /// RULES.md §7, Mirrors: the higher level wins, whichever side holds it.
    function testAMirrorGoesToTheHigherLevel() public {
        for (uint8 e; e < 3; e++) {
            _assertDuel(_side(e, 4, FUNDED), _side(e, 3, FUNDED), true, FUNDED + STAKE, FUNDED - STAKE, _name(e));
            _assertDuel(_side(e, 1, FUNDED), _side(e, 10, FUNDED), false, FUNDED - STAKE, FUNDED + STAKE, _name(e));
        }
    }

    /// RULES.md §7, Mirrors: element and level equal, an encrypted coin decides. Every outcome must be the coin
    /// that join drew, and the coin must land both ways.
    function testAMirrorOfEqualLevelsFollowsTheCoin() public {
        bool creatorWon;
        bool challengerWon;
        // A fair coin lands both ways within a few throws; the bound only stops a stuck coin from looping forever.
        for (uint8 i; i < 32 && !(creatorWon && challengerWon); i++) {
            uint8 e = i % 3;
            vm.recordLogs();
            (uint256 duelId,,) = _duel(_side(e, 5, FUNDED), _side(e, 5, FUNDED));
            bool coin = _coinOf(vm.getRecordedLogs());

            bool creatorWins = decryptPublic(spike.creatorWinsOf(duelId));
            assertEq(creatorWins, coin, "the winner is the coin");
            if (creatorWins) creatorWon = true;
            else challengerWon = true;
        }
        assertTrue(creatorWon && challengerWon, "the coin lands both ways");
    }

    // -- What moves -----------------------------------------------------------------------------------------

    /// RULES.md §7, Stakes and forfeits: a creator who cannot cover the stake loses, even with the element that
    /// wins, and the challenger takes back only its own stake.
    function testACreatorWhoCannotPayForfeits() public {
        _assertDuel(_side(WATER, 9, SHORT), _side(FIRE, 1, FUNDED), false, SHORT, FUNDED, "creator short");
    }

    function testAChallengerWhoCannotPayForfeits() public {
        _assertDuel(_side(FIRE, 1, FUNDED), _side(WATER, 9, SHORT), true, FUNDED, SHORT, "challenger short");
    }

    /// RULES.md §7: if neither crystal can cover the stake, the duel is decided as usual and no MANA moves.
    function testWhenNeitherCanPayNoManaMoves() public {
        _assertDuel(_side(WATER, 1, SHORT), _side(FIRE, 9, SHORT), true, SHORT, SHORT, "creator wins");
        _assertDuel(_side(FIRE, 9, SHORT), _side(WATER, 1, SHORT), false, SHORT, SHORT, "challenger wins");
    }

    /// The boundary of both stake checks: a balance equal to the stake covers it.
    function testABalanceEqualToTheStakePays() public {
        _assertDuel(_side(WATER, 1, STAKE), _side(FIRE, 1, FUNDED), true, 2 * STAKE, FUNDED - STAKE, "creator");
        _assertDuel(_side(FIRE, 1, FUNDED), _side(WATER, 1, STAKE), false, FUNDED - STAKE, 2 * STAKE, "challenger");
    }

    /// SEASON0.md §2.2: Join accrues both crystals before the stake is checked, so MANA earned while the lobby
    /// waited counts, and a remainder shorter than one MANA waits for the next call.
    function testJoiningAccruesBothCrystalsFirst() public {
        (uint256 lobbyId, uint256 a) = _openLobby(_side(FIRE, 1, FUNDED));
        uint256 b = spike.mint(bob, WATER, 1, 0);
        uint64 secondsPerMana = spike.SECONDS_PER_MANA();
        vm.warp(block.timestamp + STAKE * secondsPerMana + secondsPerMana - 1);

        vm.prank(bob);
        uint256 duelId = spike.joinLobby(lobbyId, b);

        // Water beats Fire, and the challenger, empty when minted, has just earned the stake: it takes both.
        assertFalse(decryptPublic(spike.creatorWinsOf(duelId)));
        assertEq(decrypt(spike.manaOf(b), address(spike), bobKey), 2 * STAKE);
        // The creator paid the stake when opening, and earned as much while waiting.
        assertEq(decrypt(spike.manaOf(a), address(spike), aliceKey), FUNDED - STAKE + STAKE);

        // The remainder was kept: one more second completes a MANA. Opening a lobby the crystal cannot cover
        // accrues it and moves nothing else.
        vm.warp(block.timestamp + 1);
        vm.prank(bob);
        spike.openLobby(b, 1_000);
        assertEq(decrypt(spike.manaOf(b), address(spike), bobKey), 2 * STAKE + 1);
    }

    /// SEASON0.md §2.2: joining closes the lobby and frees the creator's crystal.
    function testJoiningClosesTheLobby() public {
        (uint256 lobbyId, uint256 a) = _openLobby(_side(FIRE, 1, FUNDED));
        assertEq(spike.lobbyOf(a), lobbyId);
        uint256 b = spike.mint(bob, WATER, 1, FUNDED);
        vm.prank(bob);
        spike.joinLobby(lobbyId, b);

        assertEq(spike.lobbyOf(a), 0);
        uint256 late = spike.mint(carol, EARTH, 1, FUNDED);
        vm.expectRevert(DuelSpike.LobbyNotOpen.selector);
        vm.prank(carol);
        spike.joinLobby(lobbyId, late);
    }

    // -- What is revealed -----------------------------------------------------------------------------------

    /// RULES.md §3, invariant 3, and §9: a duel publishes who won and nothing else. Read from the ACL's events,
    /// opening and joining grant each new balance to the contract and its owner, `creatorPaid` and the outcome to
    /// the contract alone, and only the outcome to the public. Each player then reads only its own balance; the
    /// opponent, a stranger and the public read neither.
    function testOnlyTheOutcomeIsPublic() public {
        uint256 a = spike.mint(alice, FIRE, 3, FUNDED);
        uint256 b = spike.mint(bob, EARTH, 8, FUNDED);

        vm.recordLogs();
        vm.prank(alice);
        uint256 lobbyId = spike.openLobby(a, STAKE);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Grant[] memory grants = new Grant[](3);
        grants[0] = Grant(address(spike), euint64.unwrap(spike.manaOf(a)));
        grants[1] = Grant(alice, euint64.unwrap(spike.manaOf(a)));
        grants[2] = Grant(address(spike), ebool.unwrap(spike.creatorPaidOf(lobbyId)));
        _assertGrants(logs, grants);
        _assertPublic(logs, new bytes32[](0));

        vm.prank(bob);
        uint256 duelId = spike.joinLobby(lobbyId, b);
        logs = vm.getRecordedLogs();
        grants = new Grant[](5);
        grants[0] = Grant(address(spike), euint64.unwrap(spike.manaOf(a)));
        grants[1] = Grant(alice, euint64.unwrap(spike.manaOf(a)));
        grants[2] = Grant(address(spike), euint64.unwrap(spike.manaOf(b)));
        grants[3] = Grant(bob, euint64.unwrap(spike.manaOf(b)));
        grants[4] = Grant(address(spike), ebool.unwrap(spike.creatorWinsOf(duelId)));
        _assertGrants(logs, grants);
        bytes32[] memory revealed = new bytes32[](1);
        revealed[0] = ebool.unwrap(spike.creatorWinsOf(duelId));
        _assertPublic(logs, revealed);

        assertTrue(decryptPublic(spike.creatorWinsOf(duelId)));
        assertEq(decrypt(spike.manaOf(a), address(spike), aliceKey), FUNDED + STAKE);
        assertEq(decrypt(spike.manaOf(b), address(spike), bobKey), FUNDED - STAKE);

        _assertCannotDecrypt(spike.manaOf(a), bob, bobKey);
        _assertCannotDecrypt(spike.manaOf(a), carol, carolKey);
        _assertCannotDecrypt(spike.manaOf(b), alice, aliceKey);
        _assertCannotDecrypt(spike.manaOf(b), carol, carolKey);
        _assertNotPublic(spike.manaOf(a));
        _assertNotPublic(spike.manaOf(b));
    }

    // -- Publishing -----------------------------------------------------------------------------------------

    /// RULES.md §7, Resolution: anyone can submit the published result, and it counts in both records.
    function testAnyoneCanPublishTheOutcome() public {
        (uint256 duelId, uint256 a, uint256 b) = _duel(_side(EARTH, 2, FUNDED), _side(WATER, 9, FUNDED));
        (bool creatorWon, bytes memory proof) = decryptPublicWithSignatures(spike.creatorWinsOf(duelId));
        assertTrue(creatorWon);

        vm.expectEmit(address(spike));
        emit DuelSpike.DuelPublished(duelId, a, b);
        vm.prank(carol);
        spike.publish(duelId, creatorWon, proof);

        assertTrue(spike.isPublished(duelId));
        _assertRecord(a, 1, 0);
        _assertRecord(b, 0, 1);
    }

    /// A forged outcome: the loser presents the genuine proof and claims the other result.
    function testPublishRejectsAFlippedOutcome() public {
        (uint256 duelId, uint256 a, uint256 b) = _duel(_side(WATER, 1, FUNDED), _side(FIRE, 1, FUNDED));
        (bool creatorWon, bytes memory proof) = decryptPublicWithSignatures(spike.creatorWinsOf(duelId));

        // The signatures were made over the true result, so over the false one they recover to strangers.
        vm.expectPartialRevert(FHE.KMSInvalidSigner.selector);
        vm.prank(bob);
        spike.publish(duelId, !creatorWon, proof);

        assertFalse(spike.isPublished(duelId));
        _assertRecord(a, 0, 0);
        _assertRecord(b, 0, 0);

        // The same proof with the true result is accepted: the rejection was the claim's, not a broken proof's.
        spike.publish(duelId, creatorWon, proof);
        _assertRecord(a, 1, 0);
        _assertRecord(b, 0, 1);
    }

    /// A forged proof: well formed, over the false result, signed by as many keys as the KMS has signers, none of
    /// them the KMS's.
    function testPublishRejectsAProofTheKmsDidNotSign() public {
        (uint256 duelId,,) = _duel(_side(WATER, 1, FUNDED), _side(FIRE, 1, FUNDED));
        bytes32[] memory handles = new bytes32[](1);
        handles[0] = ebool.unwrap(spike.creatorWinsOf(duelId));
        (bytes32 digest, address[] memory kmsSigners,, bytes memory extraData) = LibKmsVerifier.publicDecryptProofDigest(
            getCoprocessorConfig(address(spike)).KMSVerifierAddress, handles, abi.encode(false)
        );

        bytes memory signatures;
        address firstForger;
        for (uint256 i; i < kmsSigners.length; i++) {
            (address forger, uint256 key) = makeAddrAndKey(string.concat("forger", vm.toString(i)));
            if (i == 0) firstForger = forger;
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
            signatures = abi.encodePacked(signatures, r, s, v);
        }
        bytes memory proof = abi.encodePacked(uint8(kmsSigners.length), signatures, extraData);

        vm.expectRevert(abi.encodeWithSelector(FHE.KMSInvalidSigner.selector, firstForger));
        vm.prank(bob);
        spike.publish(duelId, false, proof);
    }

    /// A replayed proof: genuine, but made for another duel. It would credit this duel's loser.
    function testPublishRejectsAProofFromAnotherDuel() public {
        (uint256 first,,) = _duel(_side(WATER, 1, FUNDED), _side(FIRE, 1, FUNDED));
        (uint256 second,,) = _duel(_side(FIRE, 1, FUNDED), _side(WATER, 1, FUNDED));
        (bool firstCreatorWon, bytes memory firstProof) = decryptPublicWithSignatures(spike.creatorWinsOf(first));
        assertTrue(firstCreatorWon);
        assertFalse(decryptPublic(spike.creatorWinsOf(second)));

        vm.expectPartialRevert(FHE.KMSInvalidSigner.selector);
        vm.prank(alice);
        spike.publish(second, firstCreatorWon, firstProof);
        assertFalse(spike.isPublished(second));

        // Each proof works for its own duel: the rejection was the replay's, not a broken proof's.
        spike.publish(first, firstCreatorWon, firstProof);
        assertTrue(spike.isPublished(first));
        (bool secondCreatorWon, bytes memory secondProof) = decryptPublicWithSignatures(spike.creatorWinsOf(second));
        spike.publish(second, secondCreatorWon, secondProof);
        assertTrue(spike.isPublished(second));
    }

    /// A replayed proof: the same duel published twice would count its result twice.
    function testPublishRejectsASecondPublish() public {
        (uint256 duelId, uint256 a, uint256 b) = _duel(_side(EARTH, 1, FUNDED), _side(WATER, 1, FUNDED));
        (bool creatorWon, bytes memory proof) = decryptPublicWithSignatures(spike.creatorWinsOf(duelId));
        spike.publish(duelId, creatorWon, proof);

        vm.expectRevert(DuelSpike.AlreadyPublished.selector);
        spike.publish(duelId, creatorWon, proof);
        _assertRecord(a, 1, 0);
        _assertRecord(b, 0, 1);
    }

    // -- Helpers --------------------------------------------------------------------------------------------

    /// External, because `vm.expectRevert` only catches a revert that ends an external call.
    function decryptAs(euint64 value, uint256 userKey) external returns (uint64) {
        return decrypt(value, address(spike), userKey);
    }

    function decryptPubliclyExternal(euint64 value) external returns (uint64) {
        return decryptPublic(value);
    }

    function _assertDuel(
        Side memory a,
        Side memory b,
        bool creatorWins,
        uint64 manaA,
        uint64 manaB,
        string memory label
    ) internal {
        (uint256 duelId, uint256 crystalA, uint256 crystalB) = _duel(a, b);
        assertEq(decryptPublic(spike.creatorWinsOf(duelId)), creatorWins, string.concat(label, ": winner"));
        assertEq(
            decrypt(spike.manaOf(crystalA), address(spike), aliceKey), manaA, string.concat(label, ": creator's MANA")
        );
        assertEq(
            decrypt(spike.manaOf(crystalB), address(spike), bobKey), manaB, string.concat(label, ": challenger's MANA")
        );
    }

    function _assertRecord(uint256 crystal, uint32 wins, uint32 losses) internal view {
        (uint32 actualWins, uint32 actualLosses) = spike.recordOf(crystal);
        assertEq(actualWins, wins, "wins");
        assertEq(actualLosses, losses, "losses");
    }

    function _assertCannotDecrypt(euint64 value, address user, uint256 userKey) internal {
        // Named, so the check cannot pass on an unrelated failure such as a malformed permit.
        vm.expectRevert(
            abi.encodeWithSignature(
                "CleartextErrorUserNotAuthorizedForDecrypt(bytes32,address)", euint64.unwrap(value), user
            )
        );
        this.decryptAs(value, userKey);
    }

    /// Exactly these persistent grants, in any order, read from the ACL's `Allowed` events.
    function _assertGrants(Vm.Log[] memory logs, Grant[] memory expected) internal view {
        address acl = getCoprocessorConfig(address(spike)).ACLAddress;
        bool[] memory matched = new bool[](expected.length);
        uint256 grants;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != acl || logs[i].topics.length == 0 || logs[i].topics[0] != ACL_ALLOWED) continue;
            grants++;
            address account = address(uint160(uint256(logs[i].topics[2])));
            bytes32 handle = abi.decode(logs[i].data, (bytes32));
            bool found;
            for (uint256 j; j < expected.length && !found; j++) {
                if (!matched[j] && expected[j].account == account && expected[j].handle == handle) {
                    matched[j] = found = true;
                }
            }
            assertTrue(found, string.concat("unexpected grant to ", vm.toString(account)));
        }
        assertEq(grants, expected.length, "number of grants");
    }

    /// Exactly these handles made publicly decryptable, read from the ACL's `AllowedForDecryption` events.
    function _assertPublic(Vm.Log[] memory logs, bytes32[] memory expected) internal view {
        address acl = getCoprocessorConfig(address(spike)).ACLAddress;
        bytes32[] memory revealed = new bytes32[](0);
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != acl || logs[i].topics.length == 0 || logs[i].topics[0] != ACL_PUBLIC) continue;
            bytes32[] memory batch = abi.decode(logs[i].data, (bytes32[]));
            bytes32[] memory joined = new bytes32[](revealed.length + batch.length);
            for (uint256 j; j < revealed.length; j++) {
                joined[j] = revealed[j];
            }
            for (uint256 j; j < batch.length; j++) {
                joined[revealed.length + j] = batch[j];
            }
            revealed = joined;
        }
        assertEq(revealed, expected, "publicly decryptable");
    }

    function _assertNotPublic(euint64 value) internal {
        vm.expectRevert(
            abi.encodeWithSignature("CleartextErrorHandleNotAllowedForPublicDecryption(bytes32)", euint64.unwrap(value))
        );
        this.decryptPubliclyExternal(value);
    }

    /// The one random value a join draws, read from the executor's event as the coprocessor reads it.
    function _coinOf(Vm.Log[] memory logs) internal returns (bool) {
        bytes32 handle;
        uint256 draws;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == FHE_RAND) {
                (,, handle) = abi.decode(logs[i].data, (uint8, bytes16, bytes32));
                draws++;
            }
        }
        assertEq(draws, 1, "one random value per join");
        return plaintextOf(ebool.wrap(handle));
    }

    /// RULES.md §7, as written there, rather than the contract's arithmetic: Water beats Fire, Fire beats Earth,
    /// Earth beats Water.
    function _beats(uint8 x, uint8 y) internal pure returns (bool) {
        return (x == WATER && y == FIRE) || (x == FIRE && y == EARTH) || (x == EARTH && y == WATER);
    }

    function _name(uint8 element) internal pure returns (string memory) {
        return element == FIRE ? "Fire" : element == EARTH ? "Earth" : "Water";
    }
}

/// SEASON0.md §2.3, rule 7: what joining costs, against the real caps. And §5: neither its cost nor its logs tell
/// a forfeit from a defeat.
contract DuelSpikeHcuTest is DuelFixture {
    uint256 internal constant HCU_PER_TX_BUDGET = 20_000_000 / 2;
    uint256 internal constant HCU_DEPTH_BUDGET = 5_000_000 / 2;
    /// What a crystal accrues over the hour setUp lets pass: 3,600 / 864 seconds, the remainder waiting.
    uint64 internal constant ACCRUED = 4;

    uint256 internal fundedLobby;
    uint256 internal fundedCreator;
    uint256 internal forfeitLobby;
    uint256 internal forfeitCreator;
    uint256 internal fundedChallenger;
    uint256 internal emptyChallenger;
    uint256 internal idleCrystal;

    /**
     * @dev Everything a measured call reads is made here. A forge test is one transaction, and the depth cap
     *      follows chains of dependent operations within a transaction, so a lobby opened in the test itself
     *      would add its own chain to the join's. Made in setUp, which is a transaction of its own, the handles
     *      come from an earlier transaction, as they will on chain. It also proves that the join can use them:
     *      the transient grants of the transaction that made them are gone.
     */
    function setUp() public override {
        super.setUp();
        // Both challengers lose to Water: one by defeat, one by forfeit.
        (fundedLobby, fundedCreator) = _openLobby(_side(WATER, 3, FUNDED));
        (forfeitLobby, forfeitCreator) = _openLobby(_side(WATER, 3, FUNDED));
        fundedChallenger = spike.mint(bob, FIRE, 3, FUNDED);
        emptyChallenger = spike.mint(bob, FIRE, 3, 0);
        idleCrystal = spike.mint(alice, EARTH, 1, FUNDED);
        // An hour later, every crystal accrues when it acts, so that the measured calls credit real MANA. Not much
        // longer: the empty challenger must still fall short of the stake.
        vm.warp(block.timestamp + 1 hours);
    }

    function testJoiningStaysUnderHalfOfEachCap() public {
        FhevmHCUMeter memory hcu = _join(fundedLobby, fundedChallenger);
        emit log_named_uint("joinLobby: HCU per transaction", hcu.transaction);
        emit log_named_uint("joinLobby: HCU depth", hcu.maxHandle);
        assertLt(hcu.transaction, HCU_PER_TX_BUDGET);
        assertLt(hcu.maxHandle, HCU_DEPTH_BUDGET);
    }

    /// The same operations run whatever the secrets are, so a forfeit costs what a defeat costs, and its logs differ
    /// only in the handles and ids they carry: same emitters, same events, same indexed accounts.
    function testAForfeitLooksLikeADefeat() public {
        vm.recordLogs();
        FhevmHCUMeter memory defeat = _join(fundedLobby, fundedChallenger);
        Vm.Log[] memory defeatLogs = vm.getRecordedLogs();
        FhevmHCUMeter memory forfeit = _join(forfeitLobby, emptyChallenger);
        Vm.Log[] memory forfeitLogs = vm.getRecordedLogs();

        // The two cases are what they claim. The defeated challenger paid the stake and lost it, and the creator
        // took both stakes. The empty one could not pay, and the creator took back only its own.
        assertEq(plaintextOf(spike.manaOf(fundedChallenger)), FUNDED + ACCRUED - STAKE);
        assertEq(plaintextOf(spike.manaOf(fundedCreator)), FUNDED - STAKE + ACCRUED + 2 * STAKE);
        assertEq(plaintextOf(spike.manaOf(emptyChallenger)), ACCRUED);
        assertEq(plaintextOf(spike.manaOf(forfeitCreator)), FUNDED - STAKE + ACCRUED + STAKE);

        assertEq(forfeit.transaction, defeat.transaction, "HCU per transaction");
        assertEq(forfeit.maxHandle, defeat.maxHandle, "HCU depth");
        assertEq(forfeitLogs.length, defeatLogs.length, "number of logs");
        for (uint256 i; i < defeatLogs.length; i++) {
            assertEq(forfeitLogs[i].emitter, defeatLogs[i].emitter, "emitter");
            assertEq(forfeitLogs[i].topics, defeatLogs[i].topics, "topics");
        }
    }

    function testOpeningALobbyStaysUnderHalfOfEachCap() public {
        resetHCU();
        vm.prank(alice);
        spike.openLobby(idleCrystal, STAKE);
        FhevmHCUMeter memory hcu = lastHCU();
        emit log_named_uint("openLobby: HCU per transaction", hcu.transaction);
        emit log_named_uint("openLobby: HCU depth", hcu.maxHandle);
        assertLt(hcu.transaction, HCU_PER_TX_BUDGET);
        assertLt(hcu.maxHandle, HCU_DEPTH_BUDGET);
    }

    function _join(uint256 lobbyId, uint256 crystal) internal returns (FhevmHCUMeter memory) {
        // The readings accumulate over a forge test: start this call from zero. The reset comes before the
        // prank, which only covers the next call.
        resetHCU();
        vm.prank(bob);
        spike.joinLobby(lobbyId, crystal);
        return lastHCU();
    }
}
