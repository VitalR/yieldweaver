// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import { SparkMultiStrategyVault } from "src/spark/multistrategy/SparkMultiStrategyVault.sol";
import { MockYieldStrategy } from "test/mocks/MockYieldStrategy.sol";
import { Errors } from "src/common/Errors.sol";

contract SparkMultiStrategyVaultUnitTest is Test {
    uint256 constant BPS = 10_000;

    ERC20Mock internal asset;
    MockYieldStrategy internal savings;
    MockYieldStrategy internal lend;
    SparkMultiStrategyVault internal vault;

    address internal user = address(0xBEEF);

    function setUp() public {
        asset = new ERC20Mock();
        savings = new MockYieldStrategy(asset);
        lend = new MockYieldStrategy(asset);

        address[] memory strategies = new address[](2);
        strategies[0] = address(savings);
        strategies[1] = address(lend);

        uint16[] memory targets = new uint16[](2);
        targets[0] = 4000;
        targets[1] = 4000;

        vault = new SparkMultiStrategyVault(
            asset, "Spark Multi Strategy Vault", "smSPARK", address(this), strategies, targets, 2000
        );

        asset.mint(user, 1000e18);
        vm.startPrank(user);
        asset.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function test_depositRebalancesToTargets() public {
        vm.prank(user);
        vault.deposit(1000e18, user);

        (address[] memory strategyVaults,, uint16 idleBps) = vault.strategies();
        assertEq(idleBps, 2000);

        uint256 idleBalance = asset.balanceOf(address(vault));
        assertApproxEqAbs(idleBalance, 200e18, 1e14);

        for (uint256 i; i < strategyVaults.length; i++) {
            IERC4626 strategy = IERC4626(strategyVaults[i]);
            uint256 shares = strategy.balanceOf(address(vault));
            uint256 assetsInvested = strategy.convertToAssets(shares);
            assertApproxEqAbs(assetsInvested, 400e18, 1e14);
        }
    }

    function test_mintRebalancesToTargets() public {
        vm.prank(user);
        vault.mint(1000e18, user);

        uint256 idleBalance = asset.balanceOf(address(vault));
        assertApproxEqAbs(idleBalance, 200e18, 1e14);

        IERC4626 savingsVault = IERC4626(address(savings));
        IERC4626 lendVault = IERC4626(address(lend));

        uint256 savingsAssets = savingsVault.convertToAssets(savingsVault.balanceOf(address(vault)));
        uint256 lendAssets = lendVault.convertToAssets(lendVault.balanceOf(address(vault)));

        assertApproxEqAbs(savingsAssets, 400e18, 1e14);
        assertApproxEqAbs(lendAssets, 400e18, 1e14);
    }

    function test_depositZeroAmountReverts() public {
        vm.expectRevert(Errors.ZeroAmount.selector);
        vm.prank(user);
        vault.deposit(0, user);
    }

    function test_mintZeroAmountReverts() public {
        vm.expectRevert(Errors.ZeroAmount.selector);
        vm.prank(user);
        vault.mint(0, user);
    }

    function test_withdrawZeroAmountReverts() public {
        vm.prank(user);
        vault.deposit(1000e18, user);

        vm.expectRevert(Errors.ZeroAmount.selector);
        vm.prank(user);
        vault.withdraw(0, user, user);
    }

    function test_redeemZeroAmountReverts() public {
        vm.prank(user);
        vault.deposit(1000e18, user);

        vm.expectRevert(Errors.ZeroAmount.selector);
        vm.prank(user);
        vault.redeem(0, user, user);
    }

    function test_withdrawUsesQueueOrder() public {
        vm.prank(user);
        vault.deposit(1000e18, user);

        uint16[] memory queue = new uint16[](2);
        queue[0] = 1;
        queue[1] = 0;
        vault.setWithdrawalQueue(queue);

        vm.prank(user);
        vault.withdraw(600e18, user, user);

        IERC4626 savingsVault = IERC4626(address(savings));
        IERC4626 lendVault = IERC4626(address(lend));

        uint256 lendAssets = lendVault.convertToAssets(lendVault.balanceOf(address(vault)));
        assertApproxEqAbs(lendAssets, 0, 1);

        uint256 savingsAssets = savingsVault.convertToAssets(savingsVault.balanceOf(address(vault)));
        assertApproxEqAbs(savingsAssets, 320e18, 1e14);

        uint256 idleBalance = asset.balanceOf(address(vault));
        assertApproxEqAbs(idleBalance, 80e18, 1e14);

        assertApproxEqAbs(lendAssets + savingsAssets + idleBalance, 400e18, 1e14);
    }

    function test_redeemHonoursIdleBuffer() public {
        vm.prank(user);
        vault.deposit(1000e18, user);

        vm.prank(user);
        vault.redeem(400e18, user, user);

        uint256 idleBalance = asset.balanceOf(address(vault));
        uint256 totalAssets = vault.totalAssets();
        (,, uint16 idleBps) = vault.strategies();
        uint256 expectedIdle = (totalAssets * idleBps) / BPS;
        assertApproxEqAbs(idleBalance, expectedIdle, 1e14);
    }

    function test_withdrawQueueDifferentPriority() public {
        vm.prank(user);
        vault.deposit(1000e18, user);

        uint16[] memory queue = new uint16[](2);
        queue[0] = 0;
        queue[1] = 1;
        vault.setWithdrawalQueue(queue);

        vm.prank(user);
        vault.withdraw(600e18, user, user);

        IERC4626 savingsVault = IERC4626(address(savings));
        IERC4626 lendVault = IERC4626(address(lend));

        uint256 savingsAssets = savingsVault.convertToAssets(savingsVault.balanceOf(address(vault)));
        uint256 lendAssets = lendVault.convertToAssets(lendVault.balanceOf(address(vault)));
        uint256 idleBalance = asset.balanceOf(address(vault));

        assertApproxEqAbs(savingsAssets, 0, 1);
        assertApproxEqAbs(lendAssets, 320e18, 1e14);
        assertApproxEqAbs(idleBalance, 80e18, 1e14);
        assertApproxEqAbs(lendAssets + savingsAssets + idleBalance, 400e18, 1e14);
    }

    function test_ownerCanUpdateTargets() public {
        uint16[] memory newTargets = new uint16[](2);
        newTargets[0] = 3000;
        newTargets[1] = 5000;

        vault.setTargets(2000, newTargets);

        (, uint16[] memory storedTargets, uint16 idleBps) = vault.strategies();
        assertEq(idleBps, 2000);
        assertEq(storedTargets[0], 3000);
        assertEq(storedTargets[1], 5000);
    }

    function test_rejectsInvalidTargetSum() public {
        uint16[] memory badTargets = new uint16[](2);
        badTargets[0] = 5000;
        badTargets[1] = 5000;

        vm.expectRevert(Errors.TargetSumMismatch.selector);
        vault.setTargets(1000, badTargets);
    }

    function test_nonOwnerCannotSetTargets() public {
        uint16[] memory newTargets = new uint16[](2);
        newTargets[0] = 3000;
        newTargets[1] = 5000;

        vm.expectRevert();
        vm.prank(user);
        vault.setTargets(2000, newTargets);
    }

    function test_setWithdrawalQueueRejectsDuplicates() public {
        uint16[] memory queue = new uint16[](2);
        queue[0] = 0;
        queue[1] = 0;

        vm.expectRevert(Errors.InvalidQueue.selector);
        vault.setWithdrawalQueue(queue);
    }

    function test_setWithdrawalQueueRejectsOutOfBoundsIndex() public {
        uint16[] memory queue = new uint16[](1);
        queue[0] = 5;

        vm.expectRevert(Errors.InvalidQueue.selector);
        vault.setWithdrawalQueue(queue);
    }

    function test_manualRebalanceInvestsSurplusIdle() public {
        vm.prank(user);
        vault.deposit(1000e18, user);

        asset.mint(address(vault), 200e18);
        vault.rebalance();

        uint256 idleBalance = asset.balanceOf(address(vault));
        uint256 total = vault.totalAssets();
        (,, uint16 idleBps) = vault.strategies();
        uint256 expectedIdle = (total * idleBps) / BPS;
        assertApproxEqAbs(idleBalance, expectedIdle, 1e14);
    }

    function test_constructorZeroAssetReverts() public {
        address[] memory strategies = new address[](1);
        strategies[0] = address(savings);
        uint16[] memory targets = new uint16[](1);
        targets[0] = 8000;

        vm.expectRevert(Errors.InvalidAsset.selector);
        new SparkMultiStrategyVault(
            IERC20(address(0)), "Spark Multi Strategy Vault", "smSPARK", address(this), strategies, targets, 2000
        );
    }

    function test_constructorEmptyMetadataReverts() public {
        address[] memory strategies = new address[](1);
        strategies[0] = address(savings);
        uint16[] memory targets = new uint16[](1);
        targets[0] = 8000;

        vm.expectRevert(Errors.InvalidName.selector);
        new SparkMultiStrategyVault(asset, "", "smSPARK", address(this), strategies, targets, 2000);
    }

    function test_setTargetsLengthMismatchReverts() public {
        uint16[] memory targets = new uint16[](1);
        targets[0] = 5000;

        vm.expectRevert(Errors.InvalidTargetsLength.selector);
        vault.setTargets(5000, targets);
    }

    function test_withdrawZeroReceiverReverts() public {
        vm.prank(user);
        vault.deposit(1000e18, user);

        vm.expectRevert(Errors.InvalidReceiver.selector);
        vault.withdraw(100e18, address(0), user);
    }

    function test_redeemZeroOwnerReverts() public {
        vm.prank(user);
        vault.deposit(1000e18, user);

        vm.expectRevert(Errors.InvalidOwner.selector);
        vault.redeem(100e18, user, address(0));
    }

    function test_withdrawBeyondLiquidityReverts() public {
        vm.prank(user);
        vault.deposit(500e18, user);

        vm.expectRevert(Errors.InsufficientLiquidity.selector);
        vault.withdraw(700e18, user, user);
    }

    function test_rebalanceWhenEmptyEmitsZeroEvent() public {
        vm.expectEmit(false, false, false, true);
        emit SparkMultiStrategyVault.Rebalanced(0, 0);
        vault.rebalance();
    }

    function test_constructorNoStrategiesReverts() public {
        address[] memory strategies = new address[](0);
        uint16[] memory targets = new uint16[](0);

        vm.expectRevert(Errors.NoStrategiesDefined.selector);
        new SparkMultiStrategyVault(
            asset, "Spark Multi Strategy Vault", "smSPARK", address(this), strategies, targets, 2000
        );
    }

    function test_constructorMismatchedStrategiesReverts() public {
        address[] memory strategies = new address[](2);
        strategies[0] = address(savings);
        strategies[1] = address(lend);
        uint16[] memory targets = new uint16[](1);
        targets[0] = 8000;

        vm.expectRevert(Errors.InvalidTargetsLength.selector);
        new SparkMultiStrategyVault(
            asset, "Spark Multi Strategy Vault", "smSPARK", address(this), strategies, targets, 2000
        );
    }

    function test_constructorStrategyZeroAddressReverts() public {
        address[] memory strategies = new address[](1);
        strategies[0] = address(0);
        uint16[] memory targets = new uint16[](1);
        targets[0] = 8000;

        vm.expectRevert(Errors.InvalidStrategyAddress.selector);
        new SparkMultiStrategyVault(
            asset, "Spark Multi Strategy Vault", "smSPARK", address(this), strategies, targets, 2000
        );
    }

    function test_withdrawalQueueViewReflectsUpdates() public {
        uint16[] memory initialQueue = vault.withdrawalQueue();
        assertEq(initialQueue.length, 2);
        assertEq(initialQueue[0], 0);
        assertEq(initialQueue[1], 1);

        uint16[] memory queue = new uint16[](2);
        queue[0] = 1;
        queue[1] = 0;
        vault.setWithdrawalQueue(queue);

        uint16[] memory updatedQueue = vault.withdrawalQueue();
        assertEq(updatedQueue[0], 1);
        assertEq(updatedQueue[1], 0);
    }
}
