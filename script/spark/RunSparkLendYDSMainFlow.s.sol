// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ITokenizedStrategy } from "@octant-v2-core/core/interfaces/ITokenizedStrategy.sol";

import { BaseScript } from "script/common/BaseScript.sol";
import { console2 } from "forge-std/console2.sol";

interface ISparkStrategyViews {
    function availableWithdrawLimit(address owner) external view returns (uint256);
}

contract RunSparkLendYDSMainFlowScript is BaseScript {
    uint256 constant BPS_DENOMINATOR = 10_000;

    uint256 deployerKey;
    address strategy;
    address tokenized;
    address aToken;
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
        uint256 deployed;
        uint256 total;
        uint256 userShares;
        uint256 userAssets;
        uint256 withdrawLimit;
    }

    function setUp() public {
        deployerKey = _envUintOr("DEPLOYER_PRIVATE_KEY", 0);
        strategy = _addrOrZero("STRATEGY_LEND");
        if (strategy == address(0)) {
            strategy = vm.envAddress("STRATEGY");
        }
        tokenized = _addrOrZero("TOKENIZED_LEND");
        if (tokenized == address(0)) {
            tokenized = vm.envAddress("TOKENIZED");
        }
        aToken = _addrOrZero("SPARK_ATOKEN");
        if (aToken == address(0)) {
            aToken = vm.envAddress("ATOKEN");
        }
        asset = _addrOrZero("UNDERLYING_LEND");
        if (asset == address(0)) {
            asset = vm.envAddress("UNDERLYING");
        }
        name = _envStringOr("NAME_LEND", _envStringOr("NAME", ""));

        user = _addrOrZero("USER");
        if (user == address(0)) {
            if (deployerKey != 0) user = vm.addr(deployerKey);
            else revert("USER required when DEPLOYER_PRIVATE_KEY unset");
        }
        if (deployerKey != 0) require(user == vm.addr(deployerKey), "USER must equal deployer signer");

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
        amount = _envUintOr("AMOUNT", 10_000 * (10 ** dec));

        require(strategy != address(0) && tokenized != address(0), "zero strategy/tokenized");
        require(aToken != address(0) && asset != address(0), "zero aToken/asset");
        require(withdrawBps <= BPS_DENOMINATOR, "WITHDRAW_BPS > 100%");
        if (doDeposit) {
            require(amount > 0, "amount zero");
            require(ERC20(asset).balanceOf(user) >= amount, "insufficient user balance");
        }
        if (withdrawAssetsOverride > 0) doWithdraw = true;
        if (doWithdrawAll) doWithdraw = true;
    }

    function _snapshotPosition() internal view returns (Position memory pos) {
        pos.idle = ERC20(asset).balanceOf(strategy);
        pos.deployed = ERC20(aToken).balanceOf(strategy);
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
        console2.log("Deployed (aToken):", pos.deployed);
        console2.log("Strategy Total   :", pos.total);
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
            if (doReport) (profit, loss) = _report();
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

        if (requiresBroadcast) {
            _writeReport(pre, post, deposited, withdrawn, withdrawLimitBefore, withdrawLimitAfter, profit, loss);
        }
    }

    function _report() internal returns (uint256 profit, uint256 loss) {
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

    function _executeWithdraw(uint256 withdrawLimitBefore)
        internal
        returns (uint256 withdrawn, uint256 withdrawLimitAfter)
    {
        uint256 assetsToWithdraw;
        if (doWithdrawAll) {
            uint256 userShares = ITokenizedStrategy(strategy).balanceOf(user);
            if (userShares == 0) return (0, withdrawLimitBefore);
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
        try ISparkStrategyViews(strategy).availableWithdrawLimit(user) returns (uint256 lim) {
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
        console2.log("=== SparkLend YDS Flow ===");
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

    function _writeReport(
        Position memory prePos,
        Position memory postPos,
        uint256 deposited,
        uint256 withdrawn,
        uint256 withdrawLimitBefore,
        uint256 withdrawLimitAfter,
        uint256 profit,
        uint256 loss
    ) internal {
        string memory dir = string.concat(vm.projectRoot(), "/reports/spark-yds");
        vm.createDir(dir, true);
        string memory file =
            string.concat(dir, "/run-", vm.toString(block.chainid), "-", vm.toString(block.number), ".json");

        string memory profitLoss = doReport
            ? string(abi.encodePacked(",\"profit\":", vm.toString(profit), ",\"loss\":", vm.toString(loss)))
            : "";

        bytes memory encoded = abi.encodePacked(
            "{",
            "\"core\":{",
            "\"chainId\":",
            vm.toString(block.chainid),
            ",",
            "\"strategy\":\"",
            vm.toString(strategy),
            "\",",
            "\"tokenized\":\"",
            vm.toString(tokenized),
            "\",",
            "\"aToken\":\"",
            vm.toString(aToken),
            "\",",
            "\"asset\":\"",
            vm.toString(asset),
            "\",",
            "\"user\":\"",
            vm.toString(user),
            "\"",
            "},",
            "\"flow\":{",
            "\"doDeposit\":",
            _boolToString(doDeposit),
            ",",
            "\"doTend\":",
            _boolToString(doTend),
            ",",
            "\"doReport\":",
            _boolToString(doReport),
            ",",
            "\"doWithdraw\":",
            _boolToString(doWithdraw),
            ",",
            "\"doInspect\":",
            _boolToString(doInspect),
            ",",
            "\"sleepSeconds\":",
            vm.toString(sleepSecs),
            ",",
            "\"deposited\":",
            vm.toString(deposited),
            ",",
            "\"withdrawn\":",
            vm.toString(withdrawn),
            ",",
            "\"withdrawAssetsOverride\":",
            vm.toString(withdrawAssetsOverride),
            ",",
            "\"withdrawBps\":",
            vm.toString(withdrawBps),
            ",",
            "\"withdrawLimitBefore\":",
            vm.toString(withdrawLimitBefore),
            ",",
            "\"withdrawLimitAfter\":",
            vm.toString(withdrawLimitAfter),
            profitLoss,
            "},",
            "\"positions\":{",
            "\"pre\":{",
            "\"idle\":",
            vm.toString(prePos.idle),
            ",",
            "\"deployed\":",
            vm.toString(prePos.deployed),
            ",",
            "\"total\":",
            vm.toString(prePos.total),
            ",",
            "\"userShares\":",
            vm.toString(prePos.userShares),
            ",",
            "\"userAssets\":",
            vm.toString(prePos.userAssets),
            ",",
            "\"withdrawLimit\":",
            vm.toString(prePos.withdrawLimit),
            "},",
            "\"post\":{",
            "\"idle\":",
            vm.toString(postPos.idle),
            ",",
            "\"deployed\":",
            vm.toString(postPos.deployed),
            ",",
            "\"total\":",
            vm.toString(postPos.total),
            ",",
            "\"userShares\":",
            vm.toString(postPos.userShares),
            ",",
            "\"userAssets\":",
            vm.toString(postPos.userAssets),
            ",",
            "\"withdrawLimit\":",
            vm.toString(postPos.withdrawLimit),
            "}",
            "}",
            "}"
        );

        vm.writeJson(string(encoded), file);
    }
}

