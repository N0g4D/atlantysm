// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FHE, ebool} from "@fhevm/solidity/lib/FHE.sol";
import {FhevmHCUMeter} from "@fhevm/forge/FhevmVm.sol";
import {LibKmsVerifier} from "@fhevm/forge/_host/shared/LibKmsVerifier.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Vm} from "forge-std/Vm.sol";
import {Garden} from "../src/Garden.sol";
import {GardenFixture} from "./utils/GardenFixture.sol";

/// RULES.md §7, the Arena: lobbies, duels, stakes, and publishing the outcome.
contract ArenaTest is GardenFixture {
    uint64 internal constant STAKE = 40;
    /// A day of MANA, which covers the stake, and a balance that falls short of it by one MANA.
    uint64 internal constant FUNDED = 100;
    uint64 internal constant SHORT = STAKE - 1;

    /// What an outsider can observe of one call, every handle masked (GardenFixture._masked).
    struct Trace {
        Vm.Log[] logs;
        /// Garden's storage slots written, in order, and the values they hold afterwards.
        bytes32[] writes;
        bytes32[] values;
        /// Everything Garden's views show afterwards but handles: every crystal, lobby and duel, and the counters.
        bytes state;
        /// What the call cost, as its receipt would show.
        uint256 gas;
        FhevmHCUMeter hcu;
    }

    function setUp() public override {
        super.setUp();
        // A test forges, attunes and fights many times in one forge test, which is one transaction, so the HCU caps
        // would bind on the scaffolding. On chain each call is a transaction of its own, which Hcu.t.sol measures
        // against the real caps.
        disableHCULimits();
    }

    // -- Who wins -------------------------------------------------------------------------------------------

    /// RULES.md §7, the triangle and mirrors: all nine pairs of elements, each with the creator's crystal a level above
    /// the challenger's and then a level below. Between different elements the triangle decides and the level never
    /// matters. In a mirror the higher level wins. The winner takes the loser's stake.
    function testEveryPairOfElements() public {
        // For each player, a crystal of each element at level 1 and one at level 2.
        uint256[2][3] memory aliceCrystals;
        uint256[2][3] memory bobCrystals;
        for (uint8 e; e < 3; e++) {
            for (uint256 l; l < 2; l++) {
                aliceCrystals[e][l] = _forgeElement(alice, e);
                bobCrystals[e][l] = _forgeElement(bob, e);
            }
        }
        _wait(10 days);
        for (uint8 e; e < 3; e++) {
            _attune(alice, aliceCrystals[e][1], true);
            _attune(bob, bobCrystals[e][1], true);
        }

        for (uint8 ea; ea < 3; ea++) {
            for (uint8 eb; eb < 3; eb++) {
                for (uint256 round; round < 2; round++) {
                    (uint256 la, uint256 lb) = round == 0 ? (uint256(2), uint256(1)) : (uint256(1), uint256(2));
                    bool creatorWins = ea == eb ? la > lb : _beats(ea, eb);
                    string memory label =
                        string.concat(_name(ea), " ", vm.toString(la), " against ", _name(eb), " ", vm.toString(lb));
                    _assertFundedDuel(aliceCrystals[ea][la - 1], bobCrystals[eb][lb - 1], creatorWins, label);
                }
            }
        }
    }

    /// RULES.md §7, Mirrors: when element and level are both equal, an encrypted coin decides. Every outcome is the
    /// coin that the join drew, and the coin lands both ways.
    function testAMirrorOfEqualLevelsFollowsTheCoin() public {
        uint256[3] memory aliceCrystals;
        uint256[3] memory bobCrystals;
        for (uint8 e; e < 3; e++) {
            aliceCrystals[e] = _forgeElement(alice, e);
            bobCrystals[e] = _forgeElement(bob, e);
        }
        // Enough MANA that neither side runs short of the stake, however the coins fall.
        _wait(30 days);

        bool creatorWon;
        bool challengerWon;
        // A fair coin lands both ways within a few throws. The bound only stops a stuck coin from looping forever.
        for (uint256 i; i < 32 && !(creatorWon && challengerWon); i++) {
            vm.recordLogs();
            uint256 duelId = _duel(aliceCrystals[i % 3], bobCrystals[i % 3], STAKE);
            bool coin = _coinOf(vm.getRecordedLogs());

            bool creatorWins = decryptPublic(garden.duelOf(duelId).creatorWins);
            assertEq(creatorWins, coin, "the winner is the coin");
            if (creatorWins) creatorWon = true;
            else challengerWon = true;
        }
        assertTrue(creatorWon && challengerWon, "the coin lands both ways");
    }

    // -- Lobbies --------------------------------------------------------------------------------------------

    /// RULES.md §7, Lobbies: a player opens a lobby with one crystal and a public stake, which the crystal puts up at
    /// once from its balance. The crystal waits in the lobby, which challengers find among the open ones.
    function testOpeningALobbyPutsUpTheStake() public {
        uint256 tokenId = _forge(alice);
        _wait(1 days);

        // Called directly, not through a helper that reads the owner first: the expected event must come from the
        // next call.
        vm.expectEmit(address(garden));
        emit Garden.LobbyOpened(1, tokenId, STAKE);
        vm.prank(alice);
        uint256 lobbyId = garden.openLobby(tokenId, STAKE);

        assertEq(lobbyId, 1);
        assertEq(garden.lastLobbyId(), 1);
        Garden.Lobby memory lobby = garden.lobbyOf(lobbyId);
        assertEq(lobby.crystal, tokenId, "crystal");
        assertEq(lobby.stake, STAKE, "stake");
        assertEq(lobby.openedAt, block.timestamp, "opened at");
        assertEq(uint8(lobby.status), uint8(Garden.LobbyStatus.Open), "open");
        assertEq(garden.crystalOf(tokenId).openLobby, lobbyId, "the crystal waits in it");
        assertEq(_balanceOf(tokenId, aliceKey), FUNDED - STAKE, "the stake is put up");
        _assertOpenLobbies(_ids(lobbyId));
    }

    /// RULES.md §7 and §12: a stake is from 10 to 100 MANA, both included.
    function testTheStakeIsFromTenToAHundred() public {
        uint256 first = _forge(alice);
        uint256 second = _forge(alice);
        _wait(1 days);

        uint64[4] memory refused = [uint64(0), MIN_STAKE - 1, MAX_STAKE + 1, type(uint64).max];
        for (uint256 i; i < refused.length; i++) {
            vm.expectRevert(Garden.StakeOutOfBounds.selector);
            vm.prank(alice);
            garden.openLobby(first, refused[i]);
        }
        assertEq(garden.lastLobbyId(), 0, "no lobby");
        assertEq(garden.crystalOf(first).openLobby, 0, "not waiting");

        assertEq(garden.lobbyOf(_openLobby(first, MIN_STAKE)).stake, MIN_STAKE);
        assertEq(garden.lobbyOf(_openLobby(second, MAX_STAKE)).stake, MAX_STAKE);
    }

    /// RULES.md §7: a player opens a lobby with a crystal of its own, not with someone else's, even one it may
    /// transfer. A crystal that does not exist cannot open one.
    function testOnlyTheOwnerCanOpenALobby() public {
        uint256 tokenId = _forge(alice);
        _wait(1 days);

        vm.expectRevert(Garden.NotOwner.selector);
        vm.prank(bob);
        garden.openLobby(tokenId, STAKE);
        vm.prank(alice);
        garden.approve(bob, tokenId);
        vm.expectRevert(Garden.NotOwner.selector);
        vm.prank(bob);
        garden.openLobby(tokenId, STAKE);

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, tokenId + 1));
        vm.prank(alice);
        garden.openLobby(tokenId + 1, STAKE);
        assertEq(garden.lastLobbyId(), 0);
    }

    /// RULES.md §7: a crystal waits in one open lobby at a time. While it waits, it can neither open another lobby nor
    /// join one, its own included.
    function testACrystalWaitsInOneLobbyAtATime() public {
        uint256 a = _forge(alice);
        uint256 b = _forge(bob);
        _wait(1 days);
        uint256 aliceLobby = _openLobby(a, STAKE);
        uint256 bobLobby = _openLobby(b, STAKE);

        vm.startPrank(alice);
        vm.expectRevert(Garden.CrystalWaiting.selector);
        garden.openLobby(a, STAKE);
        vm.expectRevert(Garden.CrystalWaiting.selector);
        garden.joinLobby(bobLobby, a);
        vm.expectRevert(Garden.CrystalWaiting.selector);
        garden.joinLobby(aliceLobby, a);
        vm.stopPrank();
        vm.expectRevert(Garden.CrystalWaiting.selector);
        vm.prank(bob);
        garden.joinLobby(aliceLobby, b);

        _assertOpenLobbies(_ids(aliceLobby, bobLobby));
    }

    /// RULES.md §4 and SEASON0.md §5: a crystal waiting in an open lobby cannot be shattered or transferred, by its
    /// owner or by an account the owner approved. Once its lobby is joined or cancelled, it can be shattered again.
    /// It can still attune: RULES.md §4 locks only transfers and shattering, and the stake was put up already.
    function testAWaitingCrystalCannotBeShatteredOrTransferred() public {
        uint256 a = _forge(alice);
        uint256 b = _forge(bob);
        uint256 c = _forge(alice);
        _wait(1 days);
        uint256 lobbyId = _openLobby(a, STAKE);

        vm.startPrank(alice);
        vm.expectRevert(Garden.CrystalWaiting.selector);
        garden.shatter(a);
        vm.expectRevert(Garden.CrystalWaiting.selector);
        garden.transferFrom(alice, bob, a);
        vm.expectRevert(Garden.CrystalWaiting.selector);
        garden.safeTransferFrom(alice, bob, a);
        garden.approve(bob, a);
        vm.stopPrank();
        vm.expectRevert(Garden.CrystalWaiting.selector);
        vm.prank(bob);
        garden.transferFrom(alice, bob, a);
        assertEq(garden.ownerOf(a), alice);

        _attune(alice, a, true);
        assertEq(decrypt(garden.crystalOf(a).level, address(garden), aliceKey), 2, "a waiting crystal attunes");

        _join(lobbyId, b);
        _shatter(alice, a);

        lobbyId = _openLobby(c, STAKE);
        _wait(LOBBY_TIMEOUT);
        _cancel(lobbyId);
        _shatter(alice, c);
        assertEq(garden.totalSupply(), 1, "only Bob's crystal is left");
    }

    /// RULES.md §7: anyone can join a lobby with a crystal of their own, but not with someone else's, even one they
    /// may transfer. The creator can join with another crystal of its own: RULES.md §8 accepts that weakness in
    /// Season 0.
    function testAnyoneCanJoinWithACrystalOfTheirOwn() public {
        uint256 a = _forge(alice);
        uint256 other = _forge(alice);
        _wait(1 days);
        uint256 lobbyId = _openLobby(a, STAKE);

        vm.expectRevert(Garden.NotOwner.selector);
        vm.prank(bob);
        garden.joinLobby(lobbyId, other);
        vm.prank(alice);
        garden.approve(bob, other);
        vm.expectRevert(Garden.NotOwner.selector);
        vm.prank(bob);
        garden.joinLobby(lobbyId, other);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, other + 1));
        vm.prank(bob);
        garden.joinLobby(lobbyId, other + 1);

        uint256 duelId = _join(lobbyId, other);
        Garden.Duel memory duel = garden.duelOf(duelId);
        assertEq(duel.creatorCrystal, a, "creator");
        assertEq(duel.challengerCrystal, other, "challenger");
    }

    /// SEASON0.md §2.2, Join: joining closes the lobby and frees the creator's crystal, which can open another lobby.
    /// Nobody else can join the closed lobby, and its creator cannot cancel it.
    function testJoiningClosesTheLobby() public {
        uint256 a = _forge(alice);
        uint256 b = _forge(bob);
        uint256 late = _forge(bob);
        _wait(1 days);
        uint256 lobbyId = _openLobby(a, STAKE);

        vm.expectEmit(address(garden));
        emit Garden.DuelFought(1, lobbyId, a, b, 1);
        vm.prank(bob);
        uint256 duelId = garden.joinLobby(lobbyId, b);

        assertEq(duelId, 1);
        assertEq(garden.lastDuelId(), 1);
        assertEq(uint8(garden.lobbyOf(lobbyId).status), uint8(Garden.LobbyStatus.Fought), "fought");
        assertEq(garden.crystalOf(a).openLobby, 0, "the creator's crystal is free");
        _assertOpenLobbies(new uint256[](0));

        vm.expectRevert(Garden.LobbyNotOpen.selector);
        vm.prank(bob);
        garden.joinLobby(lobbyId, late);
        _wait(LOBBY_TIMEOUT);
        vm.expectRevert(Garden.LobbyNotOpen.selector);
        vm.prank(alice);
        garden.cancelLobby(lobbyId);

        _assertOpenLobbies(_ids(_openLobby(a, STAKE)));
    }

    /// A lobby that was never opened can be neither joined nor cancelled.
    function testALobbyNeverOpenedCannotBeJoinedOrCancelled() public {
        uint256 tokenId = _forge(alice);
        _wait(1 days);
        uint256[2] memory unknown = [uint256(0), 1];
        for (uint256 i; i < unknown.length; i++) {
            vm.startPrank(alice);
            vm.expectRevert(Garden.LobbyNotOpen.selector);
            garden.joinLobby(unknown[i], tokenId);
            vm.expectRevert(Garden.LobbyNotOpen.selector);
            garden.cancelLobby(unknown[i]);
            vm.stopPrank();
        }
    }

    // -- Cancelling -----------------------------------------------------------------------------------------

    /// RULES.md §7: the creator can cancel a lobby nobody has joined 24 hours after opening it, and not a second
    /// sooner. The stake comes back, with the MANA earned while waiting, the crystal is free, and nobody can join the
    /// lobby any more.
    function testTheCreatorCanCancelALobbyAfterADay() public {
        uint256 a = _forge(alice);
        uint256 b = _forge(bob);
        _wait(1 days);
        uint256 lobbyId = _openLobby(a, STAKE);
        uint256 openedAt = block.timestamp;

        vm.warp(openedAt + LOBBY_TIMEOUT - 1);
        vm.expectRevert(Garden.TooEarlyToCancel.selector);
        vm.prank(alice);
        garden.cancelLobby(lobbyId);

        vm.warp(openedAt + LOBBY_TIMEOUT);
        vm.expectEmit(address(garden));
        emit Garden.LobbyCancelled(lobbyId);
        vm.prank(alice);
        garden.cancelLobby(lobbyId);

        assertEq(uint8(garden.lobbyOf(lobbyId).status), uint8(Garden.LobbyStatus.Cancelled), "cancelled");
        assertEq(garden.crystalOf(a).openLobby, 0, "the crystal is free");
        assertEq(_balanceOf(a, aliceKey), 2 * MANA_PER_DAY, "the stake came back");
        _assertOpenLobbies(new uint256[](0));

        vm.expectRevert(Garden.LobbyNotOpen.selector);
        vm.prank(bob);
        garden.joinLobby(lobbyId, b);
        vm.expectRevert(Garden.LobbyNotOpen.selector);
        vm.prank(alice);
        garden.cancelLobby(lobbyId);
    }

    /// RULES.md §7: only the creator can cancel its lobby, not another player nor an account the creator approved.
    function testOnlyTheCreatorCanCancel() public {
        uint256 a = _forge(alice);
        _wait(1 days);
        uint256 lobbyId = _openLobby(a, STAKE);
        _wait(LOBBY_TIMEOUT);

        vm.expectRevert(Garden.NotOwner.selector);
        vm.prank(bob);
        garden.cancelLobby(lobbyId);
        vm.prank(alice);
        garden.setApprovalForAll(bob, true);
        vm.expectRevert(Garden.NotOwner.selector);
        vm.prank(bob);
        garden.cancelLobby(lobbyId);
        assertEq(uint8(garden.lobbyOf(lobbyId).status), uint8(Garden.LobbyStatus.Open));
    }

    /// RULES.md §7: a creator that could not cover the stake put nothing up, and cancelling gives nothing back.
    function testCancellingGivesBackOnlyWhatWasPutUp() public {
        uint256 a = _forge(alice);
        _wait(SHORT * SECONDS_PER_MANA);
        uint256 lobbyId = _openLobby(a, STAKE);
        assertEq(_balanceOf(a, aliceKey), SHORT, "nothing put up");

        _wait(LOBBY_TIMEOUT);
        _cancel(lobbyId);
        assertEq(_balanceOf(a, aliceKey), SHORT + MANA_PER_DAY, "nothing given back");
    }

    /// SEASON0.md §2.2: a lobby does not expire. After the timeout a challenger can still join it, until its creator
    /// cancels it.
    function testALobbyStaysOpenAfterTheTimeout() public {
        uint256 a = _forge(alice);
        uint256 b = _forge(bob);
        _wait(1 days);
        uint256 lobbyId = _openLobby(a, STAKE);
        _wait(2 * LOBBY_TIMEOUT);

        _join(lobbyId, b);
        assertEq(uint8(garden.lobbyOf(lobbyId).status), uint8(Garden.LobbyStatus.Fought));
    }

    /// The longest timeout the constructor accepts, with the longest season, cannot overflow: cancelling is refused as
    /// too early, never with a panic.
    function testTheLongestTimeoutCannotOverflow() public {
        Garden.Params memory params = _seasonZero();
        params.seasonLength = type(uint256).max;
        params.lobbyTimeout = type(uint256).max;
        garden = new Garden(params);
        uint256 a = _forge(alice);
        _wait(1 days);
        uint256 lobbyId = _openLobby(a, STAKE);
        _wait(365 days);

        vm.expectRevert(Garden.TooEarlyToCancel.selector);
        vm.prank(alice);
        garden.cancelLobby(lobbyId);
    }

    // -- Stakes ---------------------------------------------------------------------------------------------

    /**
     * RULES.md §7, Stakes: elements and levels decide every duel, and MANA never wins one. Water beats Fire whichever
     * crystal covers the stake, as the creator and as the challenger, in all four cases: both cover it, only the
     * creator, only the challenger, neither. The stake changes hands only when both covered it, and then the winner
     * takes both. Otherwise each crystal keeps its own, and the creator takes back what it put up.
     */
    function testElementsDecideWhoeverCoversTheStake() public {
        for (uint256 i; i < 4; i++) {
            (bool aCovers, bool bCovers) = (i & 1 == 0, i & 2 == 0);
            uint64 manaA = aCovers ? FUNDED : SHORT;
            uint64 manaB = bCovers ? FUNDED : SHORT;
            bool moves = aCovers && bCovers;
            string memory label = string.concat(
                "creator ", aCovers ? "covers" : "short", ", challenger ", bCovers ? "covers" : "short", ", "
            );

            (uint256 a, uint256 b) = _pair(WATER, manaA, FIRE, manaB);
            _assertDuel(
                a,
                b,
                true,
                moves ? manaA + STAKE : manaA,
                moves ? manaB - STAKE : manaB,
                string.concat(label, "Water creates")
            );
            (a, b) = _pair(FIRE, manaA, WATER, manaB);
            _assertDuel(
                a,
                b,
                false,
                moves ? manaA - STAKE : manaA,
                moves ? manaB + STAKE : manaB,
                string.concat(label, "Fire creates")
            );
        }
    }

    /// The boundary of both stake checks: a balance equal to the stake covers it, and the stakes move.
    function testABalanceEqualToTheStakeCoversIt() public {
        (uint256 a, uint256 b) = _pair(WATER, STAKE, FIRE, FUNDED);
        _assertDuel(a, b, true, 2 * STAKE, FUNDED - STAKE, "creator");
        (a, b) = _pair(FIRE, FUNDED, WATER, STAKE);
        _assertDuel(a, b, false, FUNDED - STAKE, 2 * STAKE, "challenger");
    }

    /// RULES.md §7: the creator puts up the stake when opening the lobby. One that could not cover it then has put up
    /// nothing, and the stakes stay, even if it has earned enough by the time a challenger joins. Its element still
    /// wins the duel.
    function testTheCreatorCoversTheStakeWhenOpening() public {
        (uint256 a, uint256 b) = _pair(WATER, SHORT, FIRE, FUNDED);
        uint256 lobbyId = _openLobby(a, STAKE);
        _wait(1 days);
        uint256 duelId = _join(lobbyId, b);

        assertTrue(decryptPublic(garden.duelOf(duelId).creatorWins), "Water wins");
        assertEq(_balanceOf(a, aliceKey), SHORT + MANA_PER_DAY, "the creator took nothing");
        assertEq(_balanceOf(b, bobKey), FUNDED + MANA_PER_DAY, "the challenger lost nothing");
    }

    /// SEASON0.md §2.2, Join: both crystals accrue before the stake moves, so MANA earned while the lobby waited
    /// counts, and a remainder shorter than one MANA waits for the next call.
    function testJoiningAccruesBothCrystalsFirst() public {
        (uint256 a, uint256 b) = _pair(FIRE, FUNDED, WATER, 0);
        uint256 lobbyId = _openLobby(a, STAKE);
        _wait(STAKE * SECONDS_PER_MANA + SECONDS_PER_MANA - 1);

        uint256 duelId = _join(lobbyId, b);

        // Water beats Fire, and the challenger, empty when the lobby opened, has just earned the stake, so both covered
        // it: the challenger takes both.
        assertFalse(decryptPublic(garden.duelOf(duelId).creatorWins));
        assertEq(decrypt(garden.crystalOf(b).mana, address(garden), bobKey), 2 * STAKE);
        // The creator put up the stake when opening, and earned as much while waiting.
        assertEq(decrypt(garden.crystalOf(a).mana, address(garden), aliceKey), FUNDED - STAKE + STAKE);
        // The remainder was kept: one more second completes a MANA.
        assertEq(garden.crystalOf(b).pendingMana, 0);
        _wait(1);
        assertEq(garden.crystalOf(b).pendingMana, 1);
    }

    // -- Publishing -----------------------------------------------------------------------------------------

    /// RULES.md §7, Resolution: anyone can submit the published result, here a stranger who owns no crystal. It counts
    /// in both lifetime records, and the duel leaves the pending ones.
    function testAnyoneCanPublishTheOutcome() public {
        (uint256 a, uint256 b) = _pair(EARTH, FUNDED, WATER, FUNDED);
        uint256 duelId = _duel(a, b, STAKE);
        _assertPendingDuels(_ids(duelId));
        (bool creatorWon, bytes memory proof) = decryptPublicWithSignatures(garden.duelOf(duelId).creatorWins);
        assertTrue(creatorWon, "Earth beats Water");

        vm.expectEmit(address(garden));
        emit Garden.DuelPublished(duelId, a, b);
        vm.prank(stranger);
        garden.publish(duelId, creatorWon, proof);

        assertTrue(garden.duelOf(duelId).published);
        _assertRecord(a, 1, 0);
        _assertRecord(b, 0, 1);
        assertEq(garden.crystalOf(a).wins, 1, "wins in the crystal's view");
        assertEq(garden.crystalOf(b).losses, 1, "losses in the crystal's view");
        _assertPendingDuels(new uint256[](0));
    }

    /// A forged outcome: the loser presents the genuine proof and claims the other result.
    function testPublishRejectsAFlippedOutcome() public {
        (uint256 a, uint256 b) = _pair(WATER, FUNDED, FIRE, FUNDED);
        uint256 duelId = _duel(a, b, STAKE);
        (bool creatorWon, bytes memory proof) = decryptPublicWithSignatures(garden.duelOf(duelId).creatorWins);

        // The signatures were made over the true result, so over the false one they recover to strangers.
        vm.expectPartialRevert(FHE.KMSInvalidSigner.selector);
        vm.prank(bob);
        garden.publish(duelId, !creatorWon, proof);
        assertFalse(garden.duelOf(duelId).published);
        _assertRecord(a, 0, 0);
        _assertRecord(b, 0, 0);

        // The same proof with the true result is accepted: the rejection was the claim's, not a broken proof's.
        garden.publish(duelId, creatorWon, proof);
        _assertRecord(a, 1, 0);
        _assertRecord(b, 0, 1);
    }

    /// A forged proof: well formed, over the false result, signed by as many keys as the KMS has signers, none of them
    /// the KMS's.
    function testPublishRejectsAProofTheKmsDidNotSign() public {
        (uint256 a, uint256 b) = _pair(WATER, FUNDED, FIRE, FUNDED);
        uint256 duelId = _duel(a, b, STAKE);
        bytes32[] memory handles = new bytes32[](1);
        handles[0] = ebool.unwrap(garden.duelOf(duelId).creatorWins);
        (bytes32 digest, address[] memory kmsSigners,, bytes memory extraData) = LibKmsVerifier.publicDecryptProofDigest(
            getCoprocessorConfig(address(garden)).KMSVerifierAddress, handles, abi.encode(false)
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
        garden.publish(duelId, false, proof);
        assertFalse(garden.duelOf(duelId).published);
    }

    /// A replayed proof: genuine, but made for another duel. It would credit this duel's loser.
    function testPublishRejectsAProofFromAnotherDuel() public {
        (uint256 water, uint256 fire) = _pair(WATER, FUNDED, FIRE, FUNDED);
        uint256 first = _duel(water, fire, STAKE);
        uint256 second = _duel(fire, water, STAKE);
        (bool firstCreatorWon, bytes memory firstProof) = decryptPublicWithSignatures(garden.duelOf(first).creatorWins);
        assertTrue(firstCreatorWon);
        assertFalse(decryptPublic(garden.duelOf(second).creatorWins));

        vm.expectPartialRevert(FHE.KMSInvalidSigner.selector);
        vm.prank(alice);
        garden.publish(second, firstCreatorWon, firstProof);
        assertFalse(garden.duelOf(second).published);

        // Each proof works for its own duel: the rejection was the replay's, not a broken proof's.
        garden.publish(first, firstCreatorWon, firstProof);
        _publish(second);
        _assertRecord(water, 2, 0);
        _assertRecord(fire, 0, 2);
    }

    /// A replayed proof: the same duel published twice would count its result twice.
    function testPublishRejectsASecondPublish() public {
        (uint256 a, uint256 b) = _pair(EARTH, FUNDED, WATER, FUNDED);
        uint256 duelId = _duel(a, b, STAKE);
        (bool creatorWon, bytes memory proof) = decryptPublicWithSignatures(garden.duelOf(duelId).creatorWins);
        garden.publish(duelId, creatorWon, proof);

        vm.expectRevert(Garden.AlreadyPublished.selector);
        garden.publish(duelId, creatorWon, proof);
        _assertRecord(a, 1, 0);
        _assertRecord(b, 0, 1);
    }

    /// A duel that was never fought cannot be published.
    function testPublishRejectsADuelNeverFought() public {
        (uint256 a, uint256 b) = _pair(EARTH, FUNDED, WATER, FUNDED);
        uint256 duelId = _duel(a, b, STAKE);
        (bool creatorWon, bytes memory proof) = decryptPublicWithSignatures(garden.duelOf(duelId).creatorWins);

        uint256[2] memory unknown = [uint256(0), duelId + 1];
        for (uint256 i; i < unknown.length; i++) {
            vm.expectRevert(Garden.UnknownDuel.selector);
            garden.publish(unknown[i], creatorWon, proof);
        }
    }

    /// RULES.md §4, Record: wins and losses are public and permanent. A duel published after one of its crystals was
    /// shattered still counts, and the record outlives the crystal.
    function testARecordOutlivesItsCrystal() public {
        (uint256 a, uint256 b) = _pair(WATER, FUNDED, FIRE, FUNDED);
        uint256 duelId = _duel(a, b, STAKE);
        _shatter(bob, b);

        assertTrue(_publish(duelId));
        _assertRecord(a, 1, 0);
        _assertRecord(b, 0, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, b));
        garden.crystalOf(b);
    }

    /// RULES.md §8: a duel counts for the season in which it was fought, whenever its result is published.
    function testADuelBelongsToTheSeasonItWasFought() public {
        (uint256 a, uint256 b) = _pair(WATER, FUNDED, FIRE, FUNDED);
        vm.warp(garden.GENESIS() + SEASON_LENGTH - 1);
        uint256 lobbyId = _openLobby(a, STAKE);

        vm.expectEmit(address(garden));
        emit Garden.DuelFought(1, lobbyId, a, b, 1);
        vm.prank(bob);
        uint256 duelId = garden.joinLobby(lobbyId, b);

        vm.warp(garden.GENESIS() + SEASON_LENGTH);
        assertEq(garden.currentSeason(), 2);
        _publish(duelId);
        assertEq(garden.duelOf(duelId).season, 1);
    }

    /// The pending duels and open lobbies page like the crystals: `count` ids from the cursor, and the next cursor.
    function testLobbiesAndDuelsPageByIds() public {
        uint256[4] memory crystals = [_forge(alice), _forge(alice), _forge(bob), _forge(bob)];
        _wait(1 days);
        // Lobbies 1 to 3 open, and 1 and 3 joined: duels 1 and 2. Lobby 2 stays open. Duel 1 is published.
        _openLobby(crystals[0], STAKE);
        _openLobby(crystals[1], STAKE);
        _join(1, crystals[2]);
        _openLobby(crystals[0], STAKE);
        _join(3, crystals[3]);
        _publish(1);

        (uint256[] memory ids, uint256 next) = garden.openLobbies(0, 2);
        assertEq(ids, _ids(2));
        assertEq(next, 3);
        (ids, next) = garden.openLobbies(next, 2);
        assertEq(ids, new uint256[](0));
        assertEq(next, 0);

        (ids, next) = garden.pendingDuels(0, 1);
        assertEq(ids, new uint256[](0));
        assertEq(next, 2);
        (ids, next) = garden.pendingDuels(next, 10);
        assertEq(ids, _ids(2));
        assertEq(next, 0);
        (ids, next) = garden.pendingDuels(3, 10);
        assertEq(ids, new uint256[](0));
        assertEq(next, 0);
    }

    // -- What others see ------------------------------------------------------------------------------------

    /**
     * RULES.md §7 and §9, and SEASON0.md §5: nobody outside a duel can tell whether its stakes moved. Both branches run
     * from the same state with the same public history: two crystals with 80 MANA each, Water's lobby at a stake of
     * 40, then an attunement of the challenger's Fire crystal. Only the encrypted choice differs. A hold keeps Fire's
     * 80, both cover the stake, and Water takes both. A rise spends 50, the 30 left do not cover the stake, and the
     * stakes stay. Water wins both times: the outcome does not depend on the stakes. Outside, the joins are the same:
     * Garden's event, the storage slots written and the public values in them, every log with all its fields but
     * handles, what every view shows afterwards, the gas and the HCU. The two players are not outside: each sees in its
     * own balance whether the stakes moved, as RULES.md §9 allows.
     */
    function testWhetherTheChallengerCoveredTheStakeDoesNotShow() public {
        (uint256 a, uint256 b) = _pair(WATER, 80, FIRE, 80);
        _openLobby(a, STAKE);
        uint256 lobbyId = garden.lastLobbyId();
        uint256 opened = vm.snapshotState();

        _attune(bob, b, false);
        Trace memory moved = _observe(bob, abi.encodeCall(Garden.joinLobby, (lobbyId, b)));
        assertTrue(decryptPublic(garden.duelOf(1).creatorWins), "moved: Water wins");
        assertEq(_balanceOf(a, aliceKey), 80 + STAKE, "moved: Water takes both stakes");
        assertEq(_balanceOf(b, bobKey), 80 - STAKE, "moved: Fire lost its stake");

        assertTrue(vm.revertToState(opened));
        _attune(bob, b, true);
        Trace memory stayed = _observe(bob, abi.encodeCall(Garden.joinLobby, (lobbyId, b)));
        assertTrue(decryptPublic(garden.duelOf(1).creatorWins), "stayed: Water wins");
        assertEq(_balanceOf(a, aliceKey), 80, "stayed: Water takes back its stake");
        assertEq(_balanceOf(b, bobKey), 80 - LEVEL_COST, "stayed: Fire keeps what it had");

        _assertSameFromOutside(moved, stayed);
    }

    /**
     * The same for the creator, whose stake is taken when the lobby opens: neither the opening nor the join tells a
     * creator that covered the stake from one that could not. Fire attunes, then opens a lobby at a stake of 40 that
     * Water joins. A hold keeps Fire's 80 MANA, and Water takes both stakes. A rise leaves 30, and the stakes stay.
     */
    function testWhetherTheCreatorCoveredTheStakeDoesNotShow() public {
        (uint256 a, uint256 b) = _pair(FIRE, 80, WATER, 80);
        uint256 forged = vm.snapshotState();

        _attune(alice, a, false);
        Trace memory coveredOpen = _observe(alice, abi.encodeCall(Garden.openLobby, (a, STAKE)));
        Trace memory moved = _observe(bob, abi.encodeCall(Garden.joinLobby, (1, b)));
        assertFalse(decryptPublic(garden.duelOf(1).creatorWins), "moved: Water wins");
        assertEq(_balanceOf(a, aliceKey), 80 - STAKE, "moved: Fire lost its stake");
        assertEq(_balanceOf(b, bobKey), 80 + STAKE, "moved: Water takes both stakes");

        assertTrue(vm.revertToState(forged));
        _attune(alice, a, true);
        Trace memory shortOpen = _observe(alice, abi.encodeCall(Garden.openLobby, (a, STAKE)));
        Trace memory stayed = _observe(bob, abi.encodeCall(Garden.joinLobby, (1, b)));
        assertFalse(decryptPublic(garden.duelOf(1).creatorWins), "stayed: Water wins");
        assertEq(_balanceOf(a, aliceKey), 80 - LEVEL_COST, "stayed: Fire keeps what it had");
        assertEq(_balanceOf(b, bobKey), 80, "stayed: Water keeps what it had");

        _assertSameFromOutside(coveredOpen, shortOpen);
        _assertSameFromOutside(moved, stayed);
    }

    /// Cancelling a lobby does not tell whether its creator had put up the stake: the MANA gets a new handle either
    /// way, and the call is the same from outside. A hold keeps 80 MANA and a rise leaves 30 before the lobby opens.
    /// Only the creator sees the difference, in its own balance.
    function testACancelLooksTheSameWhetherTheStakeWasPutUp() public {
        uint256 a = _forge(alice);
        _wait(80 * SECONDS_PER_MANA);
        uint256 forged = vm.snapshotState();

        Trace memory refunded = _cancelAfterAttuning(a, false);
        assertEq(_balanceOf(a, aliceKey), 80 + MANA_PER_DAY, "refunded");
        assertTrue(vm.revertToState(forged));
        Trace memory nothingBack = _cancelAfterAttuning(a, true);
        assertEq(_balanceOf(a, aliceKey), 80 - LEVEL_COST + MANA_PER_DAY, "nothing to give back");

        _assertSameFromOutside(refunded, nothingBack);
    }

    /**
     * The comparisons above are only worth what they compare: they mask handles and nothing else. Two joins at stakes
     * of 40 and 41 emit the same events from Garden, since DuelFought does not carry the stake. The stake shows only
     * in the executor's logs, encrypted as a plaintext and compared as a scalar, in the duel's storage and in its
     * view, and the comparison sees each.
     */
    function testTheComparisonSeesAPublicDifference() public {
        (uint256 a, uint256 b) = _pair(WATER, 80, FIRE, 80);
        uint256 forged = vm.snapshotState();
        _openLobby(a, STAKE);
        Trace memory forty = _observe(bob, abi.encodeCall(Garden.joinLobby, (1, b)));
        assertTrue(vm.revertToState(forged));
        _openLobby(a, STAKE + 1);
        Trace memory fortyOne = _observe(bob, abi.encodeCall(Garden.joinLobby, (1, b)));

        assertEq(forty.writes, fortyOne.writes, "the same slots");
        assertEq(forty.logs.length, fortyOne.logs.length, "as many logs");
        uint256 differing;
        for (uint256 i; i < forty.logs.length; i++) {
            if (keccak256(abi.encode(forty.logs[i])) == keccak256(abi.encode(fortyOne.logs[i]))) continue;
            differing++;
            assertNotEq(forty.logs[i].emitter, address(garden), "Garden's events are the same");
        }
        assertGt(differing, 0, "the executor's logs show the stake");
        assertNotEq(keccak256(abi.encode(forty.values)), keccak256(abi.encode(fortyOne.values)), "so does storage");
        assertNotEq(keccak256(forty.state), keccak256(fortyOne.state), "and the duel's view");
    }

    // -- Helpers --------------------------------------------------------------------------------------------

    /**
     * @dev Alice's crystal of `ea` holding `manaA` and Bob's of `eb` holding `manaB`, both at level 1, both accrued and
     *      not yet credited. The richer one is forged first, and each forge is a whole number of MANA before now.
     */
    function _pair(uint8 ea, uint64 manaA, uint8 eb, uint64 manaB) internal returns (uint256 a, uint256 b) {
        if (manaA >= manaB) {
            a = _forgeElement(alice, ea);
            _wait((manaA - manaB) * SECONDS_PER_MANA);
            b = _forgeElement(bob, eb);
            _wait(manaB * SECONDS_PER_MANA);
        } else {
            b = _forgeElement(bob, eb);
            _wait((manaB - manaA) * SECONDS_PER_MANA);
            a = _forgeElement(alice, ea);
            _wait(manaA * SECONDS_PER_MANA);
        }
        assertEq(garden.crystalOf(a).pendingMana, manaA, "the creator's MANA");
        assertEq(garden.crystalOf(b).pendingMana, manaB, "the challenger's MANA");
    }

    /// `a` opens a lobby and `b` joins it. The winner is as expected, and each crystal holds what it should.
    function _assertDuel(uint256 a, uint256 b, bool creatorWins, uint64 manaA, uint64 manaB, string memory label)
        internal
    {
        uint256 duelId = _duel(a, b, STAKE);
        assertEq(decryptPublic(garden.duelOf(duelId).creatorWins), creatorWins, string.concat(label, ": winner"));
        assertEq(_balanceOf(a, _keyOf(a)), manaA, string.concat(label, ": creator's MANA"));
        assertEq(_balanceOf(b, _keyOf(b)), manaB, string.concat(label, ": challenger's MANA"));
    }

    /// A duel between two crystals that both cover the stake: the winner gains it and the loser loses it.
    function _assertFundedDuel(uint256 a, uint256 b, bool creatorWins, string memory label) internal {
        uint64 manaA = _balanceOf(a, _keyOf(a));
        uint64 manaB = _balanceOf(b, _keyOf(b));
        assertGe(manaA, STAKE, string.concat(label, ": the creator covers the stake"));
        assertGe(manaB, STAKE, string.concat(label, ": the challenger covers the stake"));
        _assertDuel(
            a,
            b,
            creatorWins,
            creatorWins ? manaA + STAKE : manaA - STAKE,
            creatorWins ? manaB - STAKE : manaB + STAKE,
            label
        );
    }

    function _keyOf(uint256 tokenId) internal view returns (uint256) {
        address owner = garden.ownerOf(tokenId);
        return owner == alice ? aliceKey : bobKey;
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

    /// Alice attunes, opens a lobby a block later, and cancels it once it may. Only the cancel is observed.
    function _cancelAfterAttuning(uint256 tokenId, bool rise) internal returns (Trace memory) {
        _attune(alice, tokenId, rise);
        _wait(1);
        uint256 lobbyId = _openLobby(tokenId, STAKE);
        _wait(LOBBY_TIMEOUT);
        return _observe(alice, abi.encodeCall(Garden.cancelLobby, (lobbyId)));
    }

    /// One call, a block after the last one, as an outsider sees it.
    function _observe(address caller, bytes memory call) internal returns (Trace memory t) {
        _wait(1);
        vm.recordLogs();
        vm.record();
        resetHCU();
        vm.prank(caller);
        (bool ok,) = address(garden).call(call);
        assertTrue(ok, "the observed call");
        t.gas = vm.lastCallGas().gasTotalUsed;
        t.hcu = lastHCU();
        (, t.writes) = vm.accesses(address(garden));
        t.logs = _masked(vm.getRecordedLogs());
        t.values = _maskedValues(t.writes);
        t.state = _publicState();
        // An empty trace would match any other: these comparisons are only worth what they compare.
        assertGt(t.logs.length, 0, "logs");
        assertGt(t.writes.length, 0, "writes");
        assertGt(t.hcu.transaction, 0, "HCU");
    }

    /// Everything Garden's views show but handles: each crystal's public fields, each lobby and duel, the counters.
    function _publicState() internal view returns (bytes memory state) {
        state = abi.encode(garden.totalSupply(), garden.lastTokenId(), garden.lastLobbyId(), garden.lastDuelId());
        for (uint256 id = 1; id <= garden.lastTokenId(); id++) {
            // A shattered crystal has no view left, only its record.
            try garden.crystalOf(id) returns (Garden.CrystalView memory c) {
                state = abi.encode(state, c.owner, c.lastAccrual, c.pendingMana, c.openLobby, c.wins, c.losses);
            } catch {
                (uint32 wins, uint32 losses) = garden.recordOf(id);
                state = abi.encode(state, wins, losses);
            }
        }
        for (uint256 id = 1; id <= garden.lastLobbyId(); id++) {
            Garden.Lobby memory l = garden.lobbyOf(id);
            state = abi.encode(state, l.crystal, l.stake, l.openedAt, l.status);
        }
        for (uint256 id = 1; id <= garden.lastDuelId(); id++) {
            Garden.Duel memory d = garden.duelOf(id);
            state = abi.encode(state, d.creatorCrystal, d.challengerCrystal, d.season, d.stake, d.published);
        }
    }

    function _assertSameFromOutside(Trace memory a, Trace memory b) internal pure {
        assertEq(a.writes, b.writes, "storage slots written");
        assertEq(a.values, b.values, "values written, handles masked");
        assertEq(a.state, b.state, "what the views show");
        assertEq(a.gas, b.gas, "gas");
        assertEq(a.hcu.transaction, b.hcu.transaction, "HCU per transaction");
        assertEq(a.hcu.maxHandle, b.hcu.maxHandle, "HCU depth");
        _assertSameLogs(a.logs, b.logs);
    }

    function _assertOpenLobbies(uint256[] memory expected) internal view {
        (uint256[] memory ids, uint256 next) = garden.openLobbies(0, 100);
        assertEq(ids, expected, "open lobbies");
        assertEq(next, 0);
    }

    function _assertPendingDuels(uint256[] memory expected) internal view {
        (uint256[] memory ids, uint256 next) = garden.pendingDuels(0, 100);
        assertEq(ids, expected, "pending duels");
        assertEq(next, 0);
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = a;
    }

    function _ids(uint256 a, uint256 b) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        (ids[0], ids[1]) = (a, b);
    }
}
