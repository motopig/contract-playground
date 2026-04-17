// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ITransferDelegate
 * @author LayerZero Labs (@TRileySchwarz, tinom.eth)
 * @custom:version 1.0.0
 * @notice Interface for the `TransferDelegate` contract.
 */
interface ITransferDelegate {
    /**
     * @notice Thrown when the caller is not the LZ multi-call contract.
     */
    error OnlyLZMultiCall();

    /// @notice Address of the LZ multi-call contract allowed to run delegated calls.
    function LZ_MULTI_CALL() external view returns (address);

    /**
     * @notice Transfer ERC20 tokens on behalf of a user.
     * @dev Only callable by `LZ_MULTI_CALL`.
     * @param _token ERC20 token to transfer
     * @param _from Address to transfer from
     * @param _to Address to transfer to
     * @param _amount Amount to transfer
     */
    function delegateTransferFrom(address _token, address _from, address _to, uint256 _amount) external;
}
