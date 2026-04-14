// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std-1.15.0/src/Test.sol";

import {IEntryPoint} from "account-abstraction-0.9.0/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction-0.9.0/contracts/interfaces/PackedUserOperation.sol";
import {EntryPoint} from "account-abstraction-0.9.0/contracts/core/EntryPoint.sol";
import {BaseAccount} from "account-abstraction-0.9.0/contracts/core/BaseAccount.sol";

import {SimpleAccount} from "../../src/4337/SimpleAccount.sol";
import {SimpleAccountFactory} from "../../src/4337/SimpleAccountFactory.sol";
import {TestHelper} from "./helpers/TestHelper.sol";

// ─── 最小化接口 ──────────────────────────────────────────

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
}

interface IPool {
    /// @notice 存入资产到 Aave
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    /// @notice 从 Aave 取出资产
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

interface IAToken {
    function balanceOf(address account) external view returns (uint256);
    function scaledBalanceOf(address user) external view returns (uint256);
}

/**
 * @title AaveIntegrationTest
 * @notice 通过 ERC-4337 智能合约账户对接 Aave V3 进行 USDC 存取的 Fork 测试
 *
 * @dev 测试流程:
 *   1. Fork Ethereum 主网
 *   2. 部署 EntryPoint + Factory + Account（通过 TestHelper）
 *   3. 给账户打入 USDC
 *   4. 通过 UserOp 批量操作: approve + supply USDC 到 Aave
 *   5. 通过 UserOp 从 Aave withdraw USDC
 *
 * 运行方式:
 *   MAINNET_RPC_URL=https://... forge test --match-contract AaveIntegrationTest -vvv
 */
contract AaveIntegrationTest is TestHelper {
    // ─── Mainnet 合约地址 ─────────────────────────────────
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant AAVE_V3_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant A_USDC = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c; // aEthUSDC

    // ─── 已知的 USDC 大户地址（用来转 USDC 给测试账户）─────
    address constant USDC_WHALE = 0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341;

    // ─── 测试参数 ────────────────────────────────────────
    uint256 constant SUPPLY_AMOUNT = 10_000 * 1e6; // 10,000 USDC (6 decimals)
    uint256 constant WITHDRAW_AMOUNT = 5_000 * 1e6; // 5,000 USDC

    function setUp() public override {
        // Fork mainnet
        string memory rpcUrl = vm.envString("MAINNET_RPC_URL");
        vm.createSelectFork(rpcUrl);

        // 调用 TestHelper.setUp() 部署 EntryPoint、Factory、Account 等
        super.setUp();

        // 把 USDC 转给我们的 4337 账户
        _fundAccountWithUSDC(SUPPLY_AMOUNT * 2);
    }

    // ═══════════════════════════════════════════════════════
    //  测试: Owner 直接通过账户存取 USDC
    // ═══════════════════════════════════════════════════════

    function test_directSupplyAndWithdraw() public {
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(account));
        console2.log("Account USDC before supply:", usdcBefore / 1e6);

        // Step 1: approve
        vm.prank(owner);
        account.execute(USDC, 0, abi.encodeCall(IERC20.approve, (AAVE_V3_POOL, SUPPLY_AMOUNT)));

        // Step 2: supply
        vm.prank(owner);
        account.execute(AAVE_V3_POOL, 0, abi.encodeCall(IPool.supply, (USDC, SUPPLY_AMOUNT, address(account), 0)));

        uint256 aTokenBalance = IAToken(A_USDC).balanceOf(address(account));
        console2.log("Account aUSDC after supply:", aTokenBalance / 1e6);
        assertGe(aTokenBalance, SUPPLY_AMOUNT - 2, "aToken balance should >= supply amount");

        // Step 3: withdraw
        vm.prank(owner);
        account.execute(AAVE_V3_POOL, 0, abi.encodeCall(IPool.withdraw, (USDC, WITHDRAW_AMOUNT, address(account))));

        uint256 usdcAfterWithdraw = IERC20(USDC).balanceOf(address(account));
        console2.log("Account USDC after withdraw:", usdcAfterWithdraw / 1e6);
        assertGe(usdcAfterWithdraw, usdcBefore - SUPPLY_AMOUNT + WITHDRAW_AMOUNT - 1);
    }

    // ═══════════════════════════════════════════════════════
    //  测试: 通过 UserOp 批量 approve + supply
    // ═══════════════════════════════════════════════════════

    function test_userOp_batchSupply() public {
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(account));
        console2.log("Account USDC before supply:", usdcBefore / 1e6);

        // 构建批量调用: approve + supply
        BaseAccount.Call[] memory calls = new BaseAccount.Call[](2);

        // Call 1: approve USDC
        calls[0] = BaseAccount.Call({
            target: USDC, value: 0, data: abi.encodeCall(IERC20.approve, (AAVE_V3_POOL, SUPPLY_AMOUNT))
        });

        // Call 2: supply to Aave
        calls[1] = BaseAccount.Call({
            target: AAVE_V3_POOL,
            value: 0,
            data: abi.encodeCall(IPool.supply, (USDC, SUPPLY_AMOUNT, address(account), 0))
        });

        // 构建 UserOp（使用 executeBatch，Aave 交互需要更高 gas）
        PackedUserOperation memory userOp = _buildUserOp(
            address(account), account.getNonce(), abi.encodeCall(BaseAccount.executeBatch, (calls)), 200_000, 800_000
        );

        // 签名
        userOp.signature = _signUserOp(userOp, ownerKey);

        // 通过 EntryPoint 执行
        _executeUserOp(userOp);

        // 验证
        uint256 aTokenBalance = IAToken(A_USDC).balanceOf(address(account));
        console2.log("Account aUSDC after supply:", aTokenBalance / 1e6);
        assertGe(aTokenBalance, SUPPLY_AMOUNT - 2, "aToken balance should >= supply amount");
    }

    // ═══════════════════════════════════════════════════════
    //  测试: 通过 UserOp 从 Aave 取出 USDC
    // ═══════════════════════════════════════════════════════

    function test_userOp_withdraw() public {
        // 先存入
        _supplyToAave(SUPPLY_AMOUNT);

        uint256 aTokenBefore = IAToken(A_USDC).balanceOf(address(account));
        console2.log("Account aUSDC before withdraw:", aTokenBefore / 1e6);

        // 构建 UserOp: withdraw from Aave
        PackedUserOperation memory userOp = _buildUserOp(
            address(account),
            account.getNonce(),
            abi.encodeCall(
                BaseAccount.execute,
                (AAVE_V3_POOL, 0, abi.encodeCall(IPool.withdraw, (USDC, WITHDRAW_AMOUNT, address(account))))
            ),
            200_000,
            800_000
        );

        userOp.signature = _signUserOp(userOp, ownerKey);
        _executeUserOp(userOp);

        uint256 aTokenAfter = IAToken(A_USDC).balanceOf(address(account));
        uint256 usdcBalance = IERC20(USDC).balanceOf(address(account));
        console2.log("Account aUSDC after withdraw:", aTokenAfter / 1e6);
        console2.log("Account USDC after withdraw:", usdcBalance / 1e6);

        assertLt(aTokenAfter, aTokenBefore, "aToken should decrease");
        assertGe(usdcBalance, WITHDRAW_AMOUNT - 1, "should receive USDC back");
    }

    // ═══════════════════════════════════════════════════════
    //  测试: 完整流程 supply → 等待一段时间 → withdraw 全部（含利息）
    // ═══════════════════════════════════════════════════════

    function test_userOp_supplyAndWithdrawWithInterest() public {
        // Step 1: 通过 UserOp 批量 approve + supply
        BaseAccount.Call[] memory supplyCalls = new BaseAccount.Call[](2);
        supplyCalls[0] = BaseAccount.Call({
            target: USDC, value: 0, data: abi.encodeCall(IERC20.approve, (AAVE_V3_POOL, SUPPLY_AMOUNT))
        });
        supplyCalls[1] = BaseAccount.Call({
            target: AAVE_V3_POOL,
            value: 0,
            data: abi.encodeCall(IPool.supply, (USDC, SUPPLY_AMOUNT, address(account), 0))
        });

        PackedUserOperation memory supplyOp = _buildUserOp(
            address(account),
            account.getNonce(),
            abi.encodeCall(BaseAccount.executeBatch, (supplyCalls)),
            200_000,
            800_000
        );
        supplyOp.signature = _signUserOp(supplyOp, ownerKey);
        _executeUserOp(supplyOp);

        uint256 aTokenAfterSupply = IAToken(A_USDC).balanceOf(address(account));
        console2.log("aUSDC after supply:", aTokenAfterSupply / 1e6);

        // Step 2: 模拟时间经过 30 天，累计利息
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 30 * 7200); // ~7200 blocks/day

        uint256 aTokenAfterTime = IAToken(A_USDC).balanceOf(address(account));
        console2.log("aUSDC after 30 days:", aTokenAfterTime / 1e6);
        assertGe(aTokenAfterTime, aTokenAfterSupply, "aToken should accrue interest");

        // Step 3: 通过 UserOp withdraw 全部（type(uint256).max = withdraw all）
        PackedUserOperation memory withdrawOp = _buildUserOp(
            address(account),
            account.getNonce(),
            abi.encodeCall(
                BaseAccount.execute,
                (AAVE_V3_POOL, 0, abi.encodeCall(IPool.withdraw, (USDC, type(uint256).max, address(account))))
            ),
            200_000,
            800_000
        );
        withdrawOp.signature = _signUserOp(withdrawOp, ownerKey);
        _executeUserOp(withdrawOp);

        uint256 finalUSDC = IERC20(USDC).balanceOf(address(account));
        uint256 finalAToken = IAToken(A_USDC).balanceOf(address(account));
        console2.log("Final USDC balance:", finalUSDC / 1e6);
        console2.log("Final aUSDC balance:", finalAToken / 1e6);

        assertEq(finalAToken, 0, "should have withdrawn all");
        assertGe(finalUSDC, SUPPLY_AMOUNT, "should have at least original amount (with interest)");
        console2.log("Interest earned (USDC):", (finalUSDC - (SUPPLY_AMOUNT * 2 - SUPPLY_AMOUNT)) / 1e6);
    }

    // ═══════════════════════════════════════════════════════
    //  辅助函数
    // ═══════════════════════════════════════════════════════

    /// @dev 从 whale 地址转 USDC 给测试账户
    function _fundAccountWithUSDC(uint256 amount) internal {
        // 确认 whale 余额足够
        uint256 whaleBalance = IERC20(USDC).balanceOf(USDC_WHALE);
        if (whaleBalance < amount) {
            // 如果 whale 余额不足，使用 deal
            deal(USDC, address(account), amount);
        } else {
            vm.prank(USDC_WHALE);
            IERC20(USDC).transfer(address(account), amount);
        }

        console2.log("Funded account with USDC:", IERC20(USDC).balanceOf(address(account)) / 1e6);
    }

    /// @dev Owner 直接操作存入 Aave（用于测试前置条件）
    function _supplyToAave(uint256 amount) internal {
        vm.startPrank(owner);
        account.execute(USDC, 0, abi.encodeCall(IERC20.approve, (AAVE_V3_POOL, amount)));
        account.execute(AAVE_V3_POOL, 0, abi.encodeCall(IPool.supply, (USDC, amount, address(account), 0)));
        vm.stopPrank();
    }
}
