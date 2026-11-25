// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ebool, euint8, euint64, externalEbool} from "@fhevm/solidity/lib/FHE.sol";
import {TestFhevm} from "@fhevm/forge/TestFhevm.sol";
import {Vm} from "forge-std/Vm.sol";
import {Garden} from "../../src/Garden.sol";

/// The ACL lets an account allowed on a handle allow another one, and says who is allowed, for now or for good.
interface IAcl {
    function allow(bytes32 handle, address account) external;
    function isAllowed(bytes32 handle, address account) external view returns (bool);
    function isAllowedForDecryption(bytes32 handle) external view returns (bool);
}

/**
 * @dev A Garden with the Season 0 parameters of RULES.md §12, two players and a stranger, and the checks the privacy
 *      tests share: who was granted what, and who cannot decrypt.
 */
abstract contract GardenFixture is TestFhevm {
    uint256 internal constant CHARGE = 0.01 ether;
    uint64 internal constant MANA_PER_DAY = 100;
    uint256 internal constant SEASON_LENGTH = 3 days;
    /// A day over 100 MANA.
    uint64 internal constant SECONDS_PER_MANA = 864;
    /// A rise from level L costs 50 × L² MANA, up to level 10.
    uint64 internal constant LEVEL_COST = 50;
    uint8 internal constant MAX_LEVEL = 10;
    /// An Arena stake is from 10 to 100 MANA, and a lobby nobody joins can be cancelled after a day.
    uint64 internal constant MIN_STAKE = 10;
    uint64 internal constant MAX_STAKE = 100;
    uint256 internal constant LOBBY_TIMEOUT = 24 hours;
    /// A season can be closed an hour after it ends, and its centre goes 50%, 30% and 20% to its top three.
    uint256 internal constant SEASON_CLOSE_DELAY = 1 hours;
    uint8 internal constant FIRST_SHARE = 50;
    uint8 internal constant SECOND_SHARE = 30;
    uint8 internal constant THIRD_SHARE = 20;

    uint8 internal constant FIRE = 0;
    uint8 internal constant EARTH = 1;
    uint8 internal constant WATER = 2;

    /// The executor's event for a random value: the coprocessor draws it from this, and a test reads it back.
    bytes32 internal constant FHE_RAND = keccak256("FheRand(address,uint8,bytes16,bytes32)");
    /// The executor's other events that make a handle without an encrypted operand, or from other handles.
    bytes32 internal constant FHE_RAND_BOUNDED = keccak256("FheRandBounded(address,uint256,uint8,bytes16,bytes32)");
    bytes32 internal constant TRIVIAL_ENCRYPT = keccak256("TrivialEncrypt(address,uint256,uint8,bytes32)");
    bytes32 internal constant FHE_CAST = keccak256("Cast(address,bytes32,uint8,bytes32)");
    bytes32 internal constant FHE_NEG = keccak256("FheNeg(address,bytes32,bytes32)");
    bytes32 internal constant FHE_NOT = keccak256("FheNot(address,bytes32,bytes32)");
    bytes32 internal constant FHE_SELECT = keccak256("FheIfThenElse(address,bytes32,bytes32,bytes32,bytes32)");
    bytes32 internal constant FHE_IS_IN = keccak256("FheIsIn(address,bytes32,bytes32[],bytes32)");
    bytes32 internal constant FHE_SUM = keccak256("FheSum(address,bytes32[],bytes32)");
    /// The ACL's events for a persistent grant, and for handles made publicly decryptable.
    bytes32 internal constant ACL_ALLOWED = keccak256("Allowed(address,address,bytes32)");
    bytes32 internal constant ACL_PUBLIC = keccak256("AllowedForDecryption(address,bytes32[])");
    /// The executor's event for an imported input. Its proof sits in the calldata anyway.
    bytes32 internal constant VERIFY_INPUT = keccak256("VerifyInput(address,bytes32,address,bytes,uint8,bytes32)");
    /// Stands in for a handle when two runs are compared: handles differ between any two runs, whatever the secrets.
    bytes32 internal constant HANDLE = keccak256("a handle");

    /// A persistent ACL grant: `account` may use `handle`, and decrypt it if it is a user.
    struct Grant {
        address account;
        bytes32 handle;
    }

    Garden internal garden;
    address internal alice;
    uint256 internal aliceKey;
    address internal bob;
    uint256 internal bobKey;
    /// Owns no crystal and is granted nothing, ever.
    address internal stranger;
    uint256 internal strangerKey;

    function setUp() public virtual override {
        super.setUp();
        garden = _deploy(_seasonZero());
        (alice, aliceKey) = makeAddrAndKey("alice");
        (bob, bobKey) = makeAddrAndKey("bob");
        (stranger, strangerKey) = makeAddrAndKey("stranger");
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    /// Overridden by suites that need the test harness.
    function _deploy(Garden.Params memory params) internal virtual returns (Garden) {
        return new Garden(params);
    }

    function _seasonZero() internal pure returns (Garden.Params memory) {
        return Garden.Params({
            charge: CHARGE,
            manaPerDay: MANA_PER_DAY,
            seasonLength: SEASON_LENGTH,
            levelCost: LEVEL_COST,
            maxLevel: MAX_LEVEL,
            minStake: MIN_STAKE,
            maxStake: MAX_STAKE,
            lobbyTimeout: LOBBY_TIMEOUT,
            seasonCloseDelay: SEASON_CLOSE_DELAY,
            prizeShares: [FIRST_SHARE, SECOND_SHARE, THIRD_SHARE]
        });
    }

    function _forge(address forger) internal returns (uint256 tokenId) {
        vm.prank(forger);
        tokenId = garden.forge{value: CHARGE}();
    }

    function _shatter(address owner, uint256 tokenId) internal {
        vm.prank(owner);
        garden.shatter(tokenId);
    }

    /// The owner transfers the crystal (RULES.md §4, Ownership).
    function _transfer(address owner, address to, uint256 tokenId) internal {
        vm.prank(owner);
        garden.transferFrom(owner, to, tokenId);
    }

    /// The owner attunes with a choice encrypted for Garden and the owner, as the owner's client would send it.
    function _attune(address owner, uint256 tokenId, bool rise) internal {
        (externalEbool choice, bytes memory proof) = encryptBool(rise, address(garden), owner);
        vm.prank(owner);
        garden.attune(tokenId, choice, proof);
    }

    /// The same encryption, for the conservation handler, which is not a test contract.
    function encryptChoice(bool rise, address owner) external returns (externalEbool, bytes memory) {
        return encryptBool(rise, address(garden), owner);
    }

    /// For the conservation handler: the test library's readings, which only a test contract can take.
    function plaintextElement(uint256 tokenId) external returns (uint8) {
        return plaintextOf(garden.crystalOf(tokenId).element);
    }

    function plaintextBool(ebool value) external returns (bool) {
        return plaintextOf(value);
    }

    function outcomeWithProof(uint256 duelId) external returns (bool creatorWon, bytes memory proof) {
        return decryptPublicWithSignatures(garden.duelOf(duelId).creatorWins);
    }

    // -- The Arena ------------------------------------------------------------------------------------------

    /**
     * @dev A crystal of `element` for `owner`. Nobody chooses an element (RULES.md §4), so this forges until the draw
     *      gives it, reading each draw with `plaintextOf`. The misses stay with `owner`. A miss comes two times in
     *      three, so 40 in a row would take a broken draw.
     */
    function _forgeElement(address owner, uint8 element) internal returns (uint256 tokenId) {
        for (uint256 i; i < 40; i++) {
            tokenId = _forge(owner);
            if (plaintextOf(garden.crystalOf(tokenId).element) == element) return tokenId;
        }
        revert("the draw never gave the element");
    }

    /// The crystal's owner opens a lobby with it.
    function _openLobby(uint256 tokenId, uint64 stake) internal returns (uint256 lobbyId) {
        vm.prank(garden.ownerOf(tokenId));
        lobbyId = garden.openLobby(tokenId, stake);
    }

    /// The crystal's owner joins the lobby with it, and the duel is fought.
    function _join(uint256 lobbyId, uint256 tokenId) internal returns (uint256 duelId) {
        vm.prank(garden.ownerOf(tokenId));
        duelId = garden.joinLobby(lobbyId, tokenId);
    }

    /// `a` opens a lobby, `b` joins it.
    function _duel(uint256 a, uint256 b, uint64 stake) internal returns (uint256 duelId) {
        duelId = _join(_openLobby(a, stake), b);
    }

    function _cancel(uint256 lobbyId) internal {
        vm.prank(garden.ownerOf(garden.lobbyOf(lobbyId).crystal));
        garden.cancelLobby(lobbyId);
    }

    /// The stranger publishes the duel's outcome, with the proof of its public decryption, and returns it.
    function _publish(uint256 duelId) internal returns (bool creatorWon) {
        bytes memory proof;
        (creatorWon, proof) = decryptPublicWithSignatures(garden.duelOf(duelId).creatorWins);
        vm.prank(stranger);
        garden.publish(duelId, creatorWon, proof);
    }

    /// What the owner reads of the crystal's balance as of now: the credited MANA, decrypted, and what has accrued
    /// since.
    function _balanceOf(uint256 tokenId, uint256 ownerKey) internal returns (uint64) {
        Garden.CrystalView memory crystal = garden.crystalOf(tokenId);
        return decrypt(crystal.mana, address(garden), ownerKey) + crystal.pendingMana;
    }

    function _assertRecord(uint256 tokenId, uint32 wins, uint32 losses) internal view {
        (uint32 actualWins, uint32 actualLosses) = garden.recordOf(tokenId);
        assertEq(actualWins, wins, "wins");
        assertEq(actualLosses, losses, "losses");
    }

    /// RULES.md §7, as written there rather than as the contract computes it: Water beats Fire, Fire beats Earth,
    /// Earth beats Water.
    function _beats(uint8 x, uint8 y) internal pure returns (bool) {
        return (x == WATER && y == FIRE) || (x == FIRE && y == EARTH) || (x == EARTH && y == WATER);
    }

    /// What a season's pot holds, read with `plaintextOf` since nobody can decrypt it. 0 while its handle is empty:
    /// before anything is added to it, and once the season is closed.
    function _pot(uint256 season) internal returns (uint64) {
        euint64 pot = garden.potOf(season);
        return euint64.unwrap(pot) == 0 ? 0 : plaintextOf(pot);
    }

    /// Moves time and the block together, as on chain.
    function _wait(uint256 secs) internal {
        vm.warp(block.timestamp + secs);
        vm.roll(block.number + 1);
    }

    // -- Seasons --------------------------------------------------------------------------------------------

    /// When `season` ends: the deployment, then one season length per season.
    function _seasonEnd(uint256 season) internal view returns (uint256) {
        return garden.GENESIS() + season * SEASON_LENGTH;
    }

    /// Moves to the first moment `season` can be closed, a block later.
    function _waitUntilClosable(uint256 season) internal {
        vm.warp(_seasonEnd(season) + SEASON_CLOSE_DELAY);
        vm.roll(block.number + 1);
    }

    /// A stranger closes the season: anyone can.
    function _closeSeason(uint256 season) internal {
        vm.prank(stranger);
        garden.closeSeason(season);
    }

    /// The season's top three, best first, 0 for an empty place.
    function _top(uint256 season) internal view returns (uint256[3] memory crystals) {
        (crystals,,) = garden.rankingOf(season);
    }

    function _assertTop(uint256 season, uint256 first, uint256 second, uint256 third, string memory label)
        internal
        view
    {
        uint256[3] memory top = _top(season);
        assertEq(top[0], first, string.concat(label, ": first"));
        assertEq(top[1], second, string.concat(label, ": second"));
        assertEq(top[2], third, string.concat(label, ": third"));
    }

    /// What a closed season's pot pays the crystal in `place`, 0 for the first: the share's percent of the pot, rounded
    /// down (RULES.md §8).
    function _shareOf(uint256 pot, uint256 place) internal pure returns (uint64) {
        uint256 percent = place == 0 ? FIRST_SHARE : place == 1 ? SECOND_SHARE : THIRD_SHARE;
        return uint64(pot * percent / 100);
    }

    // -- Decryption checks ----------------------------------------------------------------------------------

    /// External, because `vm.expectRevert` only catches a revert that ends an external call. One name per type:
    /// every handle type is a bytes32 outside the contract, so external overloads would clash.
    function decryptUint8As(euint8 value, uint256 userKey) external returns (uint8) {
        return decrypt(value, address(garden), userKey);
    }

    function decryptUint64As(euint64 value, uint256 userKey) external returns (uint64) {
        return decrypt(value, address(garden), userKey);
    }

    function decryptUint8Publicly(euint8 value) external returns (uint8) {
        return decryptPublic(value);
    }

    function decryptUint64Publicly(euint64 value) external returns (uint64) {
        return decryptPublic(value);
    }

    function decryptBoolAs(ebool value, uint256 userKey) external returns (bool) {
        return decrypt(value, address(garden), userKey);
    }

    function decryptBoolPublicly(ebool value) external returns (bool) {
        return decryptPublic(value);
    }

    function _assertCannotDecrypt(euint8 value, address user, uint256 userKey) internal {
        _expectNotAuthorized(euint8.unwrap(value), user);
        this.decryptUint8As(value, userKey);
    }

    function _assertCannotDecrypt(euint64 value, address user, uint256 userKey) internal {
        _expectNotAuthorized(euint64.unwrap(value), user);
        this.decryptUint64As(value, userKey);
    }

    function _assertCannotDecrypt(ebool value, address user, uint256 userKey) internal {
        _expectNotAuthorized(ebool.unwrap(value), user);
        this.decryptBoolAs(value, userKey);
    }

    function _assertNotPublic(ebool value) internal {
        _expectNotPublic(ebool.unwrap(value));
        this.decryptBoolPublicly(value);
    }

    function _assertNotPublic(euint8 value) internal {
        _expectNotPublic(euint8.unwrap(value));
        this.decryptUint8Publicly(value);
    }

    function _assertNotPublic(euint64 value) internal {
        _expectNotPublic(euint64.unwrap(value));
        this.decryptUint64Publicly(value);
    }

    /// Named, so that a check cannot pass on an unrelated failure such as a malformed permit.
    function _expectNotAuthorized(bytes32 handle, address user) private {
        vm.expectRevert(
            abi.encodeWithSignature("CleartextErrorUserNotAuthorizedForDecrypt(bytes32,address)", handle, user)
        );
    }

    function _expectNotPublic(bytes32 handle) private {
        vm.expectRevert(abi.encodeWithSignature("CleartextErrorHandleNotAllowedForPublicDecryption(bytes32)", handle));
    }

    // -- What the ACL recorded ------------------------------------------------------------------------------

    /// Exactly these persistent grants, in any order, read from the ACL's `Allowed` events.
    function _assertGrants(Vm.Log[] memory logs, Grant[] memory expected) internal view {
        address acl = getCoprocessorConfig(address(garden)).ACLAddress;
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

    /// Every persistent grant went to `account`. Returns the handles granted, in order.
    function _assertGrantsOnlyTo(Vm.Log[] memory logs, address account) internal view returns (bytes32[] memory) {
        address acl = getCoprocessorConfig(address(garden)).ACLAddress;
        bytes32[] memory handles = new bytes32[](logs.length);
        uint256 grants;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != acl || logs[i].topics.length == 0 || logs[i].topics[0] != ACL_ALLOWED) continue;
            address grantee = address(uint160(uint256(logs[i].topics[2])));
            assertEq(grantee, account, string.concat("a grant to ", vm.toString(grantee)));
            handles[grants++] = abi.decode(logs[i].data, (bytes32));
        }
        assembly ("memory-safe") {
            mstore(handles, grants)
        }
        return handles;
    }

    /// No handle was made publicly decryptable (SEASON0.md §2.3, rule 4: only duel outcomes ever are).
    function _assertNothingPublic(Vm.Log[] memory logs) internal view {
        assertEq(_madePublic(logs).length, 0, "a handle was made publicly decryptable");
    }

    /// Every persistent grant, in order, read from the ACL's `Allowed` events.
    function _grantsIn(Vm.Log[] memory logs) internal view returns (Grant[] memory grants) {
        address acl = getCoprocessorConfig(address(garden)).ACLAddress;
        grants = new Grant[](logs.length);
        uint256 n;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != acl || logs[i].topics.length == 0 || logs[i].topics[0] != ACL_ALLOWED) continue;
            grants[n++] = Grant(address(uint160(uint256(logs[i].topics[2]))), abi.decode(logs[i].data, (bytes32)));
        }
        assembly ("memory-safe") {
            mstore(grants, n)
        }
    }

    /// Every handle made publicly decryptable, in order, read from the ACL's `AllowedForDecryption` events.
    function _madePublic(Vm.Log[] memory logs) internal view returns (bytes32[] memory revealed) {
        address acl = getCoprocessorConfig(address(garden)).ACLAddress;
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
    }

    // -- Who could make a handle ----------------------------------------------------------------------------

    /**
     * @dev Whether `account` could get `handle` in this transaction from what it holds and what anyone can make
     *      (SEASON0.md §2.2, Handles): it is allowed on the handle, or the handle was made in `logs` by an operation
     *      whose every encrypted operand is within its reach. Then it can repeat the operation through a contract of its
     *      own, get the same handle, and grant it to anyone. A plaintext operand and a trivial encryption are within
     *      anyone's reach, a random draw only within its maker's. A handle made before `logs` counts only if the account
     *      is allowed on it, so a test records the logs from before the crystals it looks at were forged, and then the
     *      only handle made earlier is GARDEN_ZERO, drawn at the deployment.
     */
    function _withinReach(Vm.Log[] memory logs, bytes32 handle, address account) internal returns (bool) {
        if (IAcl(getCoprocessorConfig(address(garden)).ACLAddress).isAllowed(handle, account)) return true;
        address executor = getCoprocessorConfig(address(garden)).CoprocessorAddress;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != executor || logs[i].topics.length == 0) continue;
            bytes32 topic = logs[i].topics[0];
            bytes memory data = logs[i].data;
            if (_takesTwo(topic)) {
                (bytes32 lhs, bytes32 rhs, bytes1 scalar, bytes32 result) =
                    abi.decode(data, (bytes32, bytes32, bytes1, bytes32));
                if (result != handle) continue;
                return _withinReach(logs, lhs, account) && (scalar == 0x01 || _withinReach(logs, rhs, account));
            }
            if (topic == FHE_CAST) {
                (bytes32 operand,, bytes32 result) = abi.decode(data, (bytes32, uint8, bytes32));
                if (result == handle) return _withinReach(logs, operand, account);
            } else if (topic == FHE_NEG || topic == FHE_NOT) {
                (bytes32 operand, bytes32 result) = abi.decode(data, (bytes32, bytes32));
                if (result == handle) return _withinReach(logs, operand, account);
            } else if (topic == FHE_SELECT) {
                (bytes32 control, bytes32 ifTrue, bytes32 ifFalse, bytes32 result) =
                    abi.decode(data, (bytes32, bytes32, bytes32, bytes32));
                if (result == handle) {
                    return _withinReach(logs, control, account) && _withinReach(logs, ifTrue, account)
                        && _withinReach(logs, ifFalse, account);
                }
            } else if (topic == FHE_IS_IN) {
                (bytes32 value, bytes32[] memory values, bytes32 result) = abi.decode(data, (bytes32, bytes32[], bytes32));
                if (result == handle) return _withinReach(logs, value, account) && _allWithinReach(logs, values, account);
            } else if (topic == FHE_SUM) {
                (bytes32[] memory values, bytes32 result) = abi.decode(data, (bytes32[], bytes32));
                if (result == handle) return _allWithinReach(logs, values, account);
            } else if (topic == TRIVIAL_ENCRYPT) {
                (,, bytes32 result) = abi.decode(data, (uint256, uint8, bytes32));
                if (result == handle) return true;
            } else if (topic == FHE_RAND) {
                (,, bytes32 result) = abi.decode(data, (uint8, bytes16, bytes32));
                if (result == handle) return false;
            } else if (topic == FHE_RAND_BOUNDED) {
                (,,, bytes32 result) = abi.decode(data, (uint256, uint8, bytes16, bytes32));
                if (result == handle) return false;
            }
        }
        return false;
    }

    function _allWithinReach(Vm.Log[] memory logs, bytes32[] memory handles, address account) internal returns (bool) {
        for (uint256 i; i < handles.length; i++) {
            if (!_withinReach(logs, handles[i], account)) return false;
        }
        return true;
    }

    /// Whether the executor's event is one of its operations on two operands, the second a plaintext when its scalar
    /// byte is 1.
    function _takesTwo(bytes32 topic) internal pure returns (bool) {
        string[20] memory names = [
            "FheAdd", "FheBitAnd", "FheBitOr", "FheBitXor", "FheDiv", "FheEq", "FheGe", "FheGt", "FheLe", "FheLt",
            "FheMax", "FheMin", "FheMul", "FheNe", "FheRem", "FheRotl", "FheRotr", "FheShl", "FheShr", "FheSub"
        ];
        for (uint256 i; i < names.length; i++) {
            if (topic == keccak256(bytes(string.concat(names[i], "(address,bytes32,bytes32,bytes1,bytes32)")))) {
                return true;
            }
        }
        return false;
    }

    // -- What an outsider sees ------------------------------------------------------------------------------

    /**
     * @dev The logs of a call as an outsider can compare them with another run's: every handle masked, in the topics
     *      and in every word of the data, since handles differ between any two runs whatever the secrets. Everything
     *      else stays and must match: emitters, events, accounts granted, scalar operands, plaintexts encrypted, sizes.
     *      An imported input's handle and proof are masked too: they sit in the calldata, and every encryption makes
     *      new ones, whatever it encrypts. Masked as soon as the call is observed, because reverting to a snapshot later
     *      takes the test library's plaintexts with it, and with them the means to tell a handle.
     */
    function _masked(Vm.Log[] memory logs) internal returns (Vm.Log[] memory) {
        for (uint256 i; i < logs.length; i++) {
            bytes32[] memory topics = logs[i].topics;
            for (uint256 j; j < topics.length; j++) {
                topics[j] = _maskHandle(topics[j]);
            }
            if (topics.length > 0 && topics[0] == VERIFY_INPUT) {
                (, address user, bytes memory proof, uint8 inputType,) =
                    abi.decode(logs[i].data, (bytes32, address, bytes, uint8, bytes32));
                logs[i].data = abi.encode(HANDLE, user, new bytes(proof.length), inputType, HANDLE);
                continue;
            }
            bytes memory data = logs[i].data;
            for (uint256 offset; offset + 32 <= data.length; offset += 32) {
                bytes32 word;
                assembly ("memory-safe") {
                    word := mload(add(add(data, 32), offset))
                }
                word = _maskHandle(word);
                assembly ("memory-safe") {
                    mstore(add(add(data, 32), offset), word)
                }
            }
        }
        return logs;
    }

    /// The values now in these slots of Garden's storage, every handle masked.
    function _maskedValues(bytes32[] memory slots) internal returns (bytes32[] memory values) {
        values = new bytes32[](slots.length);
        for (uint256 i; i < slots.length; i++) {
            values[i] = _maskHandle(vm.load(address(garden), slots[i]));
        }
    }

    /// HANDLE if the word is a handle the test library holds a plaintext for, the word itself otherwise.
    function _maskHandle(bytes32 word) internal returns (bytes32) {
        return word != 0 && hasPlaintext(ebool.wrap(word)) ? HANDLE : word;
    }

    /// Two masked runs look the same from outside: the same logs, in order, equal in everything but handles.
    function _assertSameLogs(Vm.Log[] memory a, Vm.Log[] memory b) internal pure {
        assertEq(a.length, b.length, "number of logs");
        for (uint256 i; i < a.length; i++) {
            string memory at = string.concat("log ", vm.toString(i));
            assertEq(a[i].emitter, b[i].emitter, string.concat(at, ": emitter"));
            assertEq(a[i].topics, b[i].topics, string.concat(at, ": topics"));
            assertEq(a[i].data, b[i].data, string.concat(at, ": data"));
        }
    }

    function _grant(address account, euint8 handle) internal pure returns (Grant memory) {
        return Grant(account, euint8.unwrap(handle));
    }

    function _grant(address account, euint64 handle) internal pure returns (Grant memory) {
        return Grant(account, euint64.unwrap(handle));
    }

    function _grant(address account, ebool handle) internal pure returns (Grant memory) {
        return Grant(account, ebool.unwrap(handle));
    }

    function _name(uint256 element) internal pure returns (string memory) {
        return element == FIRE ? "Fire" : element == EARTH ? "Earth" : "Water";
    }
}
