// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ITransferDelegate} from "./ITransferDelegate.sol";

/**
 * @title ILZMultiCall
 * @author LayerZero Labs (@TRileySchwarz, tinom.eth)
 * @custom:version 1.0.0
 * @notice Interface for the `LZMultiCall` contract.
 */
interface ILZMultiCall {
    /**
     * @notice Struct representing a call to a contract.
     * @param target Address of the target contract to call
     * @param value Value to send with the call
     * @param data Calldata of the call
     */
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    /**
     * @notice Emitted when a set of calls is executed.
     * @param signer Address that authorized the calls
     * @param quoteId Unique identifier for this execution
     * @param nonce Nonce for replay protection
     */
    event Executed(address indexed signer, bytes32 indexed quoteId, uint256 nonce);

    /**
     * @notice Emitted when a set of calls is executed with a signature.
     * @param signer Address that authorized the calls
     * @param quoteId Unique identifier for this execution
     * @param nonce Nonce for replay protection
     */
    event ExecutedWithSignature(address indexed signer, bytes32 indexed quoteId, uint256 nonce);

    /**
     * @notice Emitted when a native ETH transfer is made (empty call with value).
     * @param to Recipient address
     * @param value Amount of ETH transferred
     */
    event NativeTransfer(address indexed to, uint256 value);

    /**
     * @notice Thrown when a set of calls is expired.
     * @param blockTimestamp Current block timestamp
     * @param expiration Expiration block timestamp
     */
    error Expired(uint256 blockTimestamp, uint256 expiration);

    /**
     * @notice Thrown when the `from` address in a transfer delegate call does not match the signer.
     * @param received Address received from the call
     * @param signer Signer address
     */
    error InvalidFromAddress(address received, address signer);

    /**
     * @notice Thrown when the signature cannot be verified.
     */
    error InvalidSignature();

    /**
     * @notice Thrown when a transfer delegate call has an invalid calldata length.
     * @param received Length of the received calldata
     * @param expected Length of the expected calldata
     */
    error InvalidCalldataLength(uint256 received, uint256 expected);

    /**
     * @notice Thrown when a transfer delegate calldata selector is invalid.
     * @param selector Calldata selector
     */
    error InvalidSelector(bytes4 selector);

    /**
     * @notice Thrown when the caller is not the LZ multi-call contract.
     */
    error OnlySelf();

    /**
     * @notice Address of the transfer delegate contract.
     * @return transferDelegate Address of the transfer delegate contract
     */
    function TRANSFER_DELEGATE() external view returns (ITransferDelegate transferDelegate);

    /**
     * @notice Nonce for replay protection (per signer).
     * @param signer Signer address
     * @return nonce Current nonce for the signer
     */
    function nonces(address signer) external view returns (uint256);

    /**
     * @notice Executes multiple calls with a user's signature.
     * @dev This enables account abstraction: anyone can submit the transaction (pay gas) on behalf
     *      of the user who signed.
     * @dev The nonce must match the signer's current nonce to prevent replay attacks.
     * @dev If target is `TRANSFER_DELEGATE` for any call, it validates that the `from` address in
     *      the transfer call matches the `_signer` address.
     * @dev Any ETH, token, or authorization left after this call can be permissionlessly claimed by
     *      anyone.
     * @dev `quoteId` can be a duplicate of previous executions.
     * @dev Calls should not depend on `tx.origin`, as execution is permissionless.
     * @param _calls Array of calls to execute
     * @param _quoteId Non-unique identifier for this execution
     * @param _expiration Expiration block timestamp after which the calls will revert
     * @param _signer Address that authorized the calls
     * @param _signature EIP-712 signature from the user
     */
    function execute(
        Call[] calldata _calls,
        bytes32 _quoteId,
        uint256 _expiration,
        address _signer,
        bytes calldata _signature
    ) external payable;

    /**
     * @notice Executes multiple calls with `msg.sender` as the signer.
     * @dev If target is `TRANSFER_DELEGATE` for any call, it validates that the `from` address in
     *      the transfer call matches the `_signer` address.
     * @dev Any ETH, token, or authorization left after this call can be permissionlessly claimed by
     *      anyone.
     * @dev `quoteId` can be a duplicate of previous executions.
     * @dev Calls should not depend on `tx.origin`, as execution is permissionless.
     * @dev Calling this function with an empty `_calls` array allows to skip the current nonce and
     *      invalidate a signature.
     * @param _calls Array of calls to execute
     * @param _quoteId Non-unique identifier for this execution
     */
    function execute(Call[] calldata _calls, bytes32 _quoteId) external payable;

    /**
     * @notice Sends remaining ERC20 tokens and ETH in the contract to a recipient.
     * @param _tokens Array of ERC20 tokens to sweep, `address(0)` for ETH
     * @param _recipient Address to send all tokens to
     */
    function sweep(address[] calldata _tokens, address _recipient) external;

    /**
     * @notice Gets the digest to sign for a given set of calls.
     * @dev Useful for off-chain signature generation.
     * @param _calls Array of calls to execute
     * @param _quoteId Unique identifier for this execution
     * @param _expiration Expiration block timestamp after which the calls will revert
     * @param _signer Address that will sign the calls
     * @return digest Digest that should be signed
     */
    function getDigestToSign(Call[] calldata _calls, bytes32 _quoteId, uint256 _expiration, address _signer)
        external
        view
        returns (bytes32 digest);
}
