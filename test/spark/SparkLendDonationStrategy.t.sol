// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {
    YieldDonatingTokenizedStrategy
} from "@octant-v2-core/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { ITokenizedStrategy } from "@octant-v2-core/core/interfaces/ITokenizedStrategy.sol";

import { SparkLendDonationStrategy } from "src/spark/SparkLendDonationStrategy.sol";
import { MockAavePool } from "test/mocks/MockAavePool.sol";
import { MockUSDC } from "test/mocks/MockUSDC.sol";

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

        vm.label(address(usdc), "USDC");
        vm.label(address(pool), "MockSparkLendPool");
        vm.label(pool.aTokenAddress(), "MockAToken");
        vm.label(address(strategy), "SparkLendStrategy");
        vm.label(address(tokenizedImpl), "TokenizedImpl");
    }

    // Helpers ----------------------------------------------------------------

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
        if (!ok) {
            (ok,) = address(strategy).call(abi.encodeWithSignature("shutdown()"));
        }
        if (!ok) {
            (ok,) = address(strategy).call(abi.encodeWithSignature("setShutdown(bool)", true));
        }
        if (!ok) {
            (ok,) = address(strategy).call(abi.encodeWithSignature("setEmergencyShutdown(bool)", true));
        }
        vm.stopPrank();
        require(ok, "shutdown-not-supported");
    }

    // Tests ------------------------------------------------------------------

    function test_constructor_setsState() public view {
        assertEq(address(strategy.POOL()), address(pool), "pool mismatch");
        assertEq(address(strategy.ATOKEN()), pool.aTokenAddress(), "aToken mismatch");
        assertEq(tokenized.asset(), address(usdc), "asset mismatch");
        assertEq(tokenized.management(), management, "management mismatch");
    }

    function test_deposit_supplies_to_pool() public {
        uint256 depositAmount = 10 * ONE_USDC;
        _deposit(user, depositAmount);

        assertEq(usdc.balanceOf(address(pool)), depositAmount, "pool should hold supplied asset");
        assertEq(ERC20(pool.aTokenAddress()).balanceOf(address(strategy)), depositAmount, "aToken not minted");
    }

    function test_withdraw_frees_from_pool() public {
        uint256 depositAmount = 20 * ONE_USDC;
        _deposit(user, depositAmount);

        vm.startPrank(user);
        tokenized.redeem(5 * ONE_USDC, user, user);
        vm.stopPrank();

        assertEq(ERC20(pool.aTokenAddress()).balanceOf(address(strategy)), 15 * ONE_USDC, "aToken balance mismatch");
        assertEq(usdc.balanceOf(user), 5 * ONE_USDC, "user did not receive withdrawn assets");
    }

    function test_report_mints_donation_on_profit() public {
        uint256 depositAmount = 100 * ONE_USDC;
        _deposit(user, depositAmount);

        // simulate yield: mint 10 USDC worth of aTokens to the strategy
        pool.accrueInterest(address(strategy), 10 * ONE_USDC);

        vm.prank(keeper);
        (uint256 profit, uint256 loss) = tokenized.report();
        assertEq(loss, 0, "loss should be zero");
        assertGt(profit, 0, "profit expected");

        uint256 dragonShares = tokenized.balanceOf(donationAddress);
        assertGt(dragonShares, 0, "donation address should receive shares");
    }

    function test_available_withdraw_limit_matches_idle_plus_atoken() public {
        _deposit(user, 12 * ONE_USDC);

        uint256 expected = usdc.balanceOf(address(strategy)) + ERC20(pool.aTokenAddress()).balanceOf(address(strategy));
        assertEq(strategy.availableWithdrawLimit(address(this)), expected, "withdraw limit mismatch");
    }

    function test_tend_deploys_idle_above_threshold() public {
        vm.prank(management);
        strategy.setTendThreshold(ONE_USDC);

        _airdrop(address(strategy), 3 * ONE_USDC);
        vm.prank(keeper);
        tokenized.tend();

        assertEq(usdc.balanceOf(address(strategy)), 0, "idle should be deployed");
        assertEq(ERC20(pool.aTokenAddress()).balanceOf(address(strategy)), 3 * ONE_USDC, "aToken mint mismatch");
    }

    function test_emergency_withdraw_pulls_from_pool() public {
        _deposit(user, 8 * ONE_USDC);

        _forceShutdown();

        vm.prank(emergencyAdmin);
        tokenized.emergencyWithdraw(5 * ONE_USDC);

        assertEq(usdc.balanceOf(address(strategy)), 5 * ONE_USDC, "funds not pulled for emergency");
    }
}
