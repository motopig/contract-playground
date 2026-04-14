// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";

/// @title  SigUtils
/// @notice Forge test helper for building and signing digests.
library SigUtils {
    /// @dev address of the Forge cheatcode VM
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    // -------------------------------------------------------------------------
    // ECDSA raw signing
    // -------------------------------------------------------------------------

    /// @notice Sign `digest` with `privateKey` and return packed (r || s || v)
    function sign(uint256 privateKey, bytes32 digest)
        internal
        pure
        returns (bytes memory sig)
    {
        (uint8 v, bytes32 r, bytes32 s) = VM.sign(privateKey, digest);
        sig = abi.encodePacked(r, s, v);
    }

    // -------------------------------------------------------------------------
    // EIP-712 helpers
    // -------------------------------------------------------------------------

    struct EIP712Domain {
        string  name;
        string  version;
        uint256 chainId;
        address verifyingContract;
    }

    bytes32 internal constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @notice Computes the EIP-712 domain separator
    function domainSeparator(EIP712Domain memory domain) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                _DOMAIN_TYPEHASH,
                keccak256(bytes(domain.name)),
                keccak256(bytes(domain.version)),
                domain.chainId,
                domain.verifyingContract
            )
        );
    }

    /// @notice Wraps `structHash` in the EIP-712 envelope
    function buildDigest(bytes32 sep, bytes32 structHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", sep, structHash));
    }

    // -------------------------------------------------------------------------
    // Multi-sig helpers
    // -------------------------------------------------------------------------

    /// @notice Builds a packed multi-sig blob from `n` private keys, sorted by
    ///         ascending signer address (required by ERC1271MultiSig).
    /// @param  keys    Array of private keys (unsorted)
    /// @param  digest  The hash to sign
    /// @return packed  Concatenated 65-byte signatures sorted by signer address
    function buildSortedMultiSig(uint256[] memory keys, bytes32 digest)
        internal
        pure
        returns (bytes memory packed)
    {
        uint256 n = keys.length;

        // Collect (address, sig) pairs
        address[] memory addrs = new address[](n);
        bytes[]   memory sigs  = new bytes[](n);

        for (uint256 i; i < n; ++i) {
            addrs[i] = VM.addr(keys[i]);
            sigs[i]  = sign(keys[i], digest);
        }

        // Bubble sort by address ascending (n is small in tests)
        for (uint256 i; i < n; ++i) {
            for (uint256 j = i + 1; j < n; ++j) {
                if (addrs[i] > addrs[j]) {
                    (addrs[i], addrs[j]) = (addrs[j], addrs[i]);
                    (sigs[i],  sigs[j])  = (sigs[j],  sigs[i]);
                }
            }
        }

        for (uint256 i; i < n; ++i) {
            packed = bytes.concat(packed, sigs[i]);
        }
    }
}
