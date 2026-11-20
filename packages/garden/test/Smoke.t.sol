// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FHE, euint64, externalEuint64} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {TestFhevm} from "@fhevm/forge/TestFhevm.sol";
import {FhevmHCUMeter} from "@fhevm/forge/FhevmVm.sol";

/**
 * @dev The smallest contract that takes the path every Garden write will take: an input the client
 *      encrypted for this contract and this sender, a computation that chooses with `FHE.select` instead
 *      of branching on the secret (SEASON0.md §2.3, rule 1), and a result that only the contract and the
 *      sender may use (rule 5).
 */
contract SmokePurse is ZamaEthereumConfig {
    /// Public, so it stays a plaintext operand: only values that are public anyway are ever encrypted.
    uint64 public constant PRICE = 10;

    mapping(address owner => euint64) public balanceOf;

    /// Keeps `amount - PRICE` when the amount covers the price, and the whole amount when it does not.
    function pay(externalEuint64 amount, bytes calldata proof) external {
        euint64 value = FHE.fromExternal(amount, proof);
        // Both sides are computed; the subtraction wraps when the amount is short, and select discards it.
        euint64 left = FHE.select(FHE.ge(value, PRICE), FHE.sub(value, PRICE), value);
        FHE.allowThis(left);
        FHE.allow(left, msg.sender);
        balanceOf[msg.sender] = left;
    }
}

/// Proves the toolchain end to end: encrypt an input, compute on it, decrypt the result.
contract SmokeTest is TestFhevm {
    // SEASON0.md §2.3, rule 7: every function stays below half of each protocol cap.
    uint256 internal constant HCU_PER_TX_BUDGET = 20_000_000 / 2;
    uint256 internal constant HCU_DEPTH_BUDGET = 5_000_000 / 2;

    SmokePurse internal purse;
    address internal alice;
    uint256 internal aliceKey;
    address internal bob;
    uint256 internal bobKey;

    function setUp() public override {
        super.setUp();
        purse = new SmokePurse();
        (alice, aliceKey) = makeAddrAndKey("alice");
        (bob, bobKey) = makeAddrAndKey("bob");
    }

    function testTheSenderDecryptsTheResult() public {
        _pay(alice, 42);
        assertEq(decrypt(purse.balanceOf(alice), address(purse), aliceKey), 32);
    }

    function testSelectKeepsAnAmountThatCannotPay() public {
        _pay(alice, 7);
        assertEq(decrypt(purse.balanceOf(alice), address(purse), aliceKey), 7);
    }

    function testAStrangerCannotDecrypt() public {
        _pay(alice, 42);
        euint64 balance = purse.balanceOf(alice);

        // Named, so the test cannot pass on an unrelated failure such as a malformed permit.
        vm.expectRevert(
            abi.encodeWithSignature(
                "CleartextErrorUserNotAuthorizedForDecrypt(bytes32,address)", euint64.unwrap(balance), bob
            )
        );
        this.decryptAs(balance, bobKey);
    }

    function testHcuIsMeteredAndWithinBudget() public {
        _pay(alice, 42);
        FhevmHCUMeter memory hcu = lastHCU();

        emit log_named_uint("pay: HCU per transaction", hcu.transaction);
        emit log_named_uint("pay: HCU depth", hcu.maxHandle);
        assertGt(hcu.transaction, 0);
        assertLt(hcu.transaction, HCU_PER_TX_BUDGET);
        assertLt(hcu.maxHandle, HCU_DEPTH_BUDGET);
    }

    /// External, because `vm.expectRevert` only catches a revert that ends an external call.
    function decryptAs(euint64 value, uint256 userKey) external returns (uint64) {
        return decrypt(value, address(purse), userKey);
    }

    function _pay(address user, uint64 amount) internal {
        (externalEuint64 input, bytes memory proof) = encryptUint64(amount, address(purse), user);
        // A forge test is one transaction, so the HCU meter accumulates across calls. Resetting here makes
        // `lastHCU()` read this call alone. It comes before the prank, which only covers the next call.
        resetHCU();
        vm.prank(user);
        purse.pay(input, proof);
    }
}
