// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SafeERC20} from "@openzeppelin-v5.5.0/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin-v5.5.0/contracts/token/ERC20/IERC20.sol";
import {LowLevelCall} from "@openzeppelin-v5.5.0/contracts/utils/LowLevelCall.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {TransferDelegate} from "./TransferDelegate.sol";
import {ITransferDelegate} from "./interfaces/ITransferDelegate.sol";
import {ILZMultiCall} from "./interfaces/ILZMultiCall.sol";

/**
 * @title LZMultiCall
 * @author LayerZero Labs (@TRileySchwarz, tinom.eth)
 * @custom:version 1.0.0
 * @notice Contract to execute multiple calls for users, including approved ERC20 transfers.
 *         Users approve the transfer delegate contract to spend their ERC20 tokens, and this
 *         contract ensures that the `from` address in the transfer call matches the signer.
 * @dev Any ETH, token, or authorization left in this contract can be permissionlessly claimed by
 *      anyone.
 * @dev No allowance should ever be set on this contract for any token, as it'd allow anyone to
 *      permissionlessly claim the tokens.
 */
contract LZMultiCall is ILZMultiCall, EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Transfer delegate that holds allowances for signers.
    ITransferDelegate public immutable TRANSFER_DELEGATE;

    /**
     * @dev Byte layout of `TransferDelegate.delegateTransferFrom(token, from, to, amount)`:
     *      [4:selector][32:token][32:from][32:to][32:amount]
     */
    uint256 internal constant TRANSFER_DATA_LENGTH = 132;
    uint256 internal constant TRANSFER_FROM_OFFSET = 48;

    bytes32 internal constant CALL_TYPE_HASH = keccak256("Call(address target,uint256 value,bytes data)");
    bytes32 internal constant EXECUTE_TYPE_HASH = keccak256(
        /// @dev Primary type and dependencies (alphabetical, deduped).
        "Execute(Call[] calls,bytes32 quoteId,uint256 expiration,uint256 nonce)"
        "Call(address target,uint256 value,bytes data)"
    );

    /// @notice Nonce for replay protection (per signer).
    mapping(address signer => uint256 nonce) public nonces;

    /// @dev Allow the contract to receive ETH mid-execution.
    receive() external payable virtual {}

    /// @dev Deploys and links a transfer delegate contract.
    constructor() EIP712("LZMultiCall", "1.0.0") {
        TRANSFER_DELEGATE = new TransferDelegate(address(this));
    }

    /**
     * @inheritdoc ILZMultiCall
     */
    function execute(
        Call[] calldata _calls,
        bytes32 _quoteId,
        uint256 _expiration,
        address _signer,
        bytes calldata _signature
    ) public payable virtual nonReentrant {
        if (block.timestamp > _expiration) revert Expired(block.timestamp, _expiration);

        uint256 nonce;
        unchecked {
            nonce = nonces[_signer]++;
        }

        if (!SignatureChecker.isValidSignatureNow(
                _signer, _getDigestToSign(_calls, _quoteId, _expiration, nonce), _signature
            )) {
            revert InvalidSignature();
        }

        _executeCalls(_calls, _signer);

        emit ExecutedWithSignature(_signer, _quoteId, nonce);
    }

    /**
     * @inheritdoc ILZMultiCall
     */
    function execute(Call[] calldata _calls, bytes32 _quoteId) public payable virtual nonReentrant {
        uint256 nonce;
        unchecked {
            nonce = nonces[msg.sender]++;
        }

        _executeCalls(_calls, msg.sender);

        emit Executed(msg.sender, _quoteId, nonce);
    }

    /**
     * @inheritdoc ILZMultiCall
     */
    function sweep(address[] calldata _tokens, address _recipient) public virtual {
        if (msg.sender != address(this)) revert OnlySelf();

        for (uint256 i = 0; i < _tokens.length; ++i) {
            address token = _tokens[i];
            if (token == address(0)) {
                uint256 balance = address(this).balance;
                if (balance > 0) _handleCall(payable(_recipient), bytes(""), balance);
            } else {
                uint256 balance = IERC20(token).balanceOf(address(this));
                if (balance > 0) IERC20(token).safeTransfer(_recipient, balance);
            }
        }
    }

    /**
     * @inheritdoc ILZMultiCall
     */
    function getDigestToSign(Call[] calldata _calls, bytes32 _quoteId, uint256 _expiration, address _signer)
        public
        view
        virtual
        returns (bytes32 digest)
    {
        return _getDigestToSign(_calls, _quoteId, _expiration, nonces[_signer]);
    }

    /**
     * @notice Internal function to execute calls.
     * @param _calls Array of calls to execute
     * @param _signer Address that signed the calls, to validate transfer delegate calls
     */
    function _executeCalls(Call[] calldata _calls, address _signer) internal virtual {
        for (uint256 i = 0; i < _calls.length; ++i) {
            Call calldata call = _calls[i];

            if (call.target == address(TRANSFER_DELEGATE)) {
                _handleTransfer(call.data, _signer, call.value);
            } else {
                _handleCall(call.target, call.data, call.value);
            }
        }
    }

    /**
     * @notice Internal function to handle transfer delegate calls.
     * @dev Validates that the `from` address in the call matches the signer address.
     * @param _data Calldata of the transfer delegate call
     * @param _signer Address that signed the calls, matching call's `from` address
     * @param _value `msg.value` for the transfer delegate call, it'll revert if non-zero
     */
    function _handleTransfer(bytes calldata _data, address _signer, uint256 _value) internal virtual {
        if (_data.length != TRANSFER_DATA_LENGTH) revert InvalidCalldataLength(_data.length, TRANSFER_DATA_LENGTH);

        (bytes4 selector, address from) = _extractSelectorAndFrom(_data);

        if (selector != TransferDelegate.delegateTransferFrom.selector) revert InvalidSelector(selector);
        if (from != _signer) revert InvalidFromAddress(from, _signer);

        _handleCall(address(TRANSFER_DELEGATE), _data, _value);
    }

    /**
     * @notice Internal function to forward arbitrary calls.
     * @param _target Address of the target contract to call
     * @param _data Calldata
     * @param _value Value to send with the call
     */
    function _handleCall(address _target, bytes memory _data, uint256 _value) internal virtual {
        bool success = LowLevelCall.callNoReturn(_target, _value, _data);
        if (!success) {
            LowLevelCall.bubbleRevert();
        }

        if (_data.length == 0 && _value > 0) {
            emit NativeTransfer(_target, _value);
        }
    }

    /**
     * @notice Internal function to efficiently extract selector and `from` address from calldata.
     * @param _data `Call.data` calldata
     * @return selector 4-byte selector
     * @return from 20-byte address
     */
    function _extractSelectorAndFrom(bytes calldata _data)
        internal
        pure
        virtual
        returns (bytes4 selector, address from)
    {
        assembly {
            selector := calldataload(_data.offset)
            from := shr(96, calldataload(add(_data.offset, TRANSFER_FROM_OFFSET)))
        }
    }

    /**
     * @notice Internal function to get the digest to sign for a given set of calls.
     * @param _calls Array of calls to execute
     * @param _quoteId Unique identifier for this execution
     * @param _expiration Expiration block timestamp after which the calls will revert
     * @param _nonce Nonce for replay protection
     * @return digest Digest that should be signed
     */
    function _getDigestToSign(Call[] calldata _calls, bytes32 _quoteId, uint256 _expiration, uint256 _nonce)
        internal
        view
        virtual
        returns (bytes32 digest)
    {
        bytes32[] memory callHashes = new bytes32[](_calls.length);

        for (uint256 i = 0; i < _calls.length; ++i) {
            Call calldata call = _calls[i];
            callHashes[i] = _hashCall(CALL_TYPE_HASH, call.target, call.value, keccak256(call.data));
        }

        bytes32 structHash =
            _hashStruct(EXECUTE_TYPE_HASH, _hashBytes32Array(callHashes), _quoteId, _expiration, _nonce);
        return _hashTypedDataV4(structHash);
    }

    /**
     * @notice Internal function to efficiently hash a call.
     * @dev Equivalent to `keccak256(abi.encode(_typeHash, _target, _value, _dataHash))`.
     * @param _typeHash Type hash of the EIP-712 call struct
     * @param _target Address of the target contract to call
     * @param _value Value to send with the call
     * @param _dataHash Hash of the calldata
     * @return callHash Hash of the call
     */
    function _hashCall(bytes32 _typeHash, address _target, uint256 _value, bytes32 _dataHash)
        internal
        pure
        virtual
        returns (bytes32 callHash)
    {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, _typeHash)
            mstore(add(ptr, 0x20), _target)
            mstore(add(ptr, 0x40), _value)
            mstore(add(ptr, 0x60), _dataHash)
            callHash := keccak256(ptr, 0x80)
        }
    }

    /**
     * @notice Internal function to efficiently hash the EIP-712 struct.
     * @dev Equivalent to `keccak256(abi.encode(_typeHash, _arrHash, _quoteId, _expiration, _nonce))`.
     * @param _typeHash Type hash of the EIP-712 struct
     * @param _arrHash Hash of the array of `bytes32`
     * @param _quoteId Unique identifier for this execution
     * @param _expiration Expiration block timestamp after which the calls will revert
     * @param _nonce Nonce for replay protection
     * @return hashedStruct Hash of the EIP-712 struct
     */
    function _hashStruct(bytes32 _typeHash, bytes32 _arrHash, bytes32 _quoteId, uint256 _expiration, uint256 _nonce)
        internal
        pure
        virtual
        returns (bytes32 hashedStruct)
    {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, _typeHash)
            mstore(add(ptr, 0x20), _arrHash)
            mstore(add(ptr, 0x40), _quoteId)
            mstore(add(ptr, 0x60), _expiration)
            mstore(add(ptr, 0x80), _nonce)
            hashedStruct := keccak256(ptr, 0xa0)
        }
    }

    /**
     * @notice Internal function to efficiently hash an array of `bytes32`.
     * @dev Equivalent to `keccak256(abi.encodePacked(_arr))`.
     * @param _arr Array of `bytes32` to hash
     * @return hashedArr Hash of the array
     */
    function _hashBytes32Array(bytes32[] memory _arr) internal pure virtual returns (bytes32 hashedArr) {
        assembly {
            hashedArr := keccak256(add(_arr, 0x20), shl(5, mload(_arr)))
        }
    }
}
