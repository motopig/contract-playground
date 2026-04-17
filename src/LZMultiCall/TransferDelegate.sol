// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin-v5.5.0/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin-v5.5.0/contracts/token/ERC20/utils/SafeERC20.sol";

import {ITransferDelegate} from "./interfaces/ITransferDelegate.sol";

/**
 * @title TransferDelegate
 * @author LayerZero Labs (@TRileySchwarz, tinom.eth)
 * @custom:version 1.0.0
 * @notice Contract to forward ERC20 transfer calls from the LZ multi-call contract.
 *         Users must approve this contract to spend their ERC20 tokens.
 *         The LZ multi-call contract ensures that the `from` address always matches the signer.
 */
contract TransferDelegate is ITransferDelegate {
    using SafeERC20 for IERC20;

    /// @notice Address of the LZ multi-call contract allowed to run delegated calls.
    address public immutable LZ_MULTI_CALL;

    /**
     * @param _lzMultiCall Address of the LZ multi-call contract allowed to run delegated calls.
     */
    constructor(address _lzMultiCall) {
        LZ_MULTI_CALL = _lzMultiCall;
    }

    /**
     * @notice Transfer ERC20 tokens on behalf of a user.
     * @dev Only callable by `LZ_MULTI_CALL`.
     * @param _token ERC20 token to transfer
     * @param _from Address to transfer from
     * @param _to Address to transfer to
     * @param _amount Amount to transfer
     */
    function delegateTransferFrom(address _token, address _from, address _to, uint256 _amount) public virtual {
        if (msg.sender != LZ_MULTI_CALL) revert OnlyLZMultiCall();
        IERC20(_token).safeTransferFrom(_from, _to, _amount);
    }
}
