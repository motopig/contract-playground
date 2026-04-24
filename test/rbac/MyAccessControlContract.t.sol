// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "openzeppelin-contracts/contracts/access/IAccessControl.sol";
import {MyAccessControlContract} from "../../src/rbac/MyAccessControlContract.sol";

contract MyAccessControlContractTest is Test {
    MyAccessControlContract internal accessControlExample;

    address internal admin = address(this);
    address internal operator = address(0x10);
    address internal minter = address(0x11);
    address internal outsider = address(0x12);

    function setUp() public {
        accessControlExample = new MyAccessControlContract();
    }

    function test_DefaultAdminRole_AssignedToDeployer() public view {
        assertTrue(accessControlExample.hasRole(accessControlExample.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_AdminCanGrantOperator_AndOperatorCanSetValue() public {
        accessControlExample.grantRole(accessControlExample.OPERATOR_ROLE(), operator);

        vm.prank(operator);
        accessControlExample.setValue(123);

        assertEq(accessControlExample.value(), 123);
    }

    function test_RevertWhen_UnauthorizedCallsSetValue() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                outsider,
                accessControlExample.OPERATOR_ROLE()
            )
        );
        vm.prank(outsider);
        accessControlExample.setValue(1);
    }

    function test_RevertWhen_NonAdminGrantsRole() public {
        bytes32 operatorRole = accessControlExample.OPERATOR_ROLE();

        vm.startPrank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                outsider,
                accessControlExample.DEFAULT_ADMIN_ROLE()
            )
        );
        accessControlExample.grantRole(operatorRole, operator);
        vm.stopPrank();
    }

    function test_AdminCanRevokeRole() public {
        accessControlExample.grantRole(accessControlExample.OPERATOR_ROLE(), operator);

        accessControlExample.revokeRole(accessControlExample.OPERATOR_ROLE(), operator);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                operator,
                accessControlExample.OPERATOR_ROLE()
            )
        );
        vm.prank(operator);
        accessControlExample.setValue(99);
    }

    function test_OperatorCanRenounceRole() public {
        accessControlExample.grantRole(accessControlExample.OPERATOR_ROLE(), operator);

        vm.startPrank(operator);
        accessControlExample.renounceRole(accessControlExample.OPERATOR_ROLE(), operator);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                operator,
                accessControlExample.OPERATOR_ROLE()
            )
        );
        vm.prank(operator);
        accessControlExample.setValue(88);
    }

    function test_MinterCanMint_AfterGrant() public {
        accessControlExample.grantRole(accessControlExample.MINTER_ROLE(), minter);

        vm.prank(minter);
        accessControlExample.mint(777);

        assertEq(accessControlExample.totalMinted(), 777);
    }

    function test_RevertWhen_UnauthorizedCallsMint() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                outsider,
                accessControlExample.MINTER_ROLE()
            )
        );
        vm.prank(outsider);
        accessControlExample.mint(1);
    }

    function test_RevertWhen_UnauthorizedCallsPause() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                outsider,
                accessControlExample.PAUSER_ROLE()
            )
        );
        vm.prank(outsider);
        accessControlExample.pause();
    }

    function test_PauseBlocksSetValueAndMint_AndUnpauseRestores() public {
        accessControlExample.grantRole(accessControlExample.OPERATOR_ROLE(), operator);
        accessControlExample.grantRole(accessControlExample.MINTER_ROLE(), minter);
        accessControlExample.grantRole(accessControlExample.PAUSER_ROLE(), admin);

        accessControlExample.pause();

        vm.prank(operator);
        vm.expectRevert(MyAccessControlContract.ContractPaused.selector);
        accessControlExample.setValue(10);

        vm.prank(minter);
        vm.expectRevert(MyAccessControlContract.ContractPaused.selector);
        accessControlExample.mint(10);

        accessControlExample.unpause();

        vm.prank(operator);
        accessControlExample.setValue(10);

        vm.prank(minter);
        accessControlExample.mint(10);

        assertEq(accessControlExample.value(), 10);
        assertEq(accessControlExample.totalMinted(), 10);
    }

    function test_RevertWhen_PauseCalledTwice() public {
        accessControlExample.grantRole(accessControlExample.PAUSER_ROLE(), admin);

        accessControlExample.pause();
        vm.expectRevert(MyAccessControlContract.AlreadyPaused.selector);
        accessControlExample.pause();
    }

    function test_RevertWhen_UnpauseCalledWithoutPause() public {
        accessControlExample.grantRole(accessControlExample.PAUSER_ROLE(), admin);

        vm.expectRevert(MyAccessControlContract.AlreadyUnpaused.selector);
        accessControlExample.unpause();
    }

    function test_BusinessEvents_EmittedWithExpectedArgs() public {
        accessControlExample.grantRole(accessControlExample.OPERATOR_ROLE(), operator);
        accessControlExample.grantRole(accessControlExample.MINTER_ROLE(), minter);
        accessControlExample.grantRole(accessControlExample.PAUSER_ROLE(), admin);

        vm.prank(operator);
        vm.expectEmit(true, true, true, true);
        emit MyAccessControlContract.ValueUpdated(42);
        accessControlExample.setValue(42);

        vm.prank(minter);
        vm.expectEmit(true, true, true, true);
        emit MyAccessControlContract.Minted(7, 7);
        accessControlExample.mint(7);

        vm.expectEmit(true, true, true, true);
        emit MyAccessControlContract.Paused(admin);
        accessControlExample.pause();

        vm.expectEmit(true, true, true, true);
        emit MyAccessControlContract.Unpaused(admin);
        accessControlExample.unpause();
    }

    function test_RoleGrantedEvent_Emitted() public {
        vm.expectEmit(true, true, true, true);
        emit IAccessControl.RoleGranted(accessControlExample.OPERATOR_ROLE(), operator, admin);

        accessControlExample.grantRole(accessControlExample.OPERATOR_ROLE(), operator);
    }

    function test_RoleRevokedEvent_Emitted() public {
        accessControlExample.grantRole(accessControlExample.OPERATOR_ROLE(), operator);

        vm.expectEmit(true, true, true, true);
        emit IAccessControl.RoleRevoked(accessControlExample.OPERATOR_ROLE(), operator, admin);

        accessControlExample.revokeRole(accessControlExample.OPERATOR_ROLE(), operator);
    }
}
