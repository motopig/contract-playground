// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title  IERC1271
/// @notice ERC-1271: Standard Signature Validation Method for Contracts
/// @dev    https://eips.ethereum.org/EIPS/eip-1271
interface IERC1271 {
    /// @notice Validates whether a signature is valid for the given hash
    /// @param  hash      The 32-byte digest that was signed
    /// @param  signature The raw signature bytes
    /// @return magicValue `0x1626ba7e` if the signature is valid, any other value otherwise
    function isValidSignature(bytes32 hash, bytes calldata signature)
        external
        view
        returns (bytes4 magicValue);
}
