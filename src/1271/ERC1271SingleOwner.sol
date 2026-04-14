// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC1271 } from "./interfaces/IERC1271.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title  ERC1271SingleOwner
/// @notice ERC-1271 signature validator that delegates to a single EOA owner.
/// @dev    Validates that the provided ECDSA signature was produced by `owner`.
///         Returns FAIL_VALUE (never reverts) for any invalid input.
contract ERC1271SingleOwner is IERC1271 {
    using ECDSA for bytes32;

    /// @dev Magic value per ERC-1271: bytes4(keccak256("isValidSignature(bytes32,bytes)"))
    bytes4 internal constant MAGIC_VALUE = 0x1626ba7e;

    /// @dev Canonical failure value — returned on any validation failure
    bytes4 internal constant FAIL_VALUE = 0xffffffff;

    /// @notice The address authorised to sign on behalf of this contract
    address public immutable owner;

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @dev Reverts when the zero address is supplied as owner
    error ZeroAddress();

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @param _owner The EOA that will be authorised to sign on behalf of this contract
    constructor(address _owner) {
        if (_owner == address(0)) revert ZeroAddress();
        owner = _owner;
    }

    // -------------------------------------------------------------------------
    // IERC1271
    // -------------------------------------------------------------------------

    /// @inheritdoc IERC1271
    /// @dev Uses OpenZeppelin's ECDSA.tryRecover to prevent signature malleability.
    ///      Validates `signature.length == 65` implicitly via tryRecover.
    function isValidSignature(bytes32 hash, bytes calldata signature)
        external
        view
        override
        returns (bytes4)
    {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        if (err != ECDSA.RecoverError.NoError || recovered != owner) {
            return FAIL_VALUE;
        }
        return MAGIC_VALUE;
    }
}
