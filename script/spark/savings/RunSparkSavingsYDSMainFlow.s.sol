// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ITokenizedStrategy } from "@octant-v2-core/core/interfaces/ITokenizedStrategy.sol";

import { BaseScript } from "script/common/BaseScript.sol";
import { console2 } from "forge-std/console2.sol";
import { ISparkVault } from "src/spark/savings/interfaces/ISparkVault.sol";

interface ISavingsStrategyViews {
    function availableWithdrawLimit(address owner) external view returns (uint256);
}

/// @notice Main-flow runner against a deployed Spark Savings YDS pair.
/// Env (required):
///   DEPLOYER_PRIVATE_KEY   : uint (or use --private-key at CLI)
///   STRATEGY               : address (SparkSavingsDonationStrategy proxy)
///   TOKENIZED              : address (paired TokenizedStrategy)
///   SPARK_VAULT            : address (spUSDS / spUSDC / spETH ...)
///   UNDERLYING             : address (USDS / USDC / WETH ...)
///   NAME                   : string  (strategy name for logs)
///
/// Env (optional):
///   USER                   : address (defaults to deployer)
///   AMOUNT                 : uint    (underlying base units; default 10_000 * 10**decimals)
///   DO_APPROVE             : bool    (default true; skip when allowance pre-set)
///   DO_DEPOSIT             : bool    (default true; disable for withdraw-only runs)
///   DO_TEND                : bool    (default false; run a separate tend pass when needed)
///   DO_REPORT              : bool    (default false)
///   DO_WITHDRAW            : bool    (defaults to WITHDRAW_BPS > 0)
///   WITHDRAW_ALL           : bool    (withdraw the full current limit)
///   WITHDRAW_BPS           : uint    (0..10_000; default 0 = skip withdraw)
///   WITHDRAW_ASSETS        : uint    (explicit amount override; takes priority over WITHDRAW_BPS)
///   SLEEP_SECONDS          : uint    (sleep to let interest accrue on slow chains; default 0)
///   DO_INSPECT             : bool    (default false; log position snapshot without broadcasting)
///
/// Example:
///    set -a; source .env; set +a
///    forge script script/spark/savings/RunSparkSavingsYDSMainFlow.s.sol:RunSparkSavingsYDSMainFlowScript \
///      --rpc-url "$ETH_RPC_URL" --private-key "$DEPLOYER_PRIVATE_KEY" --broadcast -vvvv
contract RunSparkSavingsYDSMainFlowScript is BaseScript {
    uint256 constant BPS_DENOMINATOR = 10_000;

    uint256 deployerKey;
    address strategy;
    address tokenized;
    address sparkVault;
    address asset;
    string name;

    address user;
    uint256 amount;
    bool doTend;
    bool doReport;
    uint256 withdrawBps;
    uint256 sleepSecs;
    bool doApprove;
    bool doDeposit;
    bool doWithdraw;
    bool doWithdrawAll;
    bool doInspect;
    uint256 withdrawAssetsOverride;

    struct Position {
        uint256 idle;
        uint256 vaultShares;
        uint256 deployed;
        uint256 total;
        uint256 userShares;
        uint256 userAssets;
        uint256 withdrawLimit;
    }

    function _snapshotPosition() internal view returns (Position memory pos) {
        pos.idle = ERC20(asset).balanceOf(strategy);
        pos.vaultShares = ERC20(sparkVault).balanceOf(strategy);
        pos.deployed = ISparkVault(sparkVault).convertToAssets(pos.vaultShares);
        pos.total = pos.idle + pos.deployed;
        pos.userShares = ITokenizedStrategy(strategy).balanceOf(user);
        try ITokenizedStrategy(strategy).convertToAssets(pos.userShares) returns (uint256 assetsOut) {
            pos.userAssets = assetsOut;
        } catch {
            pos.userAssets = 0;
        }
        pos.withdrawLimit = _readWithdrawLimit();
    }

    function _logPosition(string memory tag, Position memory pos) internal pure {
        console2.log(string.concat("=== ", tag, " Position ==="));
        console2.log("User Shares      :", pos.userShares);
        console2.log("User Assets      :", pos.userAssets);
        console2.log("Withdraw Limit   :", pos.withdrawLimit);
        console2.log("Strategy Idle    :", pos.idle);
        console2.log("Vault Shares     :", pos.vaultShares);
        console2.log("Strategy Deployed:", pos.deployed);
        console2.log("Strategy Total   :", pos.total);
    }

    function setUp() public {
        deployerKey = _envUintOr("DEPLOYER_PRIVATE_KEY", 0);

        strategy = vm.envAddress("STRATEGY");
        tokenized = vm.envAddress("TOKENIZED");
        sparkVault = vm.envAddress("SPARK_VAULT");
        asset = vm.envAddress("UNDERLYING");
        name = vm.envString("NAME");

        user = _addrOrZero("USER");
        if (user == address(0)) {
            if (deployerKey != 0) user = vm.addr(deployerKey);
            else revert("USER required when DEPLOYER_PRIVATE_KEY unset");
        }
        if (deployerKey != 0) {
            require(user == vm.addr(deployerKey), "USER must equal deployer signer");
        }

        doApprove = _envBoolOr("DO_APPROVE", true);
        doDeposit = _envBoolOr("DO_DEPOSIT", true);
        doTend = _envBoolOr("DO_TEND", false);
        doReport = _envBoolOr("DO_REPORT", false);
        withdrawBps = _envUintOr("WITHDRAW_BPS", 0);
        doWithdraw = _envBoolOr("DO_WITHDRAW", withdrawBps > 0);
        doWithdrawAll = _envBoolOr("WITHDRAW_ALL", false);
        doInspect = _envBoolOr("DO_INSPECT", false);
        sleepSecs = _envUintOr("SLEEP_SECONDS", 0);
        withdrawAssetsOverride = _envUintOr("WITHDRAW_ASSETS", 0);

        uint8 dec = ERC20(asset).decimals();
        uint256 def = 10_000 * (10 ** dec);
        amount = _envUintOr("AMOUNT", def);

        if (withdrawAssetsOverride > 0) doWithdraw = true;
        if (doWithdrawAll) doWithdraw = true;

        require(strategy != address(0) && tokenized != address(0), "zero strategy/tokenized");
        require(sparkVault != address(0) && asset != address(0), "zero sparkVault/asset");
        require(ISparkVault(sparkVault).asset() == asset, "vault.asset mismatch");
        require(withdrawBps <= BPS_DENOMINATOR, "WITHDRAW_BPS > 100%");
        if (doDeposit) {
            require(amount > 0, "amount zero");
            require(ERC20(asset).balanceOf(user) >= amount, "insufficient user balance");
        }
    }

    function run() public {
        Position memory pre = _snapshotPosition();
        if (doInspect) _logPosition("Pre", pre);

        uint256 deposited;
        uint256 withdrawn;
        uint256 profit;
        uint256 loss;
        uint256 withdrawLimitBefore = pre.withdrawLimit;
        uint256 withdrawLimitAfter = withdrawLimitBefore;

        bool requiresBroadcast = doDeposit || doTend || doReport || doWithdraw;
        if (requiresBroadcast) {
            if (deployerKey != 0) vm.startBroadcast(deployerKey);
            else vm.startBroadcast();

            if (doDeposit) deposited = _executeDeposit();
            if (doTend) _call(strategy, abi.encodeWithSignature("tend()"), "tend failed");
            if (sleepSecs > 0) vm.sleep(sleepSecs);
            if (doReport) (profit, loss) = _executeReport();

            withdrawLimitBefore = _readWithdrawLimit();
            if (doWithdraw) (withdrawn, withdrawLimitAfter) = _executeWithdraw(withdrawLimitBefore);

            vm.stopBroadcast();
        }

        Position memory post = requiresBroadcast ? _snapshotPosition() : pre;

        if (!requiresBroadcast && doInspect) {
            return;
        }

        _logSummary(pre, post, deposited, withdrawn, withdrawLimitBefore, withdrawLimitAfter, profit, loss);
        if (doInspect && requiresBroadcast) _logPosition("Post", post);
    }

    // ---------------- internal helpers ----------------

    function _executeReport() internal returns (uint256 profit, uint256 loss) {
        (bool ok, bytes memory data) = strategy.call(abi.encodeWithSignature("report()"));
        require(ok, "report failed");
        (profit, loss) = abi.decode(data, (uint256, uint256));
    }

    function _call(address to, bytes memory data, string memory err) internal {
        (bool ok,) = to.call(data);
        require(ok, err);
    }

    function _safeApproveFromUser(address token, address spender, uint256 amt) internal {
        uint256 current = ERC20(token).allowance(user, spender);
        if (current < amt) {
            if (current != 0) ERC20(token).approve(spender, 0);
            ERC20(token).approve(spender, amt);
        }
    }

    function _executeDeposit() internal returns (uint256) {
        if (doApprove) _safeApproveFromUser(asset, strategy, amount);
        _call(strategy, abi.encodeWithSignature("deposit(uint256,address)", amount, user), "deposit failed");
        return amount;
    }

    function _executeTend() internal {
        _call(strategy, abi.encodeWithSignature("tend()"), "tend failed (is shutdown?)");
    }

    function _executeWithdraw(uint256 withdrawLimitBefore)
        internal
        returns (uint256 withdrawn, uint256 withdrawLimitAfter)
    {
        uint256 assetsToWithdraw;
        if (doWithdrawAll) {
            uint256 userShares = ITokenizedStrategy(strategy).balanceOf(user);
            if (userShares == 0) {
                console2.log("Withdraw-all skipped: user has no shares");
                return (0, withdrawLimitBefore);
            }
            assetsToWithdraw = withdrawLimitBefore;
            try ITokenizedStrategy(strategy).convertToAssets(userShares) returns (uint256 userAssets) {
                if (userAssets > 0 && userAssets < assetsToWithdraw) assetsToWithdraw = userAssets;
            } catch { }
        } else {
            assetsToWithdraw = _resolveWithdrawAssets();
        }
        require(assetsToWithdraw > 0, "withdraw amount zero");
        require(assetsToWithdraw <= withdrawLimitBefore, "withdraw exceeds strategy limit");
        _call(
            strategy,
            abi.encodeWithSignature("withdraw(uint256,address,address)", assetsToWithdraw, user, user),
            "withdraw failed"
        );
        withdrawLimitAfter = _readWithdrawLimit();
        return (assetsToWithdraw, withdrawLimitAfter);
    }

    function _readWithdrawLimit() internal view returns (uint256) {
        try ISavingsStrategyViews(strategy).availableWithdrawLimit(user) returns (uint256 lim) {
            return lim;
        } catch {
            return 0;
        }
    }

    function _resolveWithdrawAssets() internal view returns (uint256) {
        if (withdrawAssetsOverride > 0) return withdrawAssetsOverride;
        return (amount * withdrawBps) / BPS_DENOMINATOR;
    }

    function _logSummary(
        Position memory prePos,
        Position memory postPos,
        uint256 deposited,
        uint256 withdrawn,
        uint256 withdrawLimitBefore,
        uint256 withdrawLimitAfter,
        uint256 profit,
        uint256 loss
    ) internal view {
        console2.log("=== Spark Savings YDS Flow ===");
        console2.log("Chain            :", block.chainid);
        console2.log("Strategy         :", strategy);
        console2.log("User             :", user);
        console2.log("Do Deposit       :", doDeposit);
        console2.log("Do Tend          :", doTend);
        console2.log("Do Report        :", doReport);
        console2.log("Do Withdraw      :", doWithdraw);
        console2.log("Deposited        :", deposited);
        console2.log("Withdrawn        :", withdrawn);
        console2.log("Withdraw Limit (pre)        ", prePos.withdrawLimit);
        console2.log("Withdraw Limit (before tx)  ", withdrawLimitBefore);
        console2.log("Withdraw Limit (post)       ", withdrawLimitAfter);
        console2.log("User Shares (pre) :", prePos.userShares);
        console2.log("User Shares (post):", postPos.userShares);
        console2.log("User Assets (pre) :", prePos.userAssets);
        console2.log("User Assets (post):", postPos.userAssets);
        if (doReport) console2.log("Profit           :", profit);
        console2.log("Loss             :", loss);
    }
}

