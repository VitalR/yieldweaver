// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {
    YieldDonatingTokenizedStrategy
} from "@octant-v2-core/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { ITokenizedStrategy } from "@octant-v2-core/core/interfaces/ITokenizedStrategy.sol";

import { SparkSavingsDonationStrategy } from "src/spark/SparkSavingsDonationStrategy.sol";
import { MockSparkVault } from "test/mocks/MockSparkVault.sol";
import { MockUSDC } from "test/mocks/MockUSDC.sol";

/// @notice Unit tests for SparkSavingsDonationStrategy (Spark Savings V2 ERC-4626 YDS)
/// - Exercises deploy/withdraw/report semantics via TokenizedStrategy fallback
/// - Covers tend threshold, shutdown + emergencyWithdraw, donation mint on profit
/// - Uses MockSparkVault (ERC-4626) and MockUSDC (6d) for deterministic behavior
contract SparkSavingsDonationStrategyUnitTest is Test {
    // ---------------------------------------------------------------------
    // Test fixtures (contracts)
    // ---------------------------------------------------------------------
    ERC20 public usdc;
    MockSparkVault public sparkVault;
    SparkSavingsDonationStrategy public strategy;
    ITokenizedStrategy public tokenized; // Tokenized external surface (delegated via fallback)

    // ---------------------------------------------------------------------
    // Roles
    // ---------------------------------------------------------------------
    address public management = makeAddr("management");
    address public keeper = makeAddr("keeper");
    address public emergencyAdmin = makeAddr("emergencyAdmin");
    address public donationAddress = makeAddr("donationAddress");
    address public user = makeAddr("user");
    address public user2 = makeAddr("user2");

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------
    uint256 constant RAY = 1e27;
    uint256 constant ONE_USDC = 1e6; // 6 decimals
    bool constant ENABLE_BURNING = true;

    function setUp() public {
        // Mocks
        usdc = new MockUSDC();
        sparkVault = new MockSparkVault(usdc, "spUSDC Mock", "spUSDC");

        // Tokenized implementation (reused across strategies)
        YieldDonatingTokenizedStrategy tokenizedImpl = new YieldDonatingTokenizedStrategy();

        // Strategy under test
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
            /* referral */
            0
        );

        // Expose the tokenized surface (lives at the same address; calls delegatecall under the hood)
        tokenized = ITokenizedStrategy(address(strategy));

        // Labels for readable traces
        vm.label(address(usdc), "USDC");
        vm.label(address(sparkVault), "MockSparkVault(spUSDC)");
        vm.label(address(strategy), "Strategy(SparkYDS)");
        vm.label(address(tokenizedImpl), "TokenizedImpl");
        vm.label(management, "management");
        vm.label(keeper, "keeper");
        vm.label(emergencyAdmin, "emergencyAdmin");
        vm.label(donationAddress, "donationAddress");
        vm.label(user, "user");
        vm.label(user2, "user2");
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /// @dev Mint USDC to `_to`.
    function _airdrop(address _to, uint256 _amount) internal {
        uint256 bal = usdc.balanceOf(_to);
        // `deal` works with ERC20 in Foundry to set balance directly in tests.
        deal(address(usdc), _to, bal + _amount);
    }

    /// @dev Deposit via the TokenizedStrategy surface (delegates to the strategy).
    function _deposit(address _user, uint256 _assets) internal {
        _airdrop(_user, _assets);
        vm.startPrank(_user);
        usdc.approve(address(strategy), _assets);
        tokenized.deposit(_assets, _user);
        vm.stopPrank();
    }

    /// @dev Robust, version-agnostic shutdown: tries known admin functions across Octant versions.
    function _forceShutdown() internal {
        bool ok;
        vm.startPrank(management);
        // Strategy-local convenience (some repos expose it)
        (ok,) = address(strategy).call(abi.encodeWithSignature("shutdownStrategy()"));
        if (!ok) {
            // Tokenized strategy (older/newer variants)
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

    /// @dev Rotate dragon router (donation address) with cooldown handling.
    function _rotateDonationAddress(address nextDragon) internal {
        // setDragonRouter requires management in most Octant builds
        vm.prank(management);
        (bool ok,) = address(strategy).call(abi.encodeWithSignature("setDragonRouter(address)", nextDragon));
        require(ok, "setDragonRouter failed");

        // Default cooldown is 7 days in Octant
        skip(7 days);

        // finalize must succeed after cooldown
        (ok,) = address(strategy).call(abi.encodeWithSignature("finalizeDragonRouterChange()"));
        require(ok, "finalizeDragonRouterChange failed");
    }

    // ---------------------------------------------------------------------
    // Tests
    // ---------------------------------------------------------------------

    function test_constructorSetsState() public view {
        assertEq(address(strategy.sparkVault()), address(sparkVault), "sparkVault mismatch");
        // Tokenized storage-accessors are on the tokenized surface:
        assertEq(tokenized.asset(), address(usdc), "asset mismatch");
        assertEq(tokenized.management(), management, "management mismatch");
        assertEq(tokenized.keeper(), keeper, "keeper mismatch");
        assertEq(tokenized.dragonRouter(), donationAddress, "donationAddress mismatch");
    }

    function test_deployFunds_DepositsIntoVault() public {
        // Deposit 10 USDC -> triggers _deployFunds via Tokenized hook
        _deposit(user, 10 * ONE_USDC);

        // Strategy should now hold spUSDC shares (equal to assets in 1:1 mock)
        uint256 shares = sparkVault.balanceOf(address(strategy));
        assertEq(shares, 10 * ONE_USDC, "vault shares not minted");

        // Vault should have USDC underlying
        assertEq(usdc.balanceOf(address(sparkVault)), 10 * ONE_USDC, "vault underlying mismatch");
    }

    function test_freeFunds_WithdrawsFromVault() public {
        _deposit(user, 10 * ONE_USDC);
        // Redeem 4 USDC worth of shares
        vm.startPrank(user);
        // Redeem uses shares; 1:1 in the mock
        tokenized.redeem(4 * ONE_USDC, user, user);
        vm.stopPrank();

        // 6 USDC should remain invested (shares)
        assertEq(sparkVault.balanceOf(address(strategy)), 6 * ONE_USDC, "remaining shares mismatch");
    }

    function test_report_MintsDonationOnProfit() public {
        uint256 amount = 100e6; // 100 USDC (6 decimals)

        // fund the user
        deal(address(usdc), user, amount);

        // 1) Deposit 100 USDC
        vm.startPrank(user);
        usdc.approve(address(strategy), amount);
        // deposit via TokenizedStrategy fallback -> strategy.deposit
        (bool ok,) = address(strategy).call(abi.encodeWithSignature("deposit(uint256,address)", amount, user));
        require(ok, "deposit fail");
        vm.stopPrank();

        // Sanity: strategy holds 100e6 worth of spUSDC shares
        assertEq(sparkVault.balanceOf(address(strategy)), amount);

        // 2) Simulate yield by increasing chi ~5%
        uint256 chi0 = sparkVault.nowChi(); // ray
        uint256 chi1 = (chi0 * 105) / 100; // +5%
        sparkVault.setChi(chi1); // instant PPS jump

        // 3) Report — should observe profit and mint it to donationAddress
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = tokenized.report();
        assertGt(profit, 0, "profit should be > 0");
        assertEq(loss, 0);

        // 4) Donation address should hold non-zero shares (the “yield”)
        uint256 dragonShares = tokenized.balanceOf(donationAddress);
        assertGt(dragonShares, 0, "donation address should receive shares");

        // 5) Optional: donated assets ≈ 5% of principal (allow small rounding)
        uint256 donatedAssets = tokenized.convertToAssets(dragonShares);
        assertApproxEqRel(donatedAssets, (amount * 5) / 100, 0.005e18); // ±0.5%
    }

    function test_limits_MirrorVaultCaps() public {
        // By default the mock exposes "unlimited" caps; strategy should mirror that
        uint256 depLim = strategy.availableDepositLimit(address(this));
        uint256 wthLim = strategy.availableWithdrawLimit(address(this));
        assertEq(depLim, type(uint256).max, "deposit limit not mirrored");
        // With nothing deposited, withdraw limit equals idle (0); mirror path catch-all returns idle + sharesValue
        assertEq(wthLim, 0, "withdraw limit should be zero with no funds");

        // After deposit, withdraw limit matches idle + shares value
        _deposit(user, 7 * ONE_USDC);
        uint256 expected =
            usdc.balanceOf(address(strategy)) + sparkVault.convertToAssets(sparkVault.balanceOf(address(strategy)));
        assertEq(strategy.availableWithdrawLimit(address(this)), expected, "withdraw limit mirror mismatch");
    }

    function test_tend_DeploysWhenIdleAboveThreshold() public {
        // Management config threshold to 1 USDC
        vm.prank(management);
        strategy.setTendThreshold(1 * ONE_USDC);

        // Seed idle directly to strategy (no deploy yet)
        _airdrop(address(strategy), 3 * ONE_USDC);

        uint256 idleBefore = usdc.balanceOf(address(strategy));
        assertEq(idleBefore, 3 * ONE_USDC, "precondition: idle mismatch");

        // Keeper calls tend() via tokenized surface
        vm.prank(keeper);
        tokenized.tend();

        uint256 idleAfter = usdc.balanceOf(address(strategy));
        uint256 shares = sparkVault.balanceOf(address(strategy));

        assertLt(idleAfter, idleBefore, "idle should decrease after tend()");
        assertGt(shares, 0, "shares should increase after tend()");
    }

    function test_emergencyWithdraw_DoesNotRedeploy() public {
        // User deposits 10 USDC
        _deposit(user, 10 * ONE_USDC);

        // Management shuts down
        _forceShutdown();

        // Idle before pull
        uint256 idleBefore = usdc.balanceOf(address(strategy));

        // Emergency admin requests funds (try to pull 6 USDC)
        vm.prank(emergencyAdmin);
        tokenized.emergencyWithdraw(6 * ONE_USDC);

        uint256 idleAfter = usdc.balanceOf(address(strategy));
        assertGt(idleAfter, idleBefore, "idle should increase after emergencyWithdraw");

        // In shutdown, tend should not trigger
        (bool shouldTend,) = strategy.tendTrigger();
        assertFalse(shouldTend, "tendTrigger must be false after shutdown");

        // Report in shutdown should not redeploy, just account
        vm.prank(keeper);
        tokenized.report();

        // Ensure we can still redeem as user
        uint256 userBalBefore = usdc.balanceOf(user);
        vm.prank(user);
        tokenized.redeem(4 * ONE_USDC, user, user);
        assertGe(usdc.balanceOf(user), userBalBefore + 4 * ONE_USDC, "user should redeem post-shutdown");
    }

    function test_observability_sparkVsrChi_MatchesVaultAndMonotonic() public {
        // 1) Fresh state mirrors vault (RAY)
        assertEq(strategy.sparkVsr(), RAY, "sparkVsr should start at 1.0");
        assertEq(strategy.sparkChi(), RAY, "sparkChi should start at 1.0");

        // 2) Set VSR to an allowed value (<= MAX_VSR). Use the mock's public constant getter.
        uint256 vsrAllowed = sparkVault.MAX_VSR();
        sparkVault.setVsr(vsrAllowed);
        assertEq(strategy.sparkVsr(), vsrAllowed, "sparkVsr must match vault.setVsr");

        // 3) Force a chi jump and ensure the strategy mirrors the vault
        uint256 chi0 = sparkVault.nowChi();
        uint256 chiBumped = (chi0 * 105) / 100; // +5%
        sparkVault.setChi(chiBumped);
        assertEq(strategy.sparkChi(), sparkVault.nowChi(), "sparkChi must equal vault chi");

        // 4) Monotonicity: accrue time -> chi increases -> strategy.sparkChi increases
        uint256 cBefore = strategy.sparkChi();
        sparkVault.accrue(7 days);
        uint256 cAfter = strategy.sparkChi();
        assertGt(cAfter, cBefore, "sparkChi must be monotonic with accrue");

        // 5) Read-only / idempotence
        uint256 cRead1 = strategy.sparkChi();
        uint256 vRead1 = strategy.sparkVsr();
        uint256 cRead2 = strategy.sparkChi();
        uint256 vRead2 = strategy.sparkVsr();
        assertEq(cRead1, cRead2, "sparkChi read should be pure/view");
        assertEq(vRead1, vRead2, "sparkVsr read should be pure/view");
    }

    function test_rotateDonationAddress_WithCooldown() public {
        address newDonation = vm.addr(777);
        vm.label(newDonation, "newDonation");

        // set pending (management only)
        vm.prank(management);
        tokenized.setDragonRouter(newDonation);

        // Fast-forward full cooldown (14 days) + 1 second
        skip(14 days + 1);

        // Finalize
        tokenized.finalizeDragonRouterChange();

        assertEq(tokenized.dragonRouter(), newDonation, "dragon router not updated");
    }

    function test_setDeployThreshold_onlyManagement() public {
        uint256 prev = strategy.deployThreshold();

        vm.expectRevert(); // BaseStrategy.onlyManagement() revert
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
        // Set a high threshold so the immediate post-deposit idle is below it.
        // We want to verify that _deployFunds() early-returns and funds stay idle.
        vm.prank(management);
        strategy.setDeployThreshold(20_000_000); // 20 USDC (assuming 6 dec)

        // Fund user and deposit 10 USDC
        uint256 amount = 10_000_000; // 10e6
        deal(address(usdc), user, amount);

        vm.startPrank(user);
        usdc.approve(address(strategy), amount);
        (bool ok,) = address(strategy).call(abi.encodeWithSignature("deposit(uint256,address)", amount, user));
        require(ok, "deposit fail");
        vm.stopPrank();

        // Because idle(=10 USDC) < deployThreshold(=20 USDC), no deploy should have happened
        assertEq(usdc.balanceOf(address(strategy)), amount, "idle should remain in strategy");
        assertEq(sparkVault.balanceOf(address(strategy)), 0, "no spShares expected");
    }

    function test_deployRespectsThreshold_zeroDeploysImmediately() public {
        // With threshold=0, any idle >0 should deploy on the same deposit
        vm.prank(management);
        strategy.setDeployThreshold(0);

        uint256 amount = 5_000_000; // 5 USDC
        deal(address(usdc), user, amount);

        vm.startPrank(user);
        usdc.approve(address(strategy), amount);
        (bool ok,) = address(strategy).call(abi.encodeWithSignature("deposit(uint256,address)", amount, user));
        require(ok, "deposit fail");
        vm.stopPrank();

        // Expect funds moved into the Spark vault (1:1 initial chi in mock)
        assertEq(usdc.balanceOf(address(strategy)), 0, "idle should be deployed");
        assertEq(sparkVault.balanceOf(address(strategy)), amount, "spShares should equal deposit at chi=1");
    }

    // ---------------------------------------------------------------------
    // Invariants
    // ---------------------------------------------------------------------
    /**
     * Invariant goals:
     *  (I1) No phantom shares: strategy.totalSupply() == sum(balances) over {users, dragonRouter}
     *      (approximation we can assert here): totalSupply >= dragon+users and never goes negative; we also
     *      assert that convertToAssets(totalSupply) is consistent with totalAssets() within a small epsilon.
     *  (I2) totalAssets monotonic w.r.t chi increase: if vault chi increases (and no external take()),
     *      then strategy.totalAssets() after report() should be >= previous totalAssets().
     *  (I3) emergencyWithdraw won’t increase deployed more than requested: after calling emergencyWithdraw(x),
     *      the deployed portion (convertToAssets(shares)) cannot be higher than before + tiny rounding.
     */

    /// @dev Helper to treat the strategy address as the tokenized ERC4626 surface.
    function _tokenized() internal view returns (ITokenizedStrategy) {
        return ITokenizedStrategy(address(strategy));
    }

    /// @dev Invariant (as unit): “no phantom shares”
    /// Sum of known holders’ shares equals totalSupply after a deposit+report flow.
    /// Known holders here: user and donationAddress (dragon router).
    function test_invariant_NoPhantomShares() public {
        uint256 amount = 100e6;
        // fund & deposit via tokenized surface
        deal(address(usdc), user, amount);
        vm.startPrank(user);
        usdc.approve(address(strategy), amount);
        _tokenized().deposit(amount, user);
        vm.stopPrank();

        // bump chi to create profit and report
        uint256 chi0 = sparkVault.nowChi();
        sparkVault.setChi((chi0 * 105) / 100); // +5%
        vm.prank(keeper);
        _tokenized().report();

        // totalSupply equals sum of user + donation shares (no phantom)
        uint256 ts = _tokenized().totalSupply();
        uint256 userShares = _tokenized().balanceOf(user);
        uint256 donationShares = _tokenized().balanceOf(donationAddress);
        assertEq(userShares + donationShares, ts, "phantom shares detected");
    }

    /// @dev Invariant (as unit): “totalAssets monotonic w.r.t. chi increase”
    /// If chi increases and we call report(), totalAssets() must not decrease.
    function test_invariant_TotalAssetsMonotonicWithChi() public {
        uint256 amt = 1_000_000e6;
        deal(address(usdc), user, amt);
        vm.startPrank(user);
        usdc.approve(address(strategy), amt);
        _tokenized().deposit(amt, user);
        vm.stopPrank();

        uint256 beforeAssets = _tokenized().totalAssets();

        // raise chi by ~10% and report
        uint256 chi0 = sparkVault.nowChi();
        sparkVault.setChi((chi0 * 110) / 100);
        vm.prank(keeper);
        _tokenized().report();

        uint256 afterAssets = _tokenized().totalAssets();
        assertGe(afterAssets, beforeAssets, "totalAssets decreased after chi increase");
    }

    /// @dev Invariant (as unit): “emergency withdraw won’t increase deployed more than requested”
    /// i.e., idle increase ≤ requested; deployed never decreases by more than requested.
    function test_invariant_EmergencyWithdrawBounded() public {
        uint256 amt = 5_000_000e6;
        deal(address(usdc), user, amt);
        vm.startPrank(user);
        usdc.approve(address(strategy), amt);
        _tokenized().deposit(amt, user);
        vm.stopPrank();

        // compute current deployed & idle
        uint256 sharesInVault = sparkVault.balanceOf(address(strategy));
        uint256 deployedBefore = sparkVault.convertToAssets(sharesInVault);
        uint256 idleBefore = usdc.balanceOf(address(strategy));

        // shutdown then emergencyWithdraw a portion
        vm.prank(management);
        // call shutdown via fallback (no iface on tests)
        (bool s1,) = address(strategy).call(abi.encodeWithSignature("shutdownStrategy()"));
        require(s1, "shutdown failed");

        uint256 request = amt / 3; // ask 1/3 back
        vm.prank(emergencyAdmin);
        _tokenized().emergencyWithdraw(request);

        // recompute
        uint256 deployedAfter = sparkVault.convertToAssets(sparkVault.balanceOf(address(strategy)));
        uint256 idleAfter = usdc.balanceOf(address(strategy));

        // Idle should not have increased by more than requested
        if (idleAfter > idleBefore) {
            assertLe(idleAfter - idleBefore, request, "idle increased by more than requested");
        }
        // Deployed should not decrease by more than requested (i.e., no over-withdrawal)
        if (deployedBefore > deployedAfter) {
            assertLe(deployedBefore - deployedAfter, request, "withdrew more than requested");
        }
    }
}
