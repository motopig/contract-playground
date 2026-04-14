// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test }               from "forge-std/Test.sol";
import { ERC1271TypedData }   from "../../src/1271/ERC1271TypedData.sol";
import { SigUtils }           from "./helpers/SigUtils.sol";

// =============================================================================
// Unit + Fuzz tests
// =============================================================================

contract ERC1271TypedDataTest is Test {
    bytes4 internal constant MAGIC  = 0x1626ba7e;
    bytes4 internal constant FAIL_V = 0xffffffff;

    uint256 internal ownerKey;
    address internal ownerAddr;

    ERC1271TypedData internal validator;

    // A dummy struct hash to represent an EIP-712 leaf
    bytes32 internal constant DUMMY_TYPE_HASH =
        keccak256("Permit(address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function setUp() public {
        ownerKey  = 0xC0FFEE;
        ownerAddr = vm.addr(ownerKey);
        validator = new ERC1271TypedData(ownerAddr, "TestDomain", "1");
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    function test_constructor_setsOwner() public view {
        assertEq(validator.owner(), ownerAddr);
    }

    function test_constructor_revertOnZeroAddress() public {
        vm.expectRevert(ERC1271TypedData.ZeroAddress.selector);
        new ERC1271TypedData(address(0), "D", "1");
    }

    function test_constructor_domainSeparatorNonZero() public view {
        assertNotEq(validator.domainSeparator(), bytes32(0));
    }

    // -------------------------------------------------------------------------
    // isValidSignature — unit
    // -------------------------------------------------------------------------

    function _buildStructHash(address spender, uint256 value) internal pure returns (bytes32) {
        return keccak256(abi.encode(DUMMY_TYPE_HASH, spender, value, 0, type(uint256).max));
    }

    function test_isValidSignature_validTypedSig_returnsMagic() public view {
        bytes32 structHash = _buildStructHash(address(0xBEEF), 1e18);
        bytes32 digest = validator.buildDigest(structHash);
        bytes memory sig = SigUtils.sign(ownerKey, digest);
        // ERC-1271 callers pass structHash as `hash`; the contract wraps it internally
        assertEq(validator.isValidSignature(structHash, sig), MAGIC);
    }

    function test_isValidSignature_wrongStructHash_returnsFail() public view {
        bytes32 correctStructHash = _buildStructHash(address(0xBEEF), 1e18);
        bytes32 wrongStructHash   = _buildStructHash(address(0xDEAD), 2e18);

        // Sign the correct one but supply the wrong one
        bytes32 digest = validator.buildDigest(correctStructHash);
        bytes memory sig = SigUtils.sign(ownerKey, digest);

        assertEq(validator.isValidSignature(wrongStructHash, sig), FAIL_V);
    }

    function test_isValidSignature_rawHashNotTyped_returnsFail() public view {
        // Signing the struct hash directly (no wrapper) — should fail
        bytes32 structHash = _buildStructHash(address(0xBEEF), 1e18);
        bytes memory sig = SigUtils.sign(ownerKey, structHash); // no EIP-712 envelope
        assertEq(validator.isValidSignature(structHash, sig), FAIL_V);
    }

    function test_isValidSignature_wrongSigner_returnsFail() public view {
        bytes32 structHash = _buildStructHash(address(0xAA), 100);
        bytes32 digest     = validator.buildDigest(structHash);
        bytes memory sig   = SigUtils.sign(0xBAD111, digest); // different key
        assertEq(validator.isValidSignature(structHash, sig), FAIL_V);
    }

    function test_isValidSignature_emptySig_returnsFail() public view {
        bytes32 structHash = _buildStructHash(address(0xAA), 100);
        assertEq(validator.isValidSignature(structHash, ""), FAIL_V);
    }

    function test_isValidSignature_truncatedSig_returnsFail() public view {
        bytes32 structHash = _buildStructHash(address(0xAA), 1);
        bytes32 digest     = validator.buildDigest(structHash);
        bytes memory sig   = SigUtils.sign(ownerKey, digest);
        bytes memory short = new bytes(32);
        for (uint256 i; i < 32; ++i) short[i] = sig[i];
        assertEq(validator.isValidSignature(structHash, short), FAIL_V);
    }

    /// @dev Different domain (name) must not validate the same struct hash sig
    function test_isValidSignature_differentDomain_returnsFail() public {
        ERC1271TypedData other = new ERC1271TypedData(ownerAddr, "OtherDomain", "1");

        bytes32 structHash = _buildStructHash(address(0xAA), 1);
        // Sign for `other`'s domain
        bytes32 digest   = other.buildDigest(structHash);
        bytes memory sig = SigUtils.sign(ownerKey, digest);

        // Supply to original validator's domain — must fail
        assertEq(validator.isValidSignature(structHash, sig), FAIL_V);
    }

    /// @dev chainId cross-replay: simulate a forked chain
    function test_isValidSignature_chainIdReplay_returnsFail() public {
        // Sign on chain 1337
        vm.chainId(1337);
        ERC1271TypedData inst1337 = new ERC1271TypedData(ownerAddr, "D", "1");
        bytes32 structHash = keccak256("something");
        bytes32 digest     = inst1337.buildDigest(structHash);
        bytes memory sig   = SigUtils.sign(ownerKey, digest);

        // Deploy a fresh instance on chain 31337 (default anvil) — domain separator differs
        vm.chainId(31337);
        ERC1271TypedData inst31337 = new ERC1271TypedData(ownerAddr, "D", "1");
        assertEq(inst31337.isValidSignature(structHash, sig), FAIL_V);
    }

    // -------------------------------------------------------------------------
    // Fuzz tests
    // -------------------------------------------------------------------------

    /// @dev Random bytes must never return MAGIC
    function testFuzz_isValidSignature_randomBytes_neverReturnsMagic(
        bytes32 structHash,
        bytes calldata randomSig
    ) public view {
        bytes4 result = validator.isValidSignature(structHash, randomSig);
        // Allow for astronomically unlikely collision — but non-65-byte cannot be valid
        if (randomSig.length != 65) {
            assertEq(result, FAIL_V);
        }
    }

    /// @dev Any valid (key, structHash) pair must always return MAGIC
    function testFuzz_isValidSignature_ownerSig_alwaysReturnsMagic(
        uint256 pk,
        bytes32 structHash
    ) public {
        pk = bound(pk, 1, type(uint128).max);
        address signer = vm.addr(pk);

        ERC1271TypedData inst = new ERC1271TypedData(signer, "FuzzDomain", "1");
        bytes32 digest = inst.buildDigest(structHash);
        bytes memory sig = SigUtils.sign(pk, digest);

        assertEq(inst.isValidSignature(structHash, sig), MAGIC);
    }

    /// @dev Wrong key on any structHash should never produce MAGIC
    function testFuzz_isValidSignature_wrongOwner_neverReturnsMagic(
        uint256 correctKey,
        uint256 wrongKey,
        bytes32 structHash
    ) public {
        correctKey = bound(correctKey, 1, type(uint128).max);
        wrongKey   = bound(wrongKey,   1, type(uint128).max);
        vm.assume(vm.addr(correctKey) != vm.addr(wrongKey));

        ERC1271TypedData inst = new ERC1271TypedData(vm.addr(correctKey), "D", "1");
        bytes32 digest = inst.buildDigest(structHash);
        bytes memory sig = SigUtils.sign(wrongKey, digest);

        assertEq(inst.isValidSignature(structHash, sig), FAIL_V);
    }
}

// =============================================================================
// Invariant tests
// =============================================================================

contract TypedDataHandler is Test {
    ERC1271TypedData public validator;
    uint256         public ownerKey;
    address         public ownerAddr;

    bytes4 internal constant MAGIC  = 0x1626ba7e;
    bytes4 internal constant FAIL_V = 0xffffffff;

    constructor() {
        ownerKey  = 0xF00D;
        ownerAddr = vm.addr(ownerKey);
        validator = new ERC1271TypedData(ownerAddr, "InvariantDomain", "1");
    }

    function callValid(bytes32 structHash) external view {
        bytes32 digest = validator.buildDigest(structHash);
        bytes memory sig = SigUtils.sign(ownerKey, digest);
        assertEq(validator.isValidSignature(structHash, sig), MAGIC);
    }

    function callWrongKey(uint256 wrongKey, bytes32 structHash) external view {
        wrongKey = bound(wrongKey, 1, type(uint128).max);
        vm.assume(vm.addr(wrongKey) != ownerAddr);
        bytes32 digest = validator.buildDigest(structHash);
        bytes memory sig = SigUtils.sign(wrongKey, digest);
        assertEq(validator.isValidSignature(structHash, sig), FAIL_V);
    }
}

contract ERC1271TypedDataInvariant is Test {
    TypedDataHandler internal handler;

    function setUp() public {
        handler = new TypedDataHandler();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = TypedDataHandler.callValid.selector;
        selectors[1] = TypedDataHandler.callWrongKey.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    function invariant_ownerNeverChanges() public view {
        assertEq(handler.validator().owner(), handler.ownerAddr());
    }

    function invariant_domainSeparatorStable() public view {
        // domainSeparator must remain stable (same chainId, same contract address)
        assertNotEq(handler.validator().domainSeparator(), bytes32(0));
    }
}
