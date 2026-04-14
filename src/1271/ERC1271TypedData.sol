// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC1271 } from "./interfaces/IERC1271.sol";
import { ECDSA }    from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 }   from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/// @title  ERC1271TypedData
/// @notice ERC-1271 validator that verifies EIP-712 typed-data signatures signed
///         by a single EOA owner.
/// @dev    Callers pass the raw `structHash`; this contract wraps it in the EIP-712
///         envelope and verifies the resulting digest against `owner`.
///
///         Domain replay protection is provided by the domain separator which binds
///         to `name`, `version`, `chainId`, and `verifyingContract`.
contract ERC1271TypedData is IERC1271, EIP712 {
    using ECDSA for bytes32;

    bytes4 internal constant MAGIC_VALUE = 0x1626ba7e;
    bytes4 internal constant FAIL_VALUE  = 0xffffffff;

    /// @notice The EOA whose signature is considered valid
    address public immutable owner;

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error ZeroAddress();

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @param _owner   The signing EOA
    /// @param _name    EIP-712 domain name (e.g. "MyProtocol")
    /// @param _version EIP-712 domain version (e.g. "1")
    constructor(address _owner, string memory _name, string memory _version)
        EIP712(_name, _version)
    {
        if (_owner == address(0)) revert ZeroAddress();
        owner = _owner;
    }

    // -------------------------------------------------------------------------
    // IERC1271
    // -------------------------------------------------------------------------

    /// @inheritdoc IERC1271
    /// @param hash      The EIP-712 `structHash` (NOT the final digest — this contract
    ///                  applies the domain separator wrapper internally).
    /// @param signature 65-byte ECDSA signature of `hashTypedDataV4(hash)`.
    function isValidSignature(bytes32 hash, bytes calldata signature)
        external
        view
        override
        returns (bytes4)
    {
        bytes32 digest = _hashTypedDataV4(hash);
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        if (err != ECDSA.RecoverError.NoError || recovered != owner) {
            return FAIL_VALUE;
        }
        return MAGIC_VALUE;
    }

    // -------------------------------------------------------------------------
    // View helpers
    // -------------------------------------------------------------------------

    /// @notice Returns the EIP-712 domain separator for this contract
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice Returns the fully-formed EIP-712 digest for a given structHash
    /// @param  structHash The EIP-712 struct hash to wrap
    function buildDigest(bytes32 structHash) external view returns (bytes32) {
        return _hashTypedDataV4(structHash);
    }
}
