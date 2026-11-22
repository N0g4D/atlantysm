// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ebool, euint8, euint64, externalEbool} from "@fhevm/solidity/lib/FHE.sol";
import {TestFhevm} from "@fhevm/forge/TestFhevm.sol";
import {Vm} from "forge-std/Vm.sol";
import {Garden} from "../../src/Garden.sol";

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

    uint8 internal constant FIRE = 0;
    uint8 internal constant EARTH = 1;
    uint8 internal constant WATER = 2;

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
            maxLevel: MAX_LEVEL
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

    /// What a season's pot holds, read with `plaintextOf` since nobody can decrypt it. 0 while its handle is still
    /// empty, before any crystal attunes or is shattered in that season.
    function _pot(uint256 season) internal returns (uint64) {
        euint64 pot = garden.potOf(season);
        return euint64.unwrap(pot) == 0 ? 0 : plaintextOf(pot);
    }

    /// Moves time and the block together, as on chain.
    function _wait(uint256 secs) internal {
        vm.warp(block.timestamp + secs);
        vm.roll(block.number + 1);
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

    function _assertCannotDecrypt(euint8 value, address user, uint256 userKey) internal {
        _expectNotAuthorized(euint8.unwrap(value), user);
        this.decryptUint8As(value, userKey);
    }

    function _assertCannotDecrypt(euint64 value, address user, uint256 userKey) internal {
        _expectNotAuthorized(euint64.unwrap(value), user);
        this.decryptUint64As(value, userKey);
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
        address acl = getCoprocessorConfig(address(garden)).ACLAddress;
        for (uint256 i; i < logs.length; i++) {
            bool reveal = logs[i].emitter == acl && logs[i].topics.length > 0 && logs[i].topics[0] == ACL_PUBLIC;
            assertFalse(reveal, "a handle was made publicly decryptable");
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
