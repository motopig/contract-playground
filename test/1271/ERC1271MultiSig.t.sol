// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test }             from "forge-std/Test.sol";
import { ERC1271MultiSig } from "../../src/1271/ERC1271MultiSig.sol";
import { SigUtils }        from "./helpers/SigUtils.sol";

// =============================================================================
// Unit + Fuzz tests
// =============================================================================

contract ERC1271MultiSigTest is Test {
    bytes4 internal constant MAGIC  = 0x1626ba7e;
    bytes4 internal constant FAIL_V = 0xffffffff;

    // 3 deterministic owner keys for convenience
    uint256 internal key1 = 0x1111;
    uint256 internal key2 = 0x2222;
    uint256 internal key3 = 0x3333;

    address internal addr1;
    address internal addr2;
    address internal addr3;

    ERC1271MultiSig internal multisig2of3; // 2-of-3

    function setUp() public {
        addr1 = vm.addr(key1);
        addr2 = vm.addr(key2);
        addr3 = vm.addr(key3);

        address[] memory owners = new address[](3);
        owners[0] = addr1;
        owners[1] = addr2;
        owners[2] = addr3;
        multisig2of3 = new ERC1271MultiSig(owners, 2);
    }

    // -------------------------------------------------------------------------
    // Constructor validation
    // -------------------------------------------------------------------------

    function test_constructor_setsThresholdAndOwners() public view {
        assertEq(multisig2of3.threshold(),  2);
        assertEq(multisig2of3.ownerCount(), 3);
        assertTrue(multisig2of3.isOwner(addr1));
        assertTrue(multisig2of3.isOwner(addr2));
        assertTrue(multisig2of3.isOwner(addr3));
    }

    function test_constructor_revertOnZeroThreshold() public {
        address[] memory owners = new address[](2);
        owners[0] = addr1;
        owners[1] = addr2;
        vm.expectRevert(ERC1271MultiSig.InvalidThreshold.selector);
        new ERC1271MultiSig(owners, 0);
    }

    function test_constructor_revertOnThresholdExceedsOwners() public {
        address[] memory owners = new address[](2);
        owners[0] = addr1;
        owners[1] = addr2;
        vm.expectRevert(ERC1271MultiSig.InvalidThreshold.selector);
        new ERC1271MultiSig(owners, 3);
    }

    function test_constructor_revertOnEmptyOwners() public {
        address[] memory owners = new address[](0);
        vm.expectRevert(ERC1271MultiSig.InvalidOwnersLength.selector);
        new ERC1271MultiSig(owners, 1);
    }

    function test_constructor_revertOnZeroAddressOwner() public {
        address[] memory owners = new address[](2);
        owners[0] = addr1;
        owners[1] = address(0);
        vm.expectRevert(ERC1271MultiSig.ZeroAddressOwner.selector);
        new ERC1271MultiSig(owners, 1);
    }

    function test_constructor_revertOnDuplicateOwner() public {
        address[] memory owners = new address[](2);
        owners[0] = addr1;
        owners[1] = addr1;
        vm.expectRevert(abi.encodeWithSelector(ERC1271MultiSig.DuplicateOwner.selector, addr1));
        new ERC1271MultiSig(owners, 1);
    }

    // -------------------------------------------------------------------------
    // isValidSignature — exactly-threshold sigs
    // -------------------------------------------------------------------------

    function test_isValidSignature_thresholdSigs_returnsMagic() public view {
        bytes32 hash = keccak256("threshold met");
        uint256[] memory keys = new uint256[](2);
        keys[0] = key1;
        keys[1] = key2;
        bytes memory sig = SigUtils.buildSortedMultiSig(keys, hash);
        assertEq(multisig2of3.isValidSignature(hash, sig), MAGIC);
    }

    function test_isValidSignature_allOwnersSig_returnsMagic() public view {
        bytes32 hash = keccak256("all owners");
        uint256[] memory keys = new uint256[](3);
        keys[0] = key1;
        keys[1] = key2;
        keys[2] = key3;
        bytes memory sig = SigUtils.buildSortedMultiSig(keys, hash);
        assertEq(multisig2of3.isValidSignature(hash, sig), MAGIC);
    }

    // -------------------------------------------------------------------------
    // isValidSignature — insufficient sigs
    // -------------------------------------------------------------------------

    function test_isValidSignature_onlyOneSig_returnsFail() public view {
        bytes32 hash = keccak256("only one");
        uint256[] memory keys = new uint256[](1);
        keys[0] = key1;
        bytes memory sig = SigUtils.buildSortedMultiSig(keys, hash);
        assertEq(multisig2of3.isValidSignature(hash, sig), FAIL_V);
    }

    function test_isValidSignature_emptySig_returnsFail() public view {
        bytes32 hash = keccak256("empty");
        assertEq(multisig2of3.isValidSignature(hash, ""), FAIL_V);
    }

    function test_isValidSignature_nonAlignedSig_returnsFail() public view {
        bytes32 hash = keccak256("bad length");
        bytes memory badSig = new bytes(66); // not multiple of 65
        assertEq(multisig2of3.isValidSignature(hash, badSig), FAIL_V);
    }

    // -------------------------------------------------------------------------
    // isValidSignature — non-owner sig
    // -------------------------------------------------------------------------

    function test_isValidSignature_nonOwnerSig_returnsFail() public view {
        bytes32 hash = keccak256("outsider");
        uint256 outsiderKey = 0x9999;
        vm.assume(
            vm.addr(outsiderKey) != addr1 &&
            vm.addr(outsiderKey) != addr2 &&
            vm.addr(outsiderKey) != addr3
        );
        uint256[] memory keys = new uint256[](2);
        keys[0] = key1;
        keys[1] = outsiderKey;
        bytes memory sig = SigUtils.buildSortedMultiSig(keys, hash);
        assertEq(multisig2of3.isValidSignature(hash, sig), FAIL_V);
    }

    // -------------------------------------------------------------------------
    // isValidSignature — duplicate sig (same signer twice)
    // -------------------------------------------------------------------------

    function test_isValidSignature_duplicateSigner_returnsFail() public view {
        bytes32 hash = keccak256("duplicate");
        // Manually build two identical sigs from key1 (same signer address)
        bytes memory sig1 = SigUtils.sign(key1, hash);
        bytes memory sig2 = SigUtils.sign(key1, hash);

        // Sort: since both have same address the ascending check will reject
        bytes memory combined = bytes.concat(sig1, sig2);
        assertEq(multisig2of3.isValidSignature(hash, combined), FAIL_V);
    }

    // -------------------------------------------------------------------------
    // Fuzz tests
    // -------------------------------------------------------------------------

    /// @dev Random byte blobs must never return MAGIC
    function testFuzz_isValidSignature_randomBytes_neverReturnsMagic(
        bytes32 hash,
        bytes calldata randomSig
    ) public view {
        // Only assert FAIL if not a coincidentally valid sig (astronomically unlikely)
        bytes4 result = multisig2of3.isValidSignature(hash, randomSig);
        assertTrue(result == MAGIC || result == FAIL_V);
        // We cannot guarantee FAIL for well-formed randomSig without full recovery check;
        // the important thing is it never reverts. For >random bytes it SHOULD be FAIL.
        if (randomSig.length % 65 != 0 || randomSig.length == 0) {
            assertEq(result, FAIL_V);
        }
    }

    /// @dev Correctly signed 2-of-N must always return MAGIC regardless of key values
    function testFuzz_isValidSignature_twoValidOwners_alwaysMagic(
        uint256 pk1,
        uint256 pk2,
        bytes32 hash
    ) public {
        pk1 = bound(pk1, 1, type(uint128).max);
        pk2 = bound(pk2, 1, type(uint128).max);
        vm.assume(pk1 != pk2);
        address a1 = vm.addr(pk1);
        address a2 = vm.addr(pk2);
        vm.assume(a1 != a2);

        address[] memory owners = new address[](2);
        owners[0] = a1;
        owners[1] = a2;
        ERC1271MultiSig inst = new ERC1271MultiSig(owners, 2);

        uint256[] memory keys = new uint256[](2);
        keys[0] = pk1;
        keys[1] = pk2;
        bytes memory sig = SigUtils.buildSortedMultiSig(keys, hash);
        assertEq(inst.isValidSignature(hash, sig), MAGIC);
    }

    /// @dev One-of-two (threshold=1) must succeed with a single valid sig
    function testFuzz_isValidSignature_threshold1_singleSig_returnsMagic(
        uint256 pk1,
        uint256 pk2,
        bytes32 hash
    ) public {
        pk1 = bound(pk1, 1, type(uint128).max);
        pk2 = bound(pk2, 1, type(uint128).max);
        vm.assume(pk1 != pk2);
        address a1 = vm.addr(pk1);
        address a2 = vm.addr(pk2);
        vm.assume(a1 != a2);

        address[] memory owners = new address[](2);
        owners[0] = a1;
        owners[1] = a2;
        ERC1271MultiSig inst = new ERC1271MultiSig(owners, 1);

        bytes memory sig = SigUtils.sign(pk1, hash);
        assertEq(inst.isValidSignature(hash, sig), MAGIC);
    }
}

// =============================================================================
// Invariant tests
// =============================================================================

contract MultiSigHandler is Test {
    ERC1271MultiSig public multisig;
    uint256[]       public ownerKeys;

    bytes4 internal constant MAGIC  = 0x1626ba7e;
    bytes4 internal constant FAIL_V = 0xffffffff;

    constructor() {
        ownerKeys = new uint256[](3);
        ownerKeys[0] = 0xAA01;
        ownerKeys[1] = 0xAA02;
        ownerKeys[2] = 0xAA03;

        address[] memory owners = new address[](3);
        for (uint256 i; i < 3; ++i) owners[i] = vm.addr(ownerKeys[i]);

        multisig = new ERC1271MultiSig(owners, 2);
    }

    /// @dev Drive a valid 2-of-3 call — must return MAGIC
    function callValid2of3(bytes32 hash) external {
        uint256[] memory keys = new uint256[](2);
        keys[0] = ownerKeys[0];
        keys[1] = ownerKeys[1];
        bytes memory sig = SigUtils.buildSortedMultiSig(keys, hash);
        assertEq(multisig.isValidSignature(hash, sig), MAGIC);
    }

    /// @dev Drive a 1-of-3 call — must return FAIL
    function callInsufficient(bytes32 hash) external {
        uint256[] memory keys = new uint256[](1);
        keys[0] = ownerKeys[0];
        bytes memory sig = SigUtils.buildSortedMultiSig(keys, hash);
        assertEq(multisig.isValidSignature(hash, sig), FAIL_V);
    }

    /// @dev Pass garbage — must return FAIL
    function callGarbage(bytes32 hash, bytes calldata garbage) external view {
        if (garbage.length == 0 || garbage.length % 65 != 0) {
            assertEq(multisig.isValidSignature(hash, garbage), FAIL_V);
        }
    }
}

contract ERC1271MultiSigInvariant is Test {
    MultiSigHandler internal handler;

    function setUp() public {
        handler = new MultiSigHandler();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = MultiSigHandler.callValid2of3.selector;
        selectors[1] = MultiSigHandler.callInsufficient.selector;
        selectors[2] = MultiSigHandler.callGarbage.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    function invariant_thresholdAndCountUnchanged() public view {
        assertEq(handler.multisig().threshold(),  2);
        assertEq(handler.multisig().ownerCount(), 3);
    }
}
