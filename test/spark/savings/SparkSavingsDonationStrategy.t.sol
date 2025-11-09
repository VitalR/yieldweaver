// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {
    YieldDonatingTokenizedStrategy
} from "@octant-v2-core/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { ITokenizedStrategy } from "@octant-v2-core/core/interfaces/ITokenizedStrategy.sol";

import { SparkSavingsDonationStrategy } from "src/spark/savings/SparkSavingsDonationStrategy.sol";
import { MockSparkVault } from "test/mocks/MockSparkVault.sol";
import { MockUSDC } from "test/mocks/MockUSDC.sol";
import { Errors } from "src/common/Errors.sol";

contract SparkSavingsDonationStrategyUnitTest is Test {
    ERC20 public usdc;
    MockSparkVault public sparkVault;
    SparkSavingsDonationStrategy public strategy;
    ITokenizedStrategy public tokenized;

    address public management = makeAddr("management");
    address public keeper = makeAddr("keeper");
    address public emergencyAdmin = makeAddr("emergencyAdmin");
    address public donationAddress = makeAddr("donationAddress");
    address public user = makeAddr("user");
    address public user2 = makeAddr("user2");

    uint256 constant RAY = 1e27;
    uint256 constant ONE_USDC = 1e6;
    bool constant ENABLE_BURNING = true;

    function setUp() public {
        usdc = new MockUSDC();
        sparkVault = new MockSparkVault(usdc, "spUSDC Mock", "spUSDC");

        YieldDonatingTokenizedStrategy tokenizedImpl = new YieldDonatingTokenizedStrategy();

        strategy = new SparkSavingsDonationStrategy(
            address(sparkVault),
            address(usdc),
            "Spark USDC YDS",
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            ENABLE_BURNING,
            address(tokenizedImpl),
            0
        );

        tokenized = ITokenizedStrategy(address(strategy));
    }

    function _airdrop(address _to, uint256 _amount) internal {
        uint256 bal = usdc.balanceOf(_to);
        deal(address(usdc), _to, bal + _amount);
    }

    function _deposit(address _user, uint256 _assets) internal {
        _airdrop(_user, _assets);
        vm.startPrank(_user);
        usdc.approve(address(strategy), _assets);
        tokenized.deposit(_assets, _user);
        vm.stopPrank();
    }

    function _forceShutdown() internal {
        bool ok;
        vm.startPrank(management);
        (ok,) = address(strategy).call(abi.encodeWithSignature("shutdownStrategy()"));
        if (!ok) (ok,) = address(strategy).call(abi.encodeWithSignature("shutdown()"));
        if (!ok) (ok,) = address(strategy).call(abi.encodeWithSignature("setShutdown(bool)", true));
        if (!ok) (ok,) = address(strategy).call(abi.encodeWithSignature("setEmergencyShutdown(bool)", true));
        vm.stopPrank();
        require(ok, "shutdown-not-supported");
    }

    function test_constructorSetsState() public view {
        assertEq(address(strategy.SPARK_VAULT()), address(sparkVault));
        assertEq(tokenized.asset(), address(usdc));
        assertEq(tokenized.management(), management);
        assertEq(tokenized.keeper(), keeper);
        assertEq(tokenized.dragonRouter(), donationAddress);
    }

    function test_deployFunds_DepositsIntoVault() public {
        _deposit(user, 10 * ONE_USDC);
        assertEq(sparkVault.balanceOf(address(strategy)), 10 * ONE_USDC);
        assertEq(usdc.balanceOf(address(sparkVault)), 10 * ONE_USDC);
    }

    function test_freeFunds_WithdrawsFromVault() public {
        _deposit(user, 10 * ONE_USDC);
        vm.startPrank(user);
        tokenized.redeem(4 * ONE_USDC, user, user);
        vm.stopPrank();
        assertEq(sparkVault.balanceOf(address(strategy)), 6 * ONE_USDC);
    }

    function test_report_MintsDonationOnProfit() public {
        uint256 amount = 100e6;
        deal(address(usdc), user, amount);
        vm.startPrank(user);
        usdc.approve(address(strategy), amount);
        (bool ok,) = address(strategy).call(abi.encodeWithSignature("deposit(uint256,address)", amount, user));
        require(ok, "deposit fail");
        vm.stopPrank();

        sparkVault.setChi((sparkVault.nowChi() * 105) / 100);

        vm.prank(keeper);
        (uint256 profit, uint256 loss) = tokenized.report();
        assertGt(profit, 0);
        assertEq(loss, 0);
        uint256 donatedAssets = tokenized.convertToAssets(tokenized.balanceOf(donationAddress));
        assertApproxEqRel(donatedAssets, (amount * 5) / 100, 0.005e18);
    }

    function test_limits_MirrorVaultCaps() public {
        assertEq(strategy.availableDepositLimit(address(this)), type(uint256).max);
        assertEq(strategy.availableWithdrawLimit(address(this)), 0);

        _deposit(user, 7 * ONE_USDC);
        uint256 expected =
            usdc.balanceOf(address(strategy)) + sparkVault.convertToAssets(sparkVault.balanceOf(address(strategy)));
        assertEq(strategy.availableWithdrawLimit(address(this)), expected);
    }

    function test_tend_DeploysWhenIdleAboveThreshold() public {
        vm.prank(management);
        strategy.setTendThreshold(1 * ONE_USDC);
        _airdrop(address(strategy), 3 * ONE_USDC);

        uint256 idleBefore = usdc.balanceOf(address(strategy));
        vm.prank(keeper);
        tokenized.tend();
        uint256 idleAfter = usdc.balanceOf(address(strategy));
        uint256 shares = sparkVault.balanceOf(address(strategy));

        assertLt(idleAfter, idleBefore);
        assertGt(shares, 0);
    }

    function test_emergencyWithdraw_DoesNotRedeploy() public {
        _deposit(user, 10 * ONE_USDC);
        _forceShutdown();

        uint256 idleBefore = usdc.balanceOf(address(strategy));
        vm.prank(emergencyAdmin);
        tokenized.emergencyWithdraw(6 * ONE_USDC);
        uint256 idleAfter = usdc.balanceOf(address(strategy));
        assertGt(idleAfter, idleBefore);

        (bool shouldTend,) = strategy.tendTrigger();
        assertFalse(shouldTend);

        vm.prank(keeper);
        tokenized.report();

        uint256 userBalBefore = usdc.balanceOf(user);
        vm.prank(user);
        tokenized.redeem(4 * ONE_USDC, user, user);
        assertGe(usdc.balanceOf(user), userBalBefore + 4 * ONE_USDC);
    }

    function test_deployFunds_usesReferralBranch() public {
        uint256 amount = 5 * ONE_USDC;
        vm.prank(management);
        strategy.setDeployThreshold(0);
        vm.prank(management);
        strategy.setReferral(42);

        vm.expectCall(
            address(sparkVault),
            abi.encodeWithSignature("deposit(uint256,address,uint16)", amount, address(strategy), uint16(42))
        );

        _deposit(user, amount);
    }

    function test_availableDepositLimit_fallbackToMax() public {
        vm.mockCallRevert(address(sparkVault), abi.encodeWithSignature("maxDeposit(address)", address(this)), "");
        uint256 lim = strategy.availableDepositLimit(address(this));
        vm.clearMockedCalls();
        assertEq(lim, type(uint256).max);
    }

    function test_availableWithdrawLimit_fallbackToIdlePlusAssets() public {
        _deposit(user, 10 * ONE_USDC);
        vm.mockCallRevert(address(sparkVault), abi.encodeWithSignature("maxWithdraw(address)", address(this)), "");
        uint256 expected =
            usdc.balanceOf(address(strategy)) + sparkVault.convertToAssets(sparkVault.balanceOf(address(strategy)));
        uint256 lim = strategy.availableWithdrawLimit(address(this));
        vm.clearMockedCalls();
        assertEq(lim, expected);
    }

    function test_availableDepositLimit_respectsVaultCap() public {
        _deposit(user, 4 * ONE_USDC);
        sparkVault.setDepositCap(6 * ONE_USDC);
        uint256 limit = strategy.availableDepositLimit(address(this));
        assertEq(limit, 2 * ONE_USDC);
    }

    function test_availableDepositLimit_fallbackToMaxOnRevert() public {
        vm.mockCallRevert(address(sparkVault), abi.encodeWithSignature("maxDeposit(address)", address(this)), "");
        uint256 limit = strategy.availableDepositLimit(address(this));
        vm.clearMockedCalls();
        assertEq(limit, type(uint256).max);
    }

    function test_availableWithdrawLimit_respectsVaultLimit() public {
        _deposit(user, 9 * ONE_USDC);
        uint256 limit = strategy.availableWithdrawLimit(address(this));
        assertEq(limit, 9 * ONE_USDC);
    }

    function test_idleAndDeployedViewsReflectBalances() public {
        _deposit(user, 12 * ONE_USDC);

        assertEq(strategy.idle(), 0);
        uint256 shares = sparkVault.balanceOf(address(strategy));
        uint256 expectedDeployed = sparkVault.convertToAssets(shares);
        assertApproxEqAbs(strategy.deployed(), expectedDeployed, 1);
    }

    function test_totalViewMatchesIdlePlusDeployed() public {
        _deposit(user, 10 * ONE_USDC);
        _airdrop(address(strategy), 3 * ONE_USDC);
        uint256 idleBal = strategy.idle();
        uint256 deployedBal = strategy.deployed();
        assertEq(strategy.totalView(), idleBal + deployedBal);
    }

    function test_sparkChi_returnsNowChiValue() public {
        uint256 newChi = (sparkVault.nowChi() * 103) / 100;
        sparkVault.setChi(newChi);
        uint256 chi = strategy.sparkChi();
        assertEq(chi, sparkVault.nowChi());
    }

    function test_sparkChi_returnsZeroWhenAllCallsFail() public {
        vm.mockCallRevert(address(sparkVault), abi.encodeWithSignature("nowChi()"), "");
        vm.mockCallRevert(address(sparkVault), abi.encodeWithSignature("chi()"), "");
        uint256 chi = strategy.sparkChi();
        vm.clearMockedCalls();
        assertEq(chi, 0);
    }

    function test_sparkVsr_returnsZeroOnRevert() public {
        vm.mockCallRevert(address(sparkVault), abi.encodeWithSignature("vsr()"), "");
        uint256 vsr = strategy.sparkVsr();
        vm.clearMockedCalls();
        assertEq(vsr, 0);
    }

    function test_sparkChi_fallsBackToChi() public {
        sparkVault.setChi((sparkVault.nowChi() * 102) / 100);
        vm.mockCallRevert(address(sparkVault), abi.encodeWithSignature("nowChi()"), "");
        uint256 chi = strategy.sparkChi();
        vm.clearMockedCalls();
        assertEq(chi, sparkVault.chi());
    }

    function test_observability_sparkVsrChi_MatchesVaultAndMonotonic() public {
        assertEq(strategy.sparkVsr(), RAY);
        assertEq(strategy.sparkChi(), RAY);

        uint256 vsrAllowed = sparkVault.MAX_VSR();
        sparkVault.setVsr(vsrAllowed);
        assertEq(strategy.sparkVsr(), vsrAllowed);

        sparkVault.setChi((sparkVault.nowChi() * 105) / 100);
        assertEq(strategy.sparkChi(), sparkVault.nowChi());

        uint256 cBefore = strategy.sparkChi();
        sparkVault.accrue(7 days);
        uint256 cAfter = strategy.sparkChi();
        assertGt(cAfter, cBefore);
    }

    function test_rotateDonationAddress_WithCooldown() public {
        address newDonation = vm.addr(777);
        vm.prank(management);
        tokenized.setDragonRouter(newDonation);
        skip(14 days + 1);
        tokenized.finalizeDragonRouterChange();
        assertEq(tokenized.dragonRouter(), newDonation);
    }

    function test_setDeployThreshold_onlyManagement() public {
        uint256 prev = strategy.deployThreshold();
        vm.expectRevert();
        vm.prank(user);
        strategy.setDeployThreshold(prev + 1);
    }

    function test_setDeployThreshold_updatesStateAndEmits() public {
        uint256 oldT = strategy.deployThreshold();
        uint256 newT = oldT + 123;
        vm.expectEmit(true, true, true, true);
        emit SparkSavingsDonationStrategy.DeployThresholdUpdated(oldT, newT);
        vm.prank(management);
        strategy.setDeployThreshold(newT);
        assertEq(strategy.deployThreshold(), newT);
    }

    function test_deployRespectsThreshold_blockedWhenIdleBelow() public {
        vm.prank(management);
        strategy.setDeployThreshold(20_000_000);

        uint256 amount = 10_000_000;
        deal(address(usdc), user, amount);
        vm.startPrank(user);
        usdc.approve(address(strategy), amount);
        (bool ok,) = address(strategy).call(abi.encodeWithSignature("deposit(uint256,address)", amount, user));
        require(ok, "deposit fail");
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(strategy)), amount);
        assertEq(sparkVault.balanceOf(address(strategy)), 0);
    }

    function test_deployRespectsThreshold_zeroDeploysImmediately() public {
        vm.prank(management);
        strategy.setDeployThreshold(0);

        uint256 amount = 10_000_000;
        deal(address(usdc), user, amount);
        vm.startPrank(user);
        usdc.approve(address(strategy), amount);
        (bool ok,) = address(strategy).call(abi.encodeWithSignature("deposit(uint256,address)", amount, user));
        require(ok, "deposit fail");
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(strategy)), 0);
        assertEq(sparkVault.balanceOf(address(strategy)), amount);
    }

    function test_constructorZeroAddressesRevert() public {
        YieldDonatingTokenizedStrategy tokenizedImpl = new YieldDonatingTokenizedStrategy();
        vm.expectRevert(Errors.ZeroAddress.selector);
        new SparkSavingsDonationStrategy(
            address(0),
            address(usdc),
            "Spark USDC YDS",
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            ENABLE_BURNING,
            address(tokenizedImpl),
            0
        );
    }

    function test_constructorInvalidAssetReverts() public {
        YieldDonatingTokenizedStrategy tokenizedImpl = new YieldDonatingTokenizedStrategy();
        MockUSDC altAsset = new MockUSDC();
        vm.expectRevert(Errors.InvalidAsset.selector);
        new SparkSavingsDonationStrategy(
            address(sparkVault),
            address(altAsset),
            "Spark USDC YDS",
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            ENABLE_BURNING,
            address(tokenizedImpl),
            0
        );
    }

    function test_setTendThreshold_onlyManagement() public {
        vm.expectRevert();
        vm.prank(user);
        strategy.setTendThreshold(123);
    }

    function test_setTendThreshold_updatesState() public {
        vm.prank(management);
        strategy.setTendThreshold(12_345);
        assertEq(strategy.tendIdleThreshold(), 12_345);
    }

    function test_setReferral_onlyManagement() public {
        vm.expectRevert();
        vm.prank(user);
        strategy.setReferral(7);
    }

    function test_setReferral_updatesStateAndEmits() public {
        vm.expectEmit(false, false, false, true);
        emit SparkSavingsDonationStrategy.ReferralUpdated(9);

        vm.prank(management);
        strategy.setReferral(9);
        assertEq(strategy.referral(), 9);
    }

    function test_pokeDrip_onlyManagement() public {
        vm.expectRevert();
        vm.prank(user);
        strategy.pokeDrip();
    }

    function test_pokeDrip_updatesChiWhenSupported() public {
        uint256 beforeChi = sparkVault.nowChi();
        vm.prank(management);
        strategy.pokeDrip();
        uint256 afterChi = sparkVault.nowChi();
        assertGe(afterChi, beforeChi);
    }

    function test_tendTrigger_falseWhenBelowThreshold() public {
        vm.prank(management);
        strategy.setTendThreshold(5 * ONE_USDC);
        _airdrop(address(strategy), 1 * ONE_USDC);
        (bool should,) = strategy.tendTrigger();
        assertFalse(should);
    }

    function _tokenized() internal view returns (ITokenizedStrategy) {
        return ITokenizedStrategy(address(strategy));
    }

    function test_invariant_NoPhantomShares() public {
        uint256 amount = 100e6;
        deal(address(usdc), user, amount);
        vm.startPrank(user);
        usdc.approve(address(strategy), amount);
        _tokenized().deposit(amount, user);
        vm.stopPrank();

        sparkVault.setChi((sparkVault.nowChi() * 105) / 100);
        vm.prank(keeper);
        _tokenized().report();

        uint256 ts = _tokenized().totalSupply();
        uint256 userShares = _tokenized().balanceOf(user);
        uint256 donationShares = _tokenized().balanceOf(donationAddress);
        assertEq(userShares + donationShares, ts);
    }

    function test_invariant_TotalAssetsMonotonicWithChi() public {
        uint256 amt = 1_000_000e6;
        deal(address(usdc), user, amt);
        vm.startPrank(user);
        usdc.approve(address(strategy), amt);
        _tokenized().deposit(amt, user);
        vm.stopPrank();

        uint256 beforeAssets = _tokenized().totalAssets();
        sparkVault.setChi((sparkVault.nowChi() * 110) / 100);
        vm.prank(keeper);
        _tokenized().report();
        uint256 afterAssets = _tokenized().totalAssets();
        assertGe(afterAssets, beforeAssets);
    }

    function test_invariant_EmergencyWithdrawBounded() public {
        uint256 amt = 5_000_000e6;
        deal(address(usdc), user, amt);
        vm.startPrank(user);
        usdc.approve(address(strategy), amt);
        _tokenized().deposit(amt, user);
        vm.stopPrank();

        uint256 sharesInVault = sparkVault.balanceOf(address(strategy));
        uint256 deployedBefore = sparkVault.convertToAssets(sharesInVault);
        uint256 idleBefore = usdc.balanceOf(address(strategy));

        vm.prank(management);
        (bool s1,) = address(strategy).call(abi.encodeWithSignature("shutdownStrategy()"));
        require(s1, "shutdown failed");

        uint256 request = amt / 3;
        vm.prank(emergencyAdmin);
        _tokenized().emergencyWithdraw(request);

        uint256 deployedAfter = sparkVault.convertToAssets(sparkVault.balanceOf(address(strategy)));
        uint256 idleAfter = usdc.balanceOf(address(strategy));

        if (idleAfter > idleBefore) {
            assertLe(idleAfter - idleBefore, request);
        }
        if (deployedBefore > deployedAfter) {
            assertLe(deployedBefore - deployedAfter, request, "withdrew more than requested");
        }
    }
}
