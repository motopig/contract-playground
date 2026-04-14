// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../src/token/TimeWeightedGrowthToken.sol";

contract TimeWeightedGrowthTokenTest is Test {
    TimeWeightedGrowthToken public token;

    address public owner = address(1);
    address public user1 = address(2);
    address public user2 = address(3);

    uint256 constant INITIAL_SUPPLY = 1000000 * 10 ** 18;
    uint256 constant ANNUAL_RATE = 1000; // 10%
    uint256 constant MAX_SUPPLY = 10000000 * 10 ** 18;

    function setUp() public {
        vm.startPrank(owner);
        token = new TimeWeightedGrowthToken("Time Growth Token", "TGT", ANNUAL_RATE, MAX_SUPPLY);

        // Mint initial tokens to users
        token.mint(user1, 100000 * 10 ** 18);
        token.mint(user2, 50000 * 10 ** 18);
        vm.stopPrank();
    }

    function testInitialState() public view {
        assertEq(token.name(), "Time Growth Token");
        assertEq(token.symbol(), "TGT");
        assertEq(token.annualYieldRate(), ANNUAL_RATE);
        assertEq(token.maxSupply(), MAX_SUPPLY);
        assertTrue(token.growthEnabled());
    }

    function testBalanceGrowthAfter30Days() public {
        uint256 initialBalance = token.getActualBalance(user1);

        // Fast forward 30 days
        vm.warp(block.timestamp + 30 days);

        uint256 pendingRewards = token.pendingRewards(user1);
        uint256 totalBalance = token.balanceOf(user1);

        assertGt(pendingRewards, 0, "Should have pending rewards");
        assertEq(totalBalance, initialBalance + pendingRewards);

        // 计算预期收益: 100000 * 0.1 * (30/365) * 1.0 = ~821.9 tokens
        uint256 expectedRewards = (initialBalance * ANNUAL_RATE * 30 days * 10000) / (10000 * 365 days * 10000);
        assertApproxEqRel(pendingRewards, expectedRewards, 0.01e18); // 1% tolerance
    }

    function testBalanceGrowthAfter90Days() public {
        uint256 initialBalance = token.getActualBalance(user1);

        // Fast forward 90 days (should get 1.2x multiplier)
        vm.warp(block.timestamp + 90 days);

        uint256 pendingRewards = token.pendingRewards(user1);

        // 计算预期收益: 100000 * 0.1 * (90/365) * 1.2
        uint256 expectedRewards = (initialBalance * ANNUAL_RATE * 90 days * 12000) / (10000 * 365 days * 10000);
        assertApproxEqRel(pendingRewards, expectedRewards, 0.01e18);
    }

    function testBalanceGrowthAfter180Days() public {
        uint256 initialBalance = token.getActualBalance(user1);

        // Fast forward 180 days (should get 1.5x multiplier)
        vm.warp(block.timestamp + 180 days);

        uint256 pendingRewards = token.pendingRewards(user1);

        // 计算预期收益: 100000 * 0.1 * (180/365) * 1.5
        uint256 expectedRewards = (initialBalance * ANNUAL_RATE * 180 days * 15000) / (10000 * 365 days * 10000);
        assertApproxEqRel(pendingRewards, expectedRewards, 0.01e18);
    }

    function testBalanceGrowthAfter365Days() public {
        uint256 initialBalance = token.getActualBalance(user1);

        // Fast forward 365 days (should get 2.0x multiplier)
        vm.warp(block.timestamp + 365 days);

        uint256 pendingRewards = token.pendingRewards(user1);

        // 计算预期收益: 100000 * 0.1 * 1.0 * 2.0 = 20000 tokens
        uint256 expectedRewards = (initialBalance * ANNUAL_RATE * 365 days * 20000) / (10000 * 365 days * 10000);
        assertApproxEqRel(pendingRewards, expectedRewards, 0.01e18);
    }

    function testClaimRewards() public {
        // Fast forward 30 days
        vm.warp(block.timestamp + 30 days);

        uint256 pendingBefore = token.pendingRewards(user1);
        uint256 balanceBefore = token.getActualBalance(user1);

        vm.prank(user1);
        token.claimRewards();

        uint256 balanceAfter = token.getActualBalance(user1);
        uint256 pendingAfter = token.pendingRewards(user1);

        assertEq(pendingAfter, 0, "Pending should be 0 after claim");
        assertEq(balanceAfter, balanceBefore + pendingBefore, "Balance should increase");
    }

    function testTransferUpdatesRewards() public {
        // Fast forward 30 days
        vm.warp(block.timestamp + 30 days);

        uint256 user1PendingBefore = token.pendingRewards(user1);
        uint256 user2PendingBefore = token.pendingRewards(user2);

        // Transfer from user1 to user2
        vm.prank(user1);
        token.transfer(user2, 1000 * 10 ** 18);

        // Rewards should be accrued
        assertEq(token.accruedRewards(user1), user1PendingBefore);
        assertEq(token.accruedRewards(user2), user2PendingBefore);

        // Pending should reset
        assertEq(token.pendingRewards(user1), 0);
        assertEq(token.pendingRewards(user2), 0);
    }

    function testUpdateYieldRate() public {
        vm.prank(owner);
        token.setAnnualYieldRate(2000); // Change to 20%

        assertEq(token.annualYieldRate(), 2000);
    }

    function testCannotSetTooHighYieldRate() public {
        vm.prank(owner);
        vm.expectRevert("Rate too high");
        token.setAnnualYieldRate(10001); // > 100%
    }

    function testToggleGrowth() public {
        vm.startPrank(owner);
        token.toggleGrowth(false);
        assertFalse(token.growthEnabled());

        // Fast forward 30 days
        vm.warp(block.timestamp + 30 days);

        // Should have no rewards when disabled
        assertEq(token.pendingRewards(user1), 0);

        // Re-enable
        token.toggleGrowth(true);
        vm.stopPrank();
    }

    function testEstimateFutureRewards() public view {
        uint256 estimated = token.estimateFutureRewards(user1, 365 days);

        uint256 initialBalance = token.getActualBalance(user1);
        uint256 expected = (initialBalance * ANNUAL_RATE * 365 days * 20000) / (10000 * 365 days * 10000);

        assertApproxEqRel(estimated, expected, 0.01e18);
    }

    function testGetUserInfo() public {
        vm.warp(block.timestamp + 30 days);

        (
            uint256 actualBalance,
            uint256 accruedAmount,
            uint256 pendingAmount,
            uint256 totalBalance,
            uint256 lastUpdate,
            uint256 holdingDuration
        ) = token.getUserInfo(user1);

        assertGt(actualBalance, 0);
        assertEq(accruedAmount, 0);
        assertGt(pendingAmount, 0);
        assertEq(totalBalance, actualBalance + accruedAmount + pendingAmount);
        assertGt(holdingDuration, 0);
    }

    function testBurn() public {
        uint256 balanceBefore = token.getActualBalance(user1);
        uint256 burnAmount = 1000 * 10 ** 18;

        vm.prank(user1);
        token.burn(burnAmount);

        uint256 balanceAfter = token.getActualBalance(user1);
        assertEq(balanceAfter, balanceBefore - burnAmount);
    }

    function testMaxSupplyEnforcement() public {
        vm.startPrank(owner);

        // Try to mint more than max supply
        uint256 remaining = MAX_SUPPLY - token.totalSupply();

        vm.expectRevert("Exceeds max supply");
        token.mint(user1, remaining + 1);

        vm.stopPrank();
    }

    function testWeightConfigUpdate() public {
        vm.prank(owner);
        token.setWeightConfig(0, 60 days, 11000); // Update first config

        (uint256 threshold, uint256 multiplier) = token.weightConfigs(0);
        assertEq(threshold, 60 days);
        assertEq(multiplier, 11000);
    }

    function testCompoundGrowth() public {
        uint256 initialBalance = token.getActualBalance(user1);

        // First period: 30 days
        skip(30 days);
        console.log("block.timestamp after first skip (30 days):", block.timestamp);

        vm.prank(user1);
        token.claimRewards();
        console.log("block.timestamp after first claim:", block.timestamp);
        uint256 balanceAfterFirstClaim = token.getActualBalance(user1);
        assertGt(balanceAfterFirstClaim, initialBalance);

        // Second period: another 30 days
        skip(30 days);
        console.log("block.timestamp after second skip (30 days):", block.timestamp);

        uint256 pendingSecond = token.pendingRewards(user1);
        console.log("Pending Rewards for second period:", pendingSecond);

        // 计算期望值：30 天，1.0x 权重
        uint256 expectedFirst = (initialBalance * ANNUAL_RATE * 30 days * 10000) / (10000 * 365 days * 10000);
        uint256 expectedSecond = (balanceAfterFirstClaim * ANNUAL_RATE * 30 days * 10000) / (10000 * 365 days * 10000);

        console.log("balanceAfterFirstClaim:", balanceAfterFirstClaim);
        console.log("Expected Second Period Rewards:", expectedSecond);
        console.log("Pending Second Period Rewards:", pendingSecond);
        console.log("Expected First Period Rewards:", expectedFirst);

        assertGt(pendingSecond, expectedFirst, "Second period should yield more than first period");
        assertApproxEqRel(pendingSecond, expectedSecond, 0.01e18, "Pending should match expected rewards"); // 1% tolerance
    }
}
