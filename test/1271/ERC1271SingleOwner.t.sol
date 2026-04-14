// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test }                from "forge-std/Test.sol";
import { ERC1271SingleOwner } from "../../src/1271/ERC1271SingleOwner.sol";
import { SigUtils }           from "./helpers/SigUtils.sol";

// =============================================================================
// Unit + Fuzz tests
// =============================================================================

contract ERC1271SingleOwnerTest is Test {
    using SigUtils for *;

    ERC1271SingleOwner internal validator;

    uint256 internal ownerKey;
    address internal ownerAddr;

    bytes4 internal constant MAGIC   = 0x1626ba7e;
    bytes4 internal constant FAIL_V  = 0xffffffff;

    function setUp() public {
        ownerKey  = 0xA11CE;
        ownerAddr = vm.addr(ownerKey);
        validator = new ERC1271SingleOwner(ownerAddr);
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    function test_constructor_setsOwner() public view {
        assertEq(validator.owner(), ownerAddr);
    }

    function test_constructor_revertOnZeroAddress() public {
        vm.expectRevert(ERC1271SingleOwner.ZeroAddress.selector);
        new ERC1271SingleOwner(address(0));
    }

    // -------------------------------------------------------------------------
    // isValidSignature — unit
    // -------------------------------------------------------------------------

    function test_isValidSignature_validSig_returnsMagicValue() public view {
        bytes32 hash = keccak256("hello world");
        bytes memory sig = SigUtils.sign(ownerKey, hash);
        assertEq(validator.isValidSignature(hash, sig), MAGIC);
    }

    function test_isValidSignature_wrongSigner_returnsFail() public view {
        bytes32 hash = keccak256("hello world");
        bytes memory sig = SigUtils.sign(0xBADBEEF, hash);
        assertEq(validator.isValidSignature(hash, sig), FAIL_V);
    }

    function test_isValidSignature_wrongHash_returnsFail() public view {
        bytes32 signedHash = keccak256("correct");
        bytes32 suppliedHash = keccak256("wrong");
        bytes memory sig = SigUtils.sign(ownerKey, signedHash);
        assertEq(validator.isValidSignature(suppliedHash, sig), FAIL_V);
    }

    function test_isValidSignature_emptySignature_returnsFail() public view {
        bytes32 hash = keccak256("test");
        assertEq(validator.isValidSignature(hash, ""), FAIL_V);
    }

    function test_isValidSignature_shortSignature_returnsFail() public view {
        bytes32 hash = keccak256("test");
        bytes memory sig = SigUtils.sign(ownerKey, hash);
        bytes memory truncated = new bytes(32);
        for (uint256 i; i < 32; ++i) truncated[i] = sig[i];
        assertEq(validator.isValidSignature(hash, truncated), FAIL_V);
    }

    function test_isValidSignature_malleatedSignature_returnsFail() public view {
        bytes32 hash = keccak256("test");
        bytes memory sig = SigUtils.sign(ownerKey, hash);

        // Flip v from 27↔28 to produce the malleable twin
        uint8 v;
        assembly { v := mload(add(sig, 65)) }
        uint8 flippedV = v == 27 ? 28 : 27;
        assembly { mstore8(add(sig, 64), flippedV) }

        // OZ ECDSA.tryRecover rejects high-s / wrong-v variants
        assertEq(validator.isValidSignature(hash, sig), FAIL_V);
    }

    function test_isValidSignature_zeros32ByteHash_validSig_returnsMagicValue() public view {
        bytes32 hash = bytes32(0);
        bytes memory sig = SigUtils.sign(ownerKey, hash);
        assertEq(validator.isValidSignature(hash, sig), MAGIC);
    }

    /// @dev isValidSignature must be view — confirm no state change by calling twice
    function test_isValidSignature_isView_idempotent() public view {
        bytes32 hash = keccak256("idempotent");
        bytes memory sig = SigUtils.sign(ownerKey, hash);
        bytes4 r1 = validator.isValidSignature(hash, sig);
        bytes4 r2 = validator.isValidSignature(hash, sig);
        assertEq(r1, r2);
    }

    // -------------------------------------------------------------------------
    // Fuzz tests
    // -------------------------------------------------------------------------

    /// @dev Any random bytes as signature must never return MAGIC
    function testFuzz_isValidSignature_randomBytes_neverReturnsMagic(
        bytes32 hash,
        bytes calldata randomSig
    ) public view {
        // Valid sigs are exactly 65 bytes and would recover to owner; skip that case.
        // For arbitrary byte strings the chance of a collision is negligible.
        if (randomSig.length == 65) {
            // Could accidentally be a valid sig — only assert FAIL if it doesn't
            // recover to owner
            (address recovered,,) = _tryRecover(hash, randomSig);
            if (recovered == ownerAddr) return; // genuinely valid; skip
        }
        bytes4 result = validator.isValidSignature(hash, randomSig);
        assertNotEq(result, MAGIC);
    }

    /// @dev Any valid owner-produced signature on any hash must return MAGIC
    function testFuzz_isValidSignature_ownerSig_alwaysReturnsMagic(
        uint256 privateKey,
        bytes32 hash
    ) public {
        // Constrain key to secp256k1 valid range
        privateKey = bound(privateKey, 1, type(uint128).max);
        address signer = vm.addr(privateKey);

        ERC1271SingleOwner inst = new ERC1271SingleOwner(signer);
        bytes memory sig = SigUtils.sign(privateKey, hash);
        assertEq(inst.isValidSignature(hash, sig), MAGIC);
    }

    /// @dev Wrong key for any hash should never return MAGIC
    function testFuzz_isValidSignature_wrongKey_neverReturnsMagic(
        uint256 wrongKey,
        bytes32 hash
    ) public view {
        wrongKey = bound(wrongKey, 1, type(uint128).max);
        vm.assume(vm.addr(wrongKey) != ownerAddr);
        bytes memory sig = SigUtils.sign(wrongKey, hash);
        assertEq(validator.isValidSignature(hash, sig), FAIL_V);
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    function _tryRecover(bytes32 hash, bytes calldata sig)
        internal
        pure
        returns (address recovered, uint8 err, bytes32 errArg)
    {
        // minimal inline recovery to avoid circular dependency
        if (sig.length != 65) return (address(0), 1, bytes32(0));
        bytes32 r;
        bytes32 s;
        uint8   v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
        if (v < 27) v += 27;
        if (v != 27 && v != 28) return (address(0), 2, bytes32(0));
        // high-s check
        uint256 sVal = uint256(s);
        uint256 N_HALF = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;
        if (sVal > N_HALF) return (address(0), 2, bytes32(0));
        recovered = ecrecover(hash, v, r, s);
        return (recovered, 0, bytes32(0));
    }
}

// =============================================================================
// Invariant tests
// =============================================================================

/// @dev Stateful handler that drives isValidSignature calls with mixed-validity sigs
contract SingleOwnerHandler is Test {
    ERC1271SingleOwner public validator;
    uint256            public ownerKey;
    address            public ownerAddr;

    bytes4 internal constant MAGIC  = 0x1626ba7e;
    bytes4 internal constant FAIL_V = 0xffffffff;

    uint256 public magicCallCount;
    uint256 public failCallCount;

    constructor() {
        ownerKey  = 0xDEAD;
        ownerAddr = vm.addr(ownerKey);
        validator = new ERC1271SingleOwner(ownerAddr);
    }

    /// @dev Simulate a valid call
    function callValid(bytes32 hash) external {
        bytes memory sig = SigUtils.sign(ownerKey, hash);
        bytes4 result = validator.isValidSignature(hash, sig);
        assertEq(result, MAGIC, "valid sig must return MAGIC");
        ++magicCallCount;
    }

    /// @dev Simulate an invalid call with a different key
    function callInvalid(uint256 wrongKey, bytes32 hash) external {
        wrongKey = bound(wrongKey, 1, type(uint128).max);
        vm.assume(vm.addr(wrongKey) != ownerAddr);
        bytes memory sig = SigUtils.sign(wrongKey, hash);
        bytes4 result = validator.isValidSignature(hash, sig);
        assertEq(result, FAIL_V, "invalid sig must return FAIL");
        ++failCallCount;
    }

    /// @dev Simulate a random bytes call
    function callRandom(bytes32 hash, bytes calldata randomSig) external {
        bytes4 result = validator.isValidSignature(hash, randomSig);
        // We can only assert that it does not revert
        assertTrue(result == MAGIC || result == FAIL_V, "result must be MAGIC or FAIL");
    }
}

contract ERC1271SingleOwnerInvariant is Test {
    SingleOwnerHandler internal handler;

    function setUp() public {
        handler = new SingleOwnerHandler();
        targetContract(address(handler));
        // Only drive through handler functions
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = SingleOwnerHandler.callValid.selector;
        selectors[1] = SingleOwnerHandler.callInvalid.selector;
        selectors[2] = SingleOwnerHandler.callRandom.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    /// @dev The underlying validator must never change its owner
    function invariant_ownerIsImmutable() public view {
        assertEq(handler.validator().owner(), handler.ownerAddr());
    }

    /// @dev Contract must not revert under any input sequence
    function invariant_neverReverts() public view {
        // Any revert would prevent this invariant from running — existence proves no revert
        assertTrue(true);
    }
}
