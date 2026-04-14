// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC1271 } from "./interfaces/IERC1271.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title  ERC1271MultiSig
/// @notice ERC-1271 M-of-N threshold ECDSA signature validator.
/// @dev    Callers must supply signatures sorted by recovered signer address (ascending)
///         to guard against duplicate counting.
contract ERC1271MultiSig is IERC1271 {
    using ECDSA for bytes32;

    bytes4 internal constant MAGIC_VALUE = 0x1626ba7e;
    bytes4 internal constant FAIL_VALUE  = 0xffffffff;

    /// @notice Minimum number of valid signatures required
    uint256 public immutable threshold;

    /// @notice Number of authorised owners
    uint256 public immutable ownerCount;

    /// @dev owner address → true if authorised
    mapping(address => bool) private _isOwner;

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error InvalidThreshold();
    error InvalidOwnersLength();
    error ZeroAddressOwner();
    error DuplicateOwner(address owner);

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @param _owners    Array of authorised EOA addresses (must be unique, non-zero)
    /// @param _threshold Minimum signatures required (1 ≤ threshold ≤ owners.length)
    constructor(address[] memory _owners, uint256 _threshold) {
        uint256 n = _owners.length;
        if (n == 0) revert InvalidOwnersLength();
        if (_threshold == 0 || _threshold > n) revert InvalidThreshold();

        for (uint256 i; i < n; ++i) {
            address o = _owners[i];
            if (o == address(0)) revert ZeroAddressOwner();
            if (_isOwner[o]) revert DuplicateOwner(o);
            _isOwner[o] = true;
        }

        threshold  = _threshold;
        ownerCount = n;
    }

    // -------------------------------------------------------------------------
    // IERC1271
    // -------------------------------------------------------------------------

    /// @inheritdoc IERC1271
    /// @dev `signature` must be a tightly packed concatenation of 65-byte ECDSA sigs,
    ///      ordered by recovered signer address ascending. Length must be a multiple of 65.
    function isValidSignature(bytes32 hash, bytes calldata signature)
        external
        view
        override
        returns (bytes4)
    {
        uint256 sigLen = signature.length;
        // Each ECDSA sig is exactly 65 bytes (r || s || v)
        if (sigLen == 0 || sigLen % 65 != 0) return FAIL_VALUE;

        uint256 sigCount = sigLen / 65;
        uint256 validCount;
        address lastSigner;

        for (uint256 i; i < sigCount; ++i) {
            bytes calldata sig = signature[i * 65 : (i + 1) * 65];

            (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, sig);
            if (err != ECDSA.RecoverError.NoError) return FAIL_VALUE;

            // Enforce strictly ascending order → prevents duplicate signers
            if (recovered <= lastSigner) return FAIL_VALUE;
            if (!_isOwner[recovered]) return FAIL_VALUE;

            lastSigner = recovered;
            ++validCount;
        }

        if (validCount < threshold) return FAIL_VALUE;
        return MAGIC_VALUE;
    }

    // -------------------------------------------------------------------------
    // View helpers
    // -------------------------------------------------------------------------

    /// @notice Returns whether `account` is an authorised owner
    function isOwner(address account) external view returns (bool) {
        return _isOwner[account];
    }
}
