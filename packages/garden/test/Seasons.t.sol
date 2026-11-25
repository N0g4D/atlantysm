// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {euint64} from "@fhevm/solidity/lib/FHE.sol";
import {FhevmHCUMeter} from "@fhevm/forge/FhevmVm.sol";
import {Vm} from "forge-std/Vm.sol";
import {Garden} from "../src/Garden.sol";
import {GardenFixture} from "./utils/GardenFixture.sol";

/// RULES.md §8, seasons and the centre: the season index, the ranking, closing a season, and its prize.
contract SeasonsTest is GardenFixture {
    /// The owner of a third winner, so that each of three winners belongs to someone else.
    address internal carol;
    uint256 internal carolKey;

    /// What an outsider can observe of one call, every handle masked (GardenFixture._masked).
    struct Trace {
        Vm.Log[] logs;
        /// Garden's storage slots written, in order, and the values they hold afterwards.
        bytes32[] writes;
        bytes32[] values;
        /// Everything Garden's views show afterwards but handles.
        bytes state;
        uint256 gas;
        FhevmHCUMeter hcu;
    }

    function setUp() public override {
        super.setUp();
        // A test forges, fights and publishes many times in one forge test, which is one transaction, so the HCU caps
        // would bind on the scaffolding. On chain each call is a transaction of its own, which Hcu.t.sol measures
        // against the real caps.
        disableHCULimits();
        (carol, carolKey) = makeAddrAndKey("carol");
        vm.deal(carol, 100 ether);
    }

    // -- The season index -----------------------------------------------------------------------------------

    /// RULES.md §8 and SEASON0.md §2.1: seasons follow one another from the deployment, the first numbered 1, each
    /// SEASON_LENGTH long. A Garden deployed later starts a season 1 of its own.
    function testSeasonsFollowOneAnotherFromTheDeployment() public {
        uint256 genesis = garden.GENESIS();
        assertEq(genesis, block.timestamp, "season 1 starts at the deployment");
        assertEq(garden.currentSeason(), 1);
        vm.warp(genesis + SEASON_LENGTH - 1);
        assertEq(garden.currentSeason(), 1, "the last second of season 1");
        vm.warp(genesis + SEASON_LENGTH);
        assertEq(garden.currentSeason(), 2, "the first second of season 2");
        vm.warp(genesis + 10 * SEASON_LENGTH + 1 days);
        assertEq(garden.currentSeason(), 11);

        Garden later = new Garden(_seasonZero());
        assertEq(later.GENESIS(), block.timestamp);
        assertEq(later.currentSeason(), 1, "a later deployment starts its own season 1");
    }

    /// RULES.md §8: a new season resets the ranking only. Crystals keep their level, MANA and record, the season that
    /// ended keeps its ranking, and the new one starts from nothing.
    function testANewSeasonResetsOnlyTheRanking() public {
        uint256 water = _forgeElement(alice, WATER);
        uint256 fire = _forgeElement(bob, FIRE);
        uint256 earth = _forgeElement(bob, EARTH);
        _wait(1 days);
        // Water rises to level 2 (100 - 50 = 50 MANA), then beats Fire at a stake of 10 (60 MANA).
        _attune(alice, water, true);
        _publish(_fight(water, fire));
        _assertTop(1, water, 0, 0, "season 1");

        vm.warp(_seasonEnd(1));
        assertEq(garden.currentSeason(), 2);
        _assertTop(2, 0, 0, 0, "season 2 starts empty");
        _assertTop(1, water, 0, 0, "season 1 keeps its ranking");
        assertEq(decrypt(garden.crystalOf(water).level, address(garden), aliceKey), 2, "the level stays");
        assertEq(_balanceOf(water, aliceKey), 60 + 2 * MANA_PER_DAY, "the MANA stays, and keeps accruing");
        _assertRecord(water, 1, 0);

        // Earth beats Water: a win in season 2 counts there, and the record goes on across seasons.
        _publish(_fight(earth, water));
        _assertTop(2, earth, 0, 0, "season 2");
        _assertTop(1, water, 0, 0, "season 1 is unchanged");
        _assertRecord(water, 1, 1);
        _assertScore(1, water, 1, 0, 1);
        _assertScore(2, water, 0, 1, 0);
    }

    // -- The ranking ----------------------------------------------------------------------------------------

    /**
     * RULES.md §8, Ranking: crystals are ranked by their wins in the season. Losses do not count against them, and a
     * crystal with no win is not ranked. W3 wins first, in duel 1, but W2 wins twice and W1 three times, and W1 loses to
     * Earth as well. Earth's one win comes after W3's, so W3 keeps the third place.
     */
    function testCrystalsAreRankedByWinsInTheSeason() public {
        uint256 w1 = _forgeElement(alice, WATER);
        uint256 w2 = _forgeElement(bob, WATER);
        uint256 w3 = _forgeElement(carol, WATER);
        uint256 fire = _forgeElement(alice, FIRE);
        uint256 earth = _forgeElement(bob, EARTH);

        uint256[7] memory duels = [
            _fight(w3, fire),
            _fight(w2, fire),
            _fight(w2, fire),
            _fight(w1, fire),
            _fight(w1, fire),
            _fight(earth, w1),
            _fight(w1, fire)
        ];
        for (uint256 i; i < duels.length; i++) {
            _publish(duels[i]);
        }

        (uint256[3] memory crystals, uint32[3] memory wins, bool closed) = garden.rankingOf(1);
        assertEq(crystals[0], w1, "first");
        assertEq(crystals[1], w2, "second");
        assertEq(crystals[2], w3, "third");
        assertEq(wins[0], 3);
        assertEq(wins[1], 2);
        assertEq(wins[2], 1);
        assertFalse(closed);
        _assertScore(1, w1, 3, 1, duels[6]);
        _assertScore(1, earth, 1, 0, duels[5]);
        _assertScore(1, fire, 0, 6, 0);
    }

    /**
     * RULES.md §8, Ranking: ties go to whoever reached the score first, counting duels in the order they were fought.
     * W1, W2, W3 and W4 each win twice. W1 wins first of all, in duel 1, but reaches two wins last of the three, in duel
     * 6: W2 reaches them in duel 4 and W3 in duel 5. W4 reaches them in duel 8 and is left out. The results are
     * published from the last duel to the first, so that every later duel is counted before the earlier ones, and
     * then, from the same state, in the order the duels were fought: the ranking is the same.
     */
    function testTiesGoToWhoeverReachedTheScoreFirst() public {
        uint256[4] memory w = [
            _forgeElement(alice, WATER),
            _forgeElement(bob, WATER),
            _forgeElement(carol, WATER),
            _forgeElement(bob, WATER)
        ];
        uint256 f1 = _forgeElement(alice, FIRE);
        uint256 f2 = _forgeElement(carol, FIRE);
        uint256[8] memory duels = [
            _fight(w[0], f1),
            _fight(w[1], f1),
            _fight(w[2], f2),
            _fight(w[1], f2),
            _fight(w[2], f1),
            _fight(w[0], f2),
            _fight(w[3], f1),
            _fight(w[3], f2)
        ];
        uint256 fought = vm.snapshotState();

        for (uint256 i = duels.length; i > 0; i--) {
            _publish(duels[i - 1]);
        }
        _assertTop(1, w[1], w[2], w[0], "published last to first");
        _assertScore(1, w[0], 2, 0, duels[5]);
        _assertScore(1, w[3], 2, 0, duels[7]);

        assertTrue(vm.revertToState(fought));
        for (uint256 i; i < duels.length; i++) {
            _publish(duels[i]);
        }
        _assertTop(1, w[1], w[2], w[0], "published first to last");
    }

    /**
     * SEASON0.md §5, Ranking: the same duels give the same top three whatever order their results are published in, and
     * after every result published, the top three are exact for the results counted so far. Nine duels among seven
     * crystals: W1 and W2 win twice, F2, E1, F3, E2 and F1 once each. Each order is checked step by step against a ranking
     * worked out by sorting every crystal, not by the contract's insertion. Published last to first, W1 falls out of the
     * top three when F2's earlier win is counted, and comes back with its own earlier win.
     */
    function testTheSameDuelsGiveTheSameTopThreeInAnyOrder() public {
        // W1, W2, F1, F2, F3, E1, E2.
        uint256[7] memory crystals = [
            _forgeElement(alice, WATER),
            _forgeElement(bob, WATER),
            _forgeElement(carol, FIRE),
            _forgeElement(alice, FIRE),
            _forgeElement(bob, FIRE),
            _forgeElement(carol, EARTH),
            _forgeElement(alice, EARTH)
        ];
        uint8[7] memory elements = [WATER, WATER, FIRE, FIRE, FIRE, EARTH, EARTH];
        // Creator and challenger of each duel, by index: Water beats Fire, Fire beats Earth, Earth beats Water.
        uint8[2][9] memory pairs = [
            [0, 2], // W1 beats F1
            [3, 5], // F2 beats E1
            [1, 4], // W2 beats F3
            [5, 0], // E1 beats W1
            [0, 3], // W1 beats F2
            [1, 2], // W2 beats F1
            [4, 5], // F3 beats E1
            [6, 1], // E2 beats W2
            [2, 6] // F1 beats E2
        ];
        uint256[] memory duels = new uint256[](pairs.length);
        uint256[] memory winners = new uint256[](pairs.length);
        for (uint256 i; i < pairs.length; i++) {
            (uint8 a, uint8 b) = (pairs[i][0], pairs[i][1]);
            duels[i] = _fight(crystals[a], crystals[b]);
            winners[i] = _beats(elements[a], elements[b]) ? a : b;
        }
        uint256 fought = vm.snapshotState();

        uint256[] memory order = new uint256[](pairs.length);
        for (uint256 run; run < 34; run++) {
            // The first run publishes in the order the duels were fought, the second in reverse, the rest shuffled.
            for (uint256 i; i < order.length; i++) {
                order[i] = run == 1 ? order.length - 1 - i : i;
            }
            if (run > 1) _shuffle(order, uint256(keccak256(abi.encode("order", run))));
            assertTrue(vm.revertToState(fought));
            _assertPublishedInOrder(crystals, duels, winners, order, string.concat("order ", vm.toString(run)));
            _assertTop(
                1, crystals[0], crystals[1], crystals[3], string.concat("order ", vm.toString(run), ": in the end")
            );
        }
    }

    /// RULES.md §8: a duel counts for the season in which it was fought, once its result is published, even when that
    /// happens in the next season, within the close delay: here ten minutes in. Until then it does not count anywhere.
    function testADuelCountsForTheSeasonItWasFought() public {
        uint256 water = _forgeElement(alice, WATER);
        uint256 fire = _forgeElement(bob, FIRE);
        vm.warp(_seasonEnd(1) - 1);
        uint256 duelId = _fight(water, fire);
        _assertTop(1, 0, 0, 0, "not published yet");

        vm.warp(_seasonEnd(1) + 10 minutes);
        assertEq(garden.currentSeason(), 2);
        _publish(duelId);
        _assertTop(1, water, 0, 0, "season 1");
        _assertTop(2, 0, 0, 0, "season 2");
        _assertScore(1, water, 1, 0, duelId);
        _assertScore(2, water, 0, 0, 0);
    }

    /**
     * RULES.md §8, as amended in #15: a duel counts for the season it was fought in if its result is published within
     * SEASON_CLOSE_DELAY of the season's end. A result published later counts only in the crystals' records, whether
     * or not anyone has closed the season yet. Three results of season 1: the one published a second before the delay
     * runs out counts. The one published at that second, with nobody having closed the season, does not, and neither
     * does the one published after the close. None counts for season 2.
     */
    function testAResultCountsOnlyWithinTheCloseDelay() public {
        uint256 water = _forgeElement(alice, WATER);
        uint256 fire = _forgeElement(bob, FIRE);
        uint256 earth = _forgeElement(carol, EARTH);
        // Water beats Fire, Earth beats Water, Fire beats Earth.
        uint256 inTime = _fight(water, fire);
        uint256 atTheDelay = _fight(earth, water);
        uint256 afterTheClose = _fight(fire, earth);

        vm.warp(_seasonEnd(1) + SEASON_CLOSE_DELAY - 1);
        _publish(inTime);
        vm.warp(_seasonEnd(1) + SEASON_CLOSE_DELAY);
        _publish(atTheDelay);
        (,, bool closed) = garden.rankingOf(1);
        assertFalse(closed, "nobody has closed the season yet");
        _closeSeason(1);
        _publish(afterTheClose);

        _assertTop(1, water, 0, 0, "season 1");
        _assertTop(2, 0, 0, 0, "season 2");
        _assertScore(1, water, 1, 0, inTime);
        _assertScore(1, fire, 0, 1, 0);
        _assertScore(1, earth, 0, 0, 0);
        _assertScore(2, earth, 0, 0, 0);
        _assertRecord(water, 1, 1);
        _assertRecord(earth, 1, 1);
        _assertRecord(fire, 1, 1);
    }

    /**
     * RULES.md §8, as amended in #15: the ranking is final once the delay after the season's end runs out, and from
     * then on anyone can close the season with the same outcome, whoever closes it and whenever. Three Water crystals
     * are ranked, and Earth has two wins pending, over the second and the third, that would put it third. Its results
     * miss the delay.
     * - In one branch, the third place's owner closes the season at the first moment, and Earth's results come after.
     * - In the other, Earth's results come first, and a stranger closes the season a day later.
     * Both pay the same three crystals the same shares of the 753 MANA, and Earth's wins count only in its record. Both
     * closes fall in season 2, with every winner alive. When a close comes still decides where what the season keeps
     * back goes (`testTheRestGoesToTheSeasonInProgress`), and a winner shattered before the close leaves its share in the
     * centre (`testAShatteredWinnersShareStaysInTheCentre`).
     */
    function testTheOutcomeIsTheSameWhoeverClosesAndWhenever() public {
        uint256[3] memory top = _rankThree();
        uint256 earth = _forgeElement(bob, EARTH);
        uint256[2] memory pending = [_fight(earth, top[2]), _fight(earth, top[1])];
        _shatterIntoThePot(3, 251);
        uint256[3] memory keys = [bobKey, carolKey, aliceKey];
        uint256 fought = vm.snapshotState();

        _waitUntilClosable(1);
        uint64[3] memory before = _balances(top, keys);
        vm.prank(alice);
        garden.closeSeason(1);
        uint64[3] memory atOnce = _gains(top, keys, before);
        _publish(pending[0]);
        _publish(pending[1]);
        _assertTop(1, top[0], top[1], top[2], "closed at once");

        assertTrue(vm.revertToState(fought));
        _waitUntilClosable(1);
        _publish(pending[0]);
        _publish(pending[1]);
        _assertTop(1, top[0], top[1], top[2], "Earth's results came too late");
        _wait(1 days);
        before = _balances(top, keys);
        _closeSeason(1);
        uint64[3] memory aDayLater = _gains(top, keys, before);

        uint64[3] memory expected = [uint64(376), 225, 150];
        for (uint256 place; place < 3; place++) {
            assertEq(atOnce[place], expected[place], "closed at once: the share");
            assertEq(aDayLater[place], expected[place], "closed a day later: the same share");
        }
        _assertScore(1, earth, 0, 0, 0);
        _assertRecord(earth, 2, 0);
    }

    // -- Closing --------------------------------------------------------------------------------------------

    /**
     * RULES.md §8 and SEASON0.md §5: a season can be closed SEASON_CLOSE_DELAY after it ends, by anyone, and not a second
     * sooner. Neither the season in progress nor a later one can be closed, whatever its number, and there is no
     * season 0.
     */
    function testASeasonCanBeClosedAnHourAfterItEnds() public {
        uint256 water = _forgeElement(alice, WATER);
        uint256 fire = _forgeElement(bob, FIRE);
        _publish(_fight(water, fire));

        uint256[3] memory refused = [uint256(1), 2, type(uint256).max];
        for (uint256 i; i < refused.length; i++) {
            vm.expectRevert(Garden.TooEarlyToClose.selector);
            garden.closeSeason(refused[i]);
        }
        vm.warp(_seasonEnd(1));
        vm.expectRevert(Garden.TooEarlyToClose.selector);
        garden.closeSeason(1);
        vm.warp(_seasonEnd(1) + SEASON_CLOSE_DELAY - 1);
        vm.expectRevert(Garden.TooEarlyToClose.selector);
        garden.closeSeason(1);
        vm.expectRevert(Garden.TooEarlyToClose.selector);
        garden.closeSeason(2);
        vm.expectRevert(Garden.UnknownSeason.selector);
        garden.closeSeason(0);

        vm.warp(_seasonEnd(1) + SEASON_CLOSE_DELAY);
        vm.expectEmit(address(garden));
        emit Garden.SeasonClosed(1, water, 0, 0);
        vm.prank(stranger);
        garden.closeSeason(1);
        (,, bool closed) = garden.rankingOf(1);
        assertTrue(closed);
    }

    /// SEASON0.md §5: a season is closed once. A season in which nothing happened can be closed too, and pays nobody.
    function testASeasonIsClosedOnce() public {
        _waitUntilClosable(2);
        _closeSeason(2);
        vm.expectRevert(Garden.AlreadyClosed.selector);
        garden.closeSeason(2);
        _closeSeason(1);
        vm.expectRevert(Garden.AlreadyClosed.selector);
        vm.prank(alice);
        garden.closeSeason(1);
        _assertTop(1, 0, 0, 0, "nobody ranked");
        assertEq(_pot(3), 0, "nothing to carry over");
    }

    /**
     * RULES.md §8, The prize: when a season is closed, its centre is credited to its top three crystals in encrypted
     * shares of 50%, 30% and 20%, rounded down, and what rounding leaves stays in the centre for the season in progress.
     * Three crystals that have accrued 251 MANA each are shattered into season 1's centre, which then holds 753. The
     * shares are 376, 225 and 150, and 2 MANA are left. Each winner has a different owner and finds its share in its
     * own balance. Since the split is fixed, each can work out the centre's total from its share, to within a few MANA
     * because shares are rounded down (RULES.md §8 accepts it).
     */
    function testClosingCreditsTheCentreToTheTopThree() public {
        uint256[3] memory top = _rankThree();
        _shatterIntoThePot(3, 251);
        assertEq(_pot(1), 753);

        _waitUntilClosable(1);
        uint256[3] memory keys = [bobKey, carolKey, aliceKey];
        uint64[3] memory before;
        for (uint256 place; place < 3; place++) {
            before[place] = _balanceOf(top[place], keys[place]);
        }
        euint64 closedPot = garden.potOf(1);
        _closeSeason(1);

        uint64[3] memory expected = [uint64(376), 225, 150];
        for (uint256 place; place < 3; place++) {
            uint64 share = _balanceOf(top[place], keys[place]) - before[place];
            assertEq(share, expected[place], string.concat("the share of place ", vm.toString(place + 1)));
            (uint256 low, uint256 high) = _totalsGiving(share, place);
            assertTrue(low <= 753 && 753 <= high, "the winner can work out the total");
            assertLe(high - low, 4, "to within a few MANA");
        }
        assertEq(euint64.unwrap(garden.potOf(1)), 0, "season 1's pot is paid out");
        assertEq(plaintextOf(closedPot), 753, "the handle closed still holds the total, for nobody to read");
        assertEq(_pot(2), 2, "rounding leaves 2 MANA for season 2");
    }

    /**
     * RULES.md §8: a share with no crystal to take it stays in the centre for the season in progress. With one crystal
     * ranked, it takes 50% of the 101 MANA, rounded down, and the other 51 go to season 2. A season with nobody ranked
     * carries its whole centre over.
     */
    function testSharesNobodyTakesStayInTheCentre() public {
        uint256 water = _forgeElement(bob, WATER);
        uint256 fire = _forgeElement(alice, FIRE);
        _publish(_fight(water, fire));
        _shatterIntoThePot(1, 101);

        _waitUntilClosable(1);
        uint64 before = _balanceOf(water, bobKey);
        _closeSeason(1);
        assertEq(_balanceOf(water, bobKey) - before, 50, "the first share");
        assertEq(_pot(2), 51, "the second and third shares, and the rounding");

        // Nobody fights in season 2, and its centre, the 51 carried over, goes on to season 3.
        _waitUntilClosable(2);
        _closeSeason(2);
        assertEq(_pot(3), 51, "all of season 2's centre");
        assertEq(_pot(2), 0);
    }

    /**
     * RULES.md §8: a ranked crystal that has been shattered keeps its place, but its share has no crystal to take it and
     * stays in the centre for the season in progress. The crystals below it keep their own places and shares. The
     * second of three winners is shattered at the start of season 2, with its 300 MANA going into season 2's centre;
     * season 1's centre holds 753. The first takes 376, the third 150, and season 2 gets the second's 225 and the 2 of
     * rounding.
     */
    function testAShatteredWinnersShareStaysInTheCentre() public {
        uint256[3] memory top = _rankThree();
        _shatterIntoThePot(3, 251);

        vm.warp(_seasonEnd(1));
        uint64 shatteredMana = _balanceOf(top[1], carolKey);
        _shatter(carol, top[1]);
        assertEq(_pot(2), shatteredMana);

        _waitUntilClosable(1);
        uint64 firstBefore = _balanceOf(top[0], bobKey);
        uint64 thirdBefore = _balanceOf(top[2], aliceKey);
        vm.expectEmit(address(garden));
        emit Garden.SeasonClosed(1, top[0], top[1], top[2]);
        _closeSeason(1);

        assertEq(_balanceOf(top[0], bobKey) - firstBefore, 376, "the first share");
        assertEq(_balanceOf(top[2], aliceKey) - thirdBefore, 150, "the third share, not the second's");
        assertEq(_pot(2), shatteredMana + 225 + 2, "the shattered crystal's share stays");
        _assertTop(1, top[0], top[1], top[2], "the shattered crystal keeps its place");
        _assertScore(1, top[1], 2, 0, 3);
    }

    /**
     * RULES.md §4 and §8: a shattered crystal's results still count, so a win of its published after the shatter
     * moves it up, while its share stays in the centre. W1 and W2 win once each, W2 after W1, so W1 leads. W2 is
     * shattered with its second win still pending; once published, W2 takes the first place from W1. At the close W1,
     * second, takes 30% of the 101 MANA, and the first share stays in the centre with the rest.
     */
    function testAShatteredCrystalStillMovesUpOnALateWin() public {
        uint256 w1 = _forgeElement(alice, WATER);
        uint256 w2 = _forgeElement(bob, WATER);
        uint256 fire = _forgeElement(carol, FIRE);
        _publish(_fight(w1, fire));
        _publish(_fight(w2, fire));
        uint256 late = _fight(w2, fire);
        _assertTop(1, w1, w2, 0, "before the shatter");

        _shatter(bob, w2);
        _publish(late);
        _assertTop(1, w2, w1, 0, "the shattered crystal moves up");
        _assertRecord(w2, 2, 0);
        _shatterIntoThePot(1, 101);

        _waitUntilClosable(1);
        uint64 before = _balanceOf(w1, aliceKey);
        _closeSeason(1);
        assertEq(_balanceOf(w1, aliceKey) - before, 30, "the second share");
        assertEq(_pot(2), 101 - 30, "the first and third shares stay in the centre");
    }

    /**
     * The close follows the deployment's parameters: here a split that gives the whole centre to the first place, and
     * no close delay. The season can then be closed the moment it ends: the first takes all 101 MANA, the second and
     * third take nothing, and nothing is carried over. With no delay, a result counts only if published before the
     * season ends (RULES.md §8). A duel fought in the season's last second cannot be decrypted and published by then,
     * so its result counts only in the records: a deployment needs a delay long enough to decrypt and publish one.
     */
    function testAnotherSplitAndNoDelay() public {
        Garden.Params memory params = _seasonZero();
        params.prizeShares = [100, 0, 0];
        params.seasonCloseDelay = 0;
        garden = new Garden(params);
        uint256[3] memory top = _rankThree();
        _shatterIntoThePot(1, 101);
        uint256 lateWinner = _forgeElement(carol, WATER);
        uint256 lateLoser = _forgeElement(alice, FIRE);
        vm.warp(_seasonEnd(1) - 1);
        uint256 late = _fight(lateWinner, lateLoser);

        vm.warp(_seasonEnd(1));
        uint256[3] memory keys = [bobKey, carolKey, aliceKey];
        uint64[3] memory before = _balances(top, keys);
        _closeSeason(1);
        uint64[3] memory gained = _gains(top, keys, before);
        assertEq(gained[0], 101, "the whole centre");
        assertEq(gained[1], 0, "nothing for the second");
        assertEq(gained[2], 0, "nothing for the third");
        assertEq(_pot(2), 0, "nothing carried over");

        _publish(late);
        _assertTop(1, top[0], top[1], top[2], "the last duel does not count");
        _assertRecord(lateWinner, 1, 0);
    }

    /// SEASON0.md §2.2, Close a season: the centre that a closed season keeps back goes to the season in progress, even
    /// when the close comes late. Season 1, closed in season 3, carries its 101 MANA to season 3's centre, and season 2's
    /// stays as it was.
    function testTheRestGoesToTheSeasonInProgress() public {
        _shatterIntoThePot(1, 101);
        vm.warp(_seasonEnd(1));
        _shatterIntoThePot(1, 40);
        assertEq(_pot(2), 40);

        vm.warp(_seasonEnd(2) + SEASON_CLOSE_DELAY);
        assertEq(garden.currentSeason(), 3);
        _closeSeason(1);
        assertEq(_pot(3), 101, "season 1's centre");
        assertEq(_pot(2), 40, "season 2's is untouched");
        _closeSeason(2);
        assertEq(_pot(3), 141, "and season 2's");
    }

    /// RULES.md §4 and §8: a winner waiting in an open lobby still receives its share, and the lobby carries on: its
    /// creator put up the stake when opening, and the share is MANA on top.
    function testAWaitingWinnerStillReceivesItsShare() public {
        uint256 water = _forgeElement(bob, WATER);
        uint256 fire = _forgeElement(alice, FIRE);
        _publish(_fight(water, fire));
        _shatterIntoThePot(1, 101);

        _waitUntilClosable(1);
        uint256 lobbyId = _openLobby(water, MIN_STAKE);
        uint64 before = _balanceOf(water, bobKey);
        _closeSeason(1);
        assertEq(_balanceOf(water, bobKey) - before, 50, "the share");
        assertEq(garden.crystalOf(water).openLobby, lobbyId, "still waiting");

        _join(lobbyId, fire);
        assertEq(_balanceOf(water, bobKey), before + 50 + 2 * MIN_STAKE, "Water beats Fire, and takes both stakes");
    }

    /// RULES.md §4 and §8: a place belongs to the crystal, and the close credits its share to the crystal, sealed for
    /// whoever owns it then. A winner transferred after its win keeps its record and its place, and its share goes to its
    /// new owner, alone in reading the balance.
    function testAWinnersShareGoesToWhoeverOwnsItAtTheClose() public {
        uint256 water = _forgeElement(bob, WATER);
        uint256 fire = _forgeElement(alice, FIRE);
        _publish(_fight(water, fire));
        _shatterIntoThePot(1, 101);

        _transfer(bob, carol, water);
        _assertRecord(water, 1, 0);
        _assertTop(1, water, 0, 0, "the place stays with the crystal");

        _waitUntilClosable(1);
        uint64 before = _balanceOf(water, carolKey);
        _closeSeason(1);
        assertEq(_balanceOf(water, carolKey) - before, 50, "the share, for Carol");
        _assertCannotDecrypt(garden.crystalOf(water).mana, bob, bobKey);
    }

    /**
     * RULES.md §8 and §9: the centre's total is never published, not even by closing the season. Two branches share one
     * public history: the same crystals, the same duels published in the same order, and in season 1 an attunement of
     * a crystal that never fights. Only its encrypted choice differs. A rise puts 50 MANA in the centre, which the
     * winners share as 25, 15 and 10; a hold leaves it empty, and they take nothing. Outside, the two closes are the
     * same: Garden's event, the storage slots written and the public values in them, every log with all its fields but
     * handles, what the views show afterwards, the gas and the HCU.
     */
    function testClosingDoesNotShowWhatTheCentreHolds() public {
        uint256[3] memory top = _rankThree();
        uint256 donor = _forge(alice);
        _wait(1 days);
        uint256 ranked = vm.snapshotState();
        uint256[3] memory keys = [bobKey, carolKey, aliceKey];

        _attune(alice, donor, true);
        _waitUntilClosable(1);
        uint64[3] memory before = _balances(top, keys);
        Trace memory full = _observeClose(1);
        uint64[3] memory gained = _gains(top, keys, before);
        assertEq(gained[0], 25, "full: the first share");
        assertEq(gained[1], 15, "full: the second share");
        assertEq(gained[2], 10, "full: the third share");

        assertTrue(vm.revertToState(ranked));
        _attune(alice, donor, false);
        _waitUntilClosable(1);
        before = _balances(top, keys);
        Trace memory empty = _observeClose(1);
        gained = _gains(top, keys, before);
        assertEq(gained[0] + gained[1] + gained[2], 0, "empty: no share");

        assertEq(full.writes, empty.writes, "storage slots written");
        assertEq(full.values, empty.values, "values written, handles masked");
        assertEq(full.state, empty.state, "what the views show");
        assertEq(full.gas, empty.gas, "gas");
        assertEq(full.hcu.transaction, empty.hcu.transaction, "HCU per transaction");
        assertEq(full.hcu.maxHandle, empty.hcu.maxHandle, "HCU depth");
        _assertSameLogs(full.logs, empty.logs);
    }

    // -- Helpers --------------------------------------------------------------------------------------------

    /// `a` opens a lobby at the smallest stake and `b` joins it. Nothing is published.
    function _fight(uint256 a, uint256 b) internal returns (uint256 duelId) {
        duelId = _duel(a, b, MIN_STAKE);
    }

    /**
     * @dev Three Water crystals ranked first, second and third in season 1, owned by Bob, Carol and Alice: they beat
     *      Alice's Fire crystal three times, twice and once. The third wins first, in duel 1, so wins alone rank them.
     *      Each holds a little MANA, which the stakes move.
     */
    function _rankThree() internal returns (uint256[3] memory top) {
        top = [_forgeElement(bob, WATER), _forgeElement(carol, WATER), _forgeElement(alice, WATER)];
        uint256 fire = _forgeElement(alice, FIRE);
        uint256[3] memory wins = [uint256(3), 2, 1];
        for (uint256 place = 3; place > 0; place--) {
            for (uint256 i; i < wins[place - 1]; i++) {
                _publish(_fight(top[place - 1], fire));
            }
        }
        _assertTop(1, top[0], top[1], top[2], "three ranked");
    }

    /// Alice forges `count` crystals, waits until each has accrued `mana`, and shatters them into the season's centre.
    function _shatterIntoThePot(uint256 count, uint64 mana) internal {
        uint256[] memory donors = new uint256[](count);
        for (uint256 i; i < count; i++) {
            donors[i] = _forge(alice);
        }
        _wait(mana * SECONDS_PER_MANA);
        for (uint256 i; i < count; i++) {
            _shatter(alice, donors[i]);
        }
    }

    /// Every centre total that would give `share` to `place`, as a winner works it out: the lowest and the highest.
    function _totalsGiving(uint64 share, uint256 place) internal pure returns (uint256 low, uint256 high) {
        uint256 percent = place == 0 ? FIRST_SHARE : place == 1 ? SECOND_SHARE : THIRD_SHARE;
        low = (uint256(share) * 100 + percent - 1) / percent;
        high = low;
        while (_shareOf(high + 1, place) == share) high++;
        assertEq(_shareOf(low, place), share, "the lowest total");
        if (low > 0) assertLt(_shareOf(low - 1, place), share, "and no lower one");
    }

    function _assertScore(uint256 season, uint256 tokenId, uint32 wins, uint32 losses, uint256 lastWin) internal view {
        Garden.Score memory score = garden.scoreOf(season, tokenId);
        assertEq(score.wins, wins, "season wins");
        assertEq(score.losses, losses, "season losses");
        assertEq(score.lastWin, lastWin, "latest counted win");
    }

    /**
     * @dev Publishes the duels in `order` and, after each, checks the season's top three against a ranking worked out
     *      from RULES.md §8 by sorting every crystal: most wins first, and of two with as many, the one that reached
     *      its score in the earlier duel. A crystal reaches its score in the latest of its counted wins, by the order the
     *      duels were fought. `winners` holds each duel's winner as an index into `crystals`.
     */
    function _assertPublishedInOrder(
        uint256[7] memory crystals,
        uint256[] memory duels,
        uint256[] memory winners,
        uint256[] memory order,
        string memory label
    ) internal {
        uint256[7] memory wins;
        uint256[7] memory reached;
        for (uint256 step; step < order.length; step++) {
            uint256 i = order[step];
            _publish(duels[i]);
            wins[winners[i]]++;
            if (duels[i] > reached[winners[i]]) reached[winners[i]] = duels[i];

            uint256[3] memory expected;
            bool[7] memory taken;
            for (uint256 place; place < 3; place++) {
                uint256 best = type(uint256).max;
                for (uint256 c; c < 7; c++) {
                    if (taken[c] || wins[c] == 0) continue;
                    if (
                        best == type(uint256).max || wins[c] > wins[best]
                            || (wins[c] == wins[best] && reached[c] < reached[best])
                    ) best = c;
                }
                if (best == type(uint256).max) break;
                taken[best] = true;
                expected[place] = crystals[best];
            }
            _assertTop(1, expected[0], expected[1], expected[2], string.concat(label, ", step ", vm.toString(step)));
        }
    }

    /// Fisher-Yates, from a seed.
    function _shuffle(uint256[] memory items, uint256 seed) internal pure {
        for (uint256 i = items.length; i > 1; i--) {
            seed = uint256(keccak256(abi.encode(seed)));
            uint256 j = seed % i;
            (items[i - 1], items[j]) = (items[j], items[i - 1]);
        }
    }

    function _balances(uint256[3] memory crystals, uint256[3] memory keys)
        internal
        returns (uint64[3] memory balances)
    {
        for (uint256 i; i < 3; i++) {
            balances[i] = _balanceOf(crystals[i], keys[i]);
        }
    }

    function _gains(uint256[3] memory crystals, uint256[3] memory keys, uint64[3] memory before)
        internal
        returns (uint64[3] memory gains)
    {
        for (uint256 i; i < 3; i++) {
            gains[i] = _balanceOf(crystals[i], keys[i]) - before[i];
        }
    }

    /// A stranger closes the season, as an outsider sees it. The caller has moved to a new block already.
    function _observeClose(uint256 season) internal returns (Trace memory t) {
        vm.recordLogs();
        vm.record();
        resetHCU();
        vm.prank(stranger);
        garden.closeSeason(season);
        t.gas = vm.lastCallGas().gasTotalUsed;
        t.hcu = lastHCU();
        (, t.writes) = vm.accesses(address(garden));
        t.logs = _masked(vm.getRecordedLogs());
        t.values = _maskedValues(t.writes);
        t.state = _publicState();
        // An empty trace would match any other: the comparison is only worth what it compares.
        assertGt(t.logs.length, 0, "logs");
        assertGt(t.writes.length, 0, "writes");
        assertGt(t.hcu.transaction, 0, "HCU");
    }

    /// Everything Garden's views show but handles: each crystal's public fields and record, and each season's ranking
    /// and the scores in it.
    function _publicState() internal view returns (bytes memory state) {
        state = abi.encode(garden.totalSupply(), garden.lastTokenId(), garden.lastDuelId(), garden.currentSeason());
        for (uint256 id = 1; id <= garden.lastTokenId(); id++) {
            try garden.crystalOf(id) returns (Garden.CrystalView memory c) {
                state = abi.encode(state, c.owner, c.lastAccrual, c.pendingMana, c.openLobby, c.wins, c.losses);
            } catch {
                (uint32 wins, uint32 losses) = garden.recordOf(id);
                state = abi.encode(state, wins, losses);
            }
        }
        for (uint256 season = 1; season <= garden.currentSeason(); season++) {
            (uint256[3] memory crystals, uint32[3] memory wins, bool closed) = garden.rankingOf(season);
            state = abi.encode(state, crystals, wins, closed);
            for (uint256 id = 1; id <= garden.lastTokenId(); id++) {
                state = abi.encode(state, garden.scoreOf(season, id));
            }
        }
    }
}
