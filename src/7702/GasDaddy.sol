// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/console.sol";

/**
 * @title GasDaddy
 * @dev General forwarding contract for EIP-7702 gas sponsorship
 * @notice This contract will be used as code for user EOAs via EIP-7702
 */
contract GasDaddy {
    bool private initialized;

    event CallSponsored(
        address indexed user, address indexed target, address indexed sponsor, bytes4 selector, bool success
    );

    event Initialized(address indexed user);

    /**
     * @dev Initialize the contract for the user
     * @notice This function can only be called once per user when the contract is delegated via EIP-7702
     */
    function initialize() external {
        initialized = true;
        emit Initialized(msg.sender);
    }

    /**
     * @dev Check if the contract has been initialized
     * @return Whether the contract has been initialized
     */
    function isInitialized() external view returns (bool) {
        return initialized;
    }

    /**
     * @dev Execute any function call on behalf of the user
     * @param target Address of the target contract
     * @param data Encoded function call data
     * @notice This function will be executed in the user's EOA context via EIP-7702
     */
    function executeCall(address target, bytes calldata data) external {
        // When executed via EIP-7702:
        // - msg.sender = sponsor's EOA address
        // - tx.origin = sponsor's EOA address
        // - gas is paid by sponsor

        require(initialized, "GasDaddy: not initialized");
        require(target != address(0), "GasDaddy: target cannot be zero address");
        require(data.length >= 4, "GasDaddy: invalid call data");

        bytes4 selector = bytes4(data[:4]);

        (bool success,) = target.call(data);
        console.log("GasDaddy: executeCall to", target);
        console.log("GasDaddy: executeCall success", success);
        console.log("GasDaddy: executeCall selector");
        console.logBytes4(selector);
        console.log("GasDaddy: executeCall msg.sender", msg.sender);
        console.log("GasDaddy: executeCall tx.origin", tx.origin);
        emit CallSponsored(msg.sender, target, tx.origin, selector, success);

        require(success, "GasDaddy: call failed");
    }

    /**
     * @dev Execute multiple function calls in a single transaction
     * @param targets Array of target contract addresses
     * @param data Array of encoded function call data
     * @notice All calls must succeed for the transaction to succeed
     */
    function executeMultiCall(address[] calldata targets, bytes[] calldata data) external {
        require(targets.length == data.length, "GasDaddy: length mismatch");
        require(targets.length > 0, "GasDaddy: empty arrays");

        for (uint256 i = 0; i < targets.length; i++) {
            require(targets[i] != address(0), "GasDaddy: target cannot be zero address");
            require(data[i].length >= 4, "GasDaddy: invalid call data");

            bytes4 selector = bytes4(data[i][:4]);

            (bool success,) = targets[i].call(data[i]);

            emit CallSponsored(msg.sender, targets[i], tx.origin, selector, success);

            require(success, "GasDaddy: call failed");
        }
    }

    /**
     * @dev Get execution context for debugging
     */
    function getContext()
        external
        view
        returns (address msgSender, address contractThis, address txOrigin, bool isInit)
    {
        return (msg.sender, address(this), tx.origin, initialized);
    }
}
