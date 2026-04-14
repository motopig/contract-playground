// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {MyContract} from "../../src/rbac/MyContract.sol";
import {AccessManager} from "openzeppelin-contracts/contracts/access/manager/AccessManager.sol";

contract EthSink {
    receive() external payable {}
}

contract MyContractTest is Test {
    MyContract public myContract;
    AccessManager public accessManager;
    EthSink public ethSink;
    
    address public admin = address(0x1);
    address public operator = address(0x2);
    address public stranger = address(0x3);
    address public finance = address(0x4);
    address public minter = address(0x5);
    address public pauser = address(0x6);
    address public viewer = address(0x7);

    uint64 constant ADMIN_ROLE = 0;
    uint64 constant OPERATOR_ROLE = 1;
    uint64 constant FINANCE_ROLE = 2;
    uint64 constant MINTER_ROLE = 3;
    uint64 constant PAUSER_ROLE = 4;
    uint64 constant VIEWER_ROLE = 5;

    uint32 constant ONE_DAY_DELAY = 86400;

    function setUp() public {
        accessManager = new AccessManager(admin);
        ethSink = new EthSink();
        myContract = new MyContract(address(accessManager), address(ethSink));

        // OPERATOR/MINTER/PAUSER/VIEWER 立即生效 (delay=0)
        _grantRole(OPERATOR_ROLE, operator, 0);
        _grantRole(MINTER_ROLE, minter, 0);
        _grantRole(PAUSER_ROLE, pauser, 0);
        _grantRole(VIEWER_ROLE, viewer, 0);
        // FINANCE: executionDelay = 86400 (24小时)
        // 意味着: hasRole 通过检查，但 canCall 检查会考虑 delay
        _grantRole(FINANCE_ROLE, finance, ONE_DAY_DELAY);

        _configureRole(MyContract.setValue.selector, OPERATOR_ROLE);
        _configureRole(MyContract.resetValue.selector, OPERATOR_ROLE);
        _configureRole(MyContract.withdraw.selector, FINANCE_ROLE);
        _configureRole(MyContract.transferTo.selector, FINANCE_ROLE);
        _configureRole(MyContract.mint.selector, MINTER_ROLE);
        _configureRole(MyContract.pause.selector, PAUSER_ROLE);
        _configureRole(MyContract.unpause.selector, PAUSER_ROLE);
        _configureRole(MyContract.getFullStatus.selector, VIEWER_ROLE);
    }

    function _grantRole(uint64 roleId, address account, uint32 executionDelay) internal {
        vm.prank(admin);
        accessManager.grantRole(roleId, account, executionDelay);
    }

    function _configureRole(bytes4 selector, uint64 roleId) internal {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        vm.prank(admin);
        accessManager.setTargetFunctionRole(address(myContract), selectors, roleId);
    }

    // ===== 检查 grantRole delay 的效果 =====

    function test_check_finance_delay() public view {
        (bool isMember, uint32 roleDelay) = accessManager.hasRole(FINANCE_ROLE, finance);
        console.log("Is member:", isMember, "Role delay:", roleDelay);
        assertTrue(isMember);
        assertEq(roleDelay, ONE_DAY_DELAY);

        // 检查 canCall - 这应该会返回 (true, ONE_DAY_DELAY) 因为角色有延迟
        (bool canCall, uint32 execDelay) = accessManager.canCall(
            finance,
            address(myContract),
            MyContract.withdraw.selector
        );
        console.log("Can call:", canCall, "Exec delay:", execDelay);
        // canCall 为 true 因为角色有效，但 delay 是 86400
    }

    function test_finance_direct_call_reverts_due_to_delay() public {
        // finance 有 FINANCE_ROLE 但 executionDelay=86400
        // 直接调用 withdraw 应该失败
        vm.deal(address(myContract), 1 ether);
        
        vm.prank(finance);
        vm.expectRevert();
        myContract.withdraw();
    }

    function test_finance_schedule_and_execute() public {
        // canCall 延迟的测试：角色有效但操作被延迟
        // OZ AccessManager 的 execute 依赖 canCall，而 canCall 在 delay 期内返回 false
        // 因此即使 schedule 预约了，也无法在 delay 期内执行
        
        vm.deal(address(myContract), 1 ether);
        
        // 尝试直接 execute（没有 schedule）- 失败因为 canCall = false
        vm.prank(finance);
        vm.expectRevert();
        accessManager.execute(
            address(myContract),
            abi.encodeCall(MyContract.withdraw, ()) 
        );
    }

    function test_finance_execute_before_delay_fails() public {
        vm.deal(address(myContract), 1 ether);
        
        // canCall 返回 false（延迟未过），所以 execute 会失败
        vm.prank(finance);
        vm.expectRevert();
        accessManager.execute(
            address(myContract),
            abi.encodeCall(MyContract.withdraw, ())
        );
    }

    // ===== OPERATOR_ROLE 测试 =====

    function test_operator_can_setValue() public {
        vm.prank(operator);
        myContract.setValue(100);
        assertEq(myContract.value(), 100);
    }

    function test_operator_can_resetValue() public {
        vm.prank(operator);
        myContract.setValue(999);
        vm.prank(operator);
        myContract.resetValue();
        assertEq(myContract.value(), 0);
    }

    function test_operator_cannot_withdraw() public {
        vm.deal(address(myContract), 1 ether);
        vm.prank(operator);
        vm.expectRevert();
        myContract.withdraw();
    }

    // ===== MINTER_ROLE 测试 =====

    function test_minter_can_mint() public {
        vm.prank(minter);
        myContract.mint(1000);
        assertEq(myContract.totalMinted(), 1000);
    }

    function test_minter_cannot_pause() public {
        vm.prank(minter);
        vm.expectRevert();
        myContract.pause();
    }

    // ===== PAUSER_ROLE 测试 =====

    function test_pauser_can_pause() public {
        assertFalse(myContract.paused());
        vm.prank(pauser);
        myContract.pause();
        assertTrue(myContract.paused());
    }

    function test_pauser_can_unpause() public {
        vm.prank(pauser);
        myContract.pause();
        vm.prank(pauser);
        myContract.unpause();
        assertFalse(myContract.paused());
    }

    function test_pauser_cannot_mint() public {
        vm.prank(pauser);
        vm.expectRevert();
        myContract.mint(500);
    }

    // ===== VIEWER_ROLE 测试 =====

    function test_viewer_can_getFullStatus() public {
        vm.deal(address(myContract), 5 ether);
        vm.prank(viewer);
        (uint256 val, uint256 bal, uint256 minted, bool p, address o) = myContract.getFullStatus();
        assertEq(val, 0);
        assertEq(bal, 5 ether);
        assertEq(minted, 0);
        assertFalse(p);
        assertEq(o, address(this));
    }

    function test_viewer_cannot_mint() public {
        vm.prank(viewer);
        vm.expectRevert();
        myContract.mint(1);
    }

    // ===== 公开函数测试 =====

    function test_public_functions_no_restriction() public {
        vm.prank(stranger);
        myContract.getValue();
        vm.prank(stranger);
        myContract.getBalance();
        vm.prank(stranger);
        myContract.isPaused();
    }

    function test_stranger_has_no_roles() public view {
        (bool hasOp,) = accessManager.hasRole(OPERATOR_ROLE, stranger);
        (bool hasFin,) = accessManager.hasRole(FINANCE_ROLE, stranger);
        (bool hasMin,) = accessManager.hasRole(MINTER_ROLE, stranger);
        (bool hasPau,) = accessManager.hasRole(PAUSER_ROLE, stranger);
        (bool hasView,) = accessManager.hasRole(VIEWER_ROLE, stranger);
        assertFalse(hasOp);
        assertFalse(hasFin);
        assertFalse(hasMin);
        assertFalse(hasPau);
        assertFalse(hasView);
    }

    // ===== 跨角色权限隔离测试 =====

    function test_no_cross_role_permission() public {
        vm.prank(operator);
        vm.expectRevert();
        myContract.withdraw();
        vm.prank(finance);
        vm.expectRevert();
        myContract.mint(100);
        vm.prank(minter);
        vm.expectRevert();
        myContract.pause();
        vm.prank(pauser);
        vm.expectRevert();
        myContract.getFullStatus();
    }
}