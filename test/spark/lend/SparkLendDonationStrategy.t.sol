// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {
    YieldDonatingTokenizedStrategy
} from "@octant-v2-core/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { ITokenizedStrategy } from "@octant-v2-core/core/interfaces/ITokenizedStrategy.sol";

import { SparkLendDonationStrategy } from "src/spark/lend/SparkLendDonationStrategy.sol";
import { MockAavePool } from "test/mocks/MockAavePool.sol";
import { MockUSDC } from "test/mocks/MockUSDC.sol";
import { Errors } from "src/common/Errors.sol";

contract SparkLendDonationStrategyUnitTest is Test {
    ERC20 public usdc;
    MockAavePool public pool;
    SparkLendDonationStrategy public strategy;
    ITokenizedStrategy public tokenized;

    address public management = makeAddr("management");
    address public keeper = makeAddr("keeper");
    address public emergencyAdmin = makeAddr("emergencyAdmin");
    address public donationAddress = makeAddr("donationAddress");
    address public user = makeAddr("user");

    uint256 constant ONE_USDC = 1e6;

    function setUp() public {
        usdc = new MockUSDC();
        pool = new MockAavePool(usdc);

        YieldDonatingTokenizedStrategy tokenizedImpl = new YieldDonatingTokenizedStrategy();

        strategy = new SparkLendDonationStrategy(
            address(pool),
            pool.aTokenAddress(),
            address(usdc),
            "SparkLend USDC YDS",
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            true,
            address(tokenizedImpl),
            0
        );

        tokenized = ITokenizedStrategy(address(strategy));
    }

    function _airdrop(address _to, uint256 _amount) internal {
        deal(address(usdc), _to, usdc.balanceOf(_to) + _amount);
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

    function test_constructor_setsState() public view {
        assertEq(address(strategy.POOL()), address(pool));
        assertEq(address(strategy.ATOKEN()), pool.aTokenAddress());
        assertEq(tokenized.asset(), address(usdc));
        assertEq(tokenized.management(), management);
    }

    function test_deposit_supplies_to_pool() public {
        uint256 depositAmount = 10 * ONE_USDC;
        _deposit(user, depositAmount);
        assertEq(usdc.balanceOf(address(pool)), depositAmount);
        assertEq(ERC20(pool.aTokenAddress()).balanceOf(address(strategy)), depositAmount);
    }

    function test_withdraw_frees_from_pool() public {
        uint256 depositAmount = 20 * ONE_USDC;
        _deposit(user, depositAmount);
        vm.startPrank(user);
        tokenized.redeem(5 * ONE_USDC, user, user);
        vm.stopPrank();
        assertEq(ERC20(pool.aTokenAddress()).balanceOf(address(strategy)), 15 * ONE_USDC);
        assertEq(usdc.balanceOf(user), 5 * ONE_USDC);
    }

    function test_report_mints_donation_on_profit() public {
        uint256 depositAmount = 100 * ONE_USDC;
        _deposit(user, depositAmount);
        pool.accrueInterest(address(strategy), 10 * ONE_USDC);
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = tokenized.report();
        assertEq(loss, 0);
        assertGt(profit, 0);
        assertGt(tokenized.balanceOf(donationAddress), 0);
    }

    function test_available_withdraw_limit_matches_idle_plus_atoken() public {
        _deposit(user, 12 * ONE_USDC);
        uint256 expected = usdc.balanceOf(address(strategy)) + ERC20(pool.aTokenAddress()).balanceOf(address(strategy));
        assertEq(strategy.availableWithdrawLimit(address(this)), expected);
    }

    function test_tend_deploys_idle_above_threshold() public {
        vm.prank(management);
        strategy.setTendThreshold(ONE_USDC);
        _airdrop(address(strategy), 3 * ONE_USDC);
        vm.prank(keeper);
        tokenized.tend();
        assertEq(usdc.balanceOf(address(strategy)), 0);
        assertEq(ERC20(pool.aTokenAddress()).balanceOf(address(strategy)), 3 * ONE_USDC);
    }

    function test_emergency_withdraw_pulls_from_pool() public {
        _deposit(user, 8 * ONE_USDC);
        _forceShutdown();
        vm.prank(emergencyAdmin);
        tokenized.emergencyWithdraw(5 * ONE_USDC);
        assertEq(usdc.balanceOf(address(strategy)), 5 * ONE_USDC);
    }

    function test_setDeployThreshold_onlyManagement() public {
        vm.expectRevert();
        vm.prank(user);
        strategy.setDeployThreshold(123);
    }

    function test_setDeployThreshold_updatesState() public {
        vm.prank(management);
        strategy.setDeployThreshold(321);
        assertEq(strategy.deployThreshold(), 321);
    }

    function test_setTendThreshold_onlyManagement() public {
        vm.expectRevert();
        vm.prank(user);
        strategy.setTendThreshold(55);
    }

    function test_setTendThreshold_updatesState() public {
        vm.prank(management);
        strategy.setTendThreshold(77);
        assertEq(strategy.tendIdleThreshold(), 77);
    }

    function test_setReferral_onlyManagement() public {
        vm.expectRevert();
        vm.prank(user);
        strategy.setReferral(11);
    }

    function test_setReferral_updatesStateAndEmits() public {
        vm.expectEmit(false, false, false, true);
        emit SparkLendDonationStrategy.ReferralUpdated(16);
        vm.prank(management);
        strategy.setReferral(16);
        assertEq(strategy.referral(), 16);
    }

    function test_tendTrigger_shutdownReturnsFalse() public {
        _forceShutdown();
        (bool should,) = strategy.tendTrigger();
        assertFalse(should);
    }

    function test_idleReflectsHeldAssets() public {
        _airdrop(address(strategy), 7 * ONE_USDC);
        assertEq(strategy.idle(), 7 * ONE_USDC);
    }

    function test_deployedReflectsATokenBalance() public {
        uint256 depositAmount = 9 * ONE_USDC;
        _deposit(user, depositAmount);
        assertEq(strategy.deployed(), depositAmount);
    }

    function test_totalViewMatchesIdlePlusDeployed() public {
        uint256 depositAmount = 6 * ONE_USDC;
        _deposit(user, depositAmount);
        _airdrop(address(strategy), 3 * ONE_USDC);
        uint256 idleBal = strategy.idle();
        uint256 deployedBal = strategy.deployed();
        assertEq(strategy.totalView(), idleBal + deployedBal);
    }

    function test_constructorZeroAddressReverts() public {
        YieldDonatingTokenizedStrategy tokenizedImpl = new YieldDonatingTokenizedStrategy();
        address aToken = pool.aTokenAddress();
        vm.expectRevert("ZERO ADDRESS");
        new SparkLendDonationStrategy(
            address(pool),
            aToken,
            address(usdc),
            "SparkLend USDC YDS",
            management,
            address(0),
            emergencyAdmin,
            donationAddress,
            true,
            address(tokenizedImpl),
            0
        );
    }
}
