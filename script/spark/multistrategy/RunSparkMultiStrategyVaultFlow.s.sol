// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { BaseScript } from "script/common/BaseScript.sol";
import { console2 } from "forge-std/console2.sol";

import { SparkMultiStrategyVault } from "src/spark/multistrategy/SparkMultiStrategyVault.sol";

contract RunSparkMultiStrategyVaultFlowScript is BaseScript {
    uint256 internal constant BPS = 10_000;

    struct StrategySnapshot {
        address vault;
        uint16 targetBps;
        uint256 shares;
        uint256 assets;
    }

    struct VaultSnapshot {
        uint256 totalAssets;
        uint256 idleBalance;
        uint256 totalSupply;
        uint256 pricePerShare;
        uint256 userShares;
        uint256 userAssets;
        uint16 idleTargetBps;
        StrategySnapshot[] strategies;
        uint16[] queue;
    }

    struct FlowSummary {
        uint256 depositedAssets;
        uint256 mintedShares;
        uint256 withdrawnAssets;
        uint256 burnedShares;
        uint256 redeemedAssets;
        uint256 redeemedShares;
        bool targetsUpdated;
        bool queueUpdated;
        bool rebalanceCalled;
    }

    uint256 deployerKey;
    address vault;
    address asset;
    address user;

    bool doApprove;
    bool doDeposit;
    bool doWithdraw;
    bool doRedeem;
    bool doSetTargets;
    bool doSetQueue;
    bool doRebalance;
    bool doInspect;

    uint256 depositAssets;
    uint256 withdrawAssetsOverride;
    uint256 withdrawBps;
    bool withdrawAll;

    uint256 redeemSharesOverride;
    bool redeemAll;

    address[] vaultStrategies;
    uint16[] currentTargetBps;
    uint16 currentIdleBps;

    uint16[] targetBpsOverride;
    uint16 idleBpsOverride;
    bool hasTargetOverride;

    uint16[] queueOverride;
    bool hasQueueOverride;

    function setUp() public {
        deployerKey = _envUintOr("DEPLOYER_PRIVATE_KEY", 0);
        vault = _addrOrZero("MULTI_VAULT");
        if (vault == address(0)) {
            vault = _addrOrZero("VAULT");
        }
        require(vault != address(0), "vault addr required");

        asset = _addrOrZero("UNDERLYING");
        if (asset == address(0)) {
            asset = IERC4626(vault).asset();
        }
        require(asset != address(0), "asset addr required");

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
        doWithdraw = _envBoolOr("DO_WITHDRAW", false);
        doRedeem = _envBoolOr("DO_REDEEM", false);
        doRebalance = _envBoolOr("DO_REBALANCE", false);
        doInspect = _envBoolOr("DO_INSPECT", false);

        withdrawAll = _envBoolOr("WITHDRAW_ALL", false);
        redeemAll = _envBoolOr("REDEEM_ALL", false);

        withdrawAssetsOverride = _envUintOr("WITHDRAW_ASSETS", 0);
        withdrawBps = _envUintOr("WITHDRAW_BPS", 0);
        redeemSharesOverride = _envUintOr("REDEEM_SHARES", 0);

        uint8 dec = ERC20(asset).decimals();
        uint256 defaultDeposit = 10_000 * (10 ** dec);
        depositAssets = _envUintOr("DEPOSIT_ASSETS", _envUintOr("AMOUNT", defaultDeposit));

        (vaultStrategies, currentTargetBps, currentIdleBps) = SparkMultiStrategyVault(vault).strategies();

        (targetBpsOverride, hasTargetOverride, idleBpsOverride) =
            _loadTargetOverrides(currentTargetBps.length, currentTargetBps, currentIdleBps);
        (queueOverride, hasQueueOverride) = _loadQueueOverrides(vaultStrategies.length);

        doSetTargets = _envBoolOr("DO_SET_TARGETS", hasTargetOverride);
        doSetQueue = _envBoolOr("DO_SET_QUEUE", hasQueueOverride);

        if (withdrawAssetsOverride > 0 || withdrawBps > 0 || withdrawAll) doWithdraw = true;
        if (redeemSharesOverride > 0 || redeemAll) doRedeem = true;

        require(withdrawBps <= BPS, "WITHDRAW_BPS > 100%");
        if (doDeposit) {
            require(depositAssets > 0, "deposit amount zero");
            require(IERC20(asset).balanceOf(user) >= depositAssets, "insufficient user balance");
        }
    }

    function run() public {
        VaultSnapshot memory pre = _snapshot();
        if (doInspect) _logSnapshot("Pre", pre);

        FlowSummary memory summary;

        bool requiresBroadcast = doDeposit || doWithdraw || doRedeem || doSetTargets || doSetQueue || doRebalance;
        if (requiresBroadcast) {
            if (deployerKey != 0) vm.startBroadcast(deployerKey);
            else vm.startBroadcast();

            if (doDeposit) (summary.depositedAssets, summary.mintedShares) = _executeDeposit();

            if (doSetTargets) {
                require(hasTargetOverride, "target override missing");
                SparkMultiStrategyVault(vault).setTargets(idleBpsOverride, targetBpsOverride);
                summary.targetsUpdated = true;
            }

            if (doSetQueue) {
                require(hasQueueOverride, "queue override missing");
                SparkMultiStrategyVault(vault).setWithdrawalQueue(queueOverride);
                summary.queueUpdated = true;
            }

            if (doRebalance) {
                SparkMultiStrategyVault(vault).rebalance();
                summary.rebalanceCalled = true;
            }

            if (doWithdraw) (summary.withdrawnAssets, summary.burnedShares) = _executeWithdraw();

            if (doRedeem) (summary.redeemedAssets, summary.redeemedShares) = _executeRedeem();

            vm.stopBroadcast();
        }

        VaultSnapshot memory post = requiresBroadcast ? _snapshot() : pre;

        if (!requiresBroadcast && doInspect) {
            return;
        }

        _logSummary(pre, post, summary);
        _writeReport(pre, post, summary);
        if (doInspect && requiresBroadcast) _logSnapshot("Post", post);
    }

    function _executeDeposit() internal returns (uint256 assetsOut, uint256 sharesMinted) {
        if (doApprove) _approveIfNeeded(asset, vault, depositAssets);
        sharesMinted = SparkMultiStrategyVault(vault).deposit(depositAssets, user);
        assetsOut = depositAssets;
    }

    function _executeWithdraw() internal returns (uint256 assetsWithdrawn, uint256 sharesBurned) {
        uint256 assetsToWithdraw = _resolveWithdrawAssets();
        require(assetsToWithdraw > 0, "withdraw amount zero");
        sharesBurned = SparkMultiStrategyVault(vault).withdraw(assetsToWithdraw, user, user);
        assetsWithdrawn = assetsToWithdraw;
    }

    function _executeRedeem() internal returns (uint256 assetsReceived, uint256 sharesRedeemed) {
        uint256 sharesToRedeem = _resolveRedeemShares();
        require(sharesToRedeem > 0, "redeem shares zero");
        assetsReceived = SparkMultiStrategyVault(vault).redeem(sharesToRedeem, user, user);
        sharesRedeemed = sharesToRedeem;
    }

    function _resolveWithdrawAssets() internal view returns (uint256) {
        if (withdrawAll) {
            return SparkMultiStrategyVault(vault).maxWithdraw(user);
        }
        if (withdrawAssetsOverride > 0) {
            return withdrawAssetsOverride;
        }
        if (withdrawBps > 0) {
            uint256 totalAssets = SparkMultiStrategyVault(vault).totalAssets();
            return (totalAssets * withdrawBps) / BPS;
        }
        return 0;
    }

    function _resolveRedeemShares() internal view returns (uint256) {
        if (redeemAll) {
            return SparkMultiStrategyVault(vault).maxRedeem(user);
        }
        if (redeemSharesOverride > 0) {
            return redeemSharesOverride;
        }
        return 0;
    }

    function _approveIfNeeded(address token, address spender, uint256 amt) internal {
        uint256 allowance = IERC20(token).allowance(user, spender);
        if (allowance < amt) {
            if (allowance != 0) IERC20(token).approve(spender, 0);
            IERC20(token).approve(spender, amt);
        }
    }

    function _snapshot() internal view returns (VaultSnapshot memory snap) {
        snap.totalAssets = SparkMultiStrategyVault(vault).totalAssets();
        snap.idleBalance = IERC20(asset).balanceOf(vault);
        snap.totalSupply = IERC20(vault).totalSupply();
        snap.pricePerShare = snap.totalSupply == 0 ? 0 : (snap.totalAssets * 1e18) / snap.totalSupply;
        snap.userShares = IERC20(vault).balanceOf(user);
        snap.userAssets = SparkMultiStrategyVault(vault).convertToAssets(snap.userShares);

        (address[] memory stratVaults, uint16[] memory targetBps, uint16 idleBps) =
            SparkMultiStrategyVault(vault).strategies();
        snap.idleTargetBps = idleBps;
        snap.strategies = new StrategySnapshot[](stratVaults.length);
        for (uint256 i; i < stratVaults.length; ++i) {
            StrategySnapshot memory s;
            s.vault = stratVaults[i];
            s.targetBps = targetBps[i];
            uint256 shares = IERC4626(stratVaults[i]).balanceOf(vault);
            s.shares = shares;
            s.assets = shares == 0 ? 0 : IERC4626(stratVaults[i]).convertToAssets(shares);
            snap.strategies[i] = s;
        }
        snap.queue = SparkMultiStrategyVault(vault).withdrawalQueue();
    }

    function _logSnapshot(string memory tag, VaultSnapshot memory snap) internal view {
        console2.log(string.concat("=== ", tag, " Multi Strategy Vault ==="));
        console2.log("Vault           :", vault);
        console2.log("Total Assets    :", snap.totalAssets);
        console2.log("Idle Balance    :", snap.idleBalance);
        console2.log("Total Supply    :", snap.totalSupply);
        console2.log("Price Per Share :", snap.pricePerShare);
        console2.log("Idle Target Bps :", snap.idleTargetBps);
        console2.log("User Shares     :", snap.userShares);
        console2.log("User Assets     :", snap.userAssets);
        console2.log("Strategies      :", snap.strategies.length);
        for (uint256 i; i < snap.strategies.length; ++i) {
            StrategySnapshot memory s = snap.strategies[i];
            console2.log(string.concat("  Strategy[", vm.toString(i), "] :", vm.toString(s.vault)));
            console2.log("    targetBps   :", s.targetBps);
            console2.log("    shares      :", s.shares);
            console2.log("    assets      :", s.assets);
        }
        if (snap.queue.length > 0) {
            console2.log("Withdraw Queue  :", snap.queue.length);
            for (uint256 i; i < snap.queue.length; ++i) {
                console2.log(string.concat("  queue[", vm.toString(i), "] :", vm.toString(uint256(snap.queue[i]))));
            }
        } else {
            console2.log("Withdraw Queue  : default (sequential)");
        }
    }

    function _logSummary(VaultSnapshot memory pre, VaultSnapshot memory post, FlowSummary memory summary)
        internal
        view
    {
        console2.log("=== Spark Multi Strategy Vault Flow ===");
        console2.log("Vault           :", vault);
        console2.log("User            :", user);
        console2.log("Deposited Assets:", summary.depositedAssets);
        console2.log("Minted Shares   :", summary.mintedShares);
        console2.log("Withdrawn Assets:", summary.withdrawnAssets);
        console2.log("Shares Burned   :", summary.burnedShares);
        console2.log("Redeemed Assets :", summary.redeemedAssets);
        console2.log("Shares Redeemed :", summary.redeemedShares);
        console2.log("Targets Updated :", _boolToString(summary.targetsUpdated));
        console2.log("Queue Updated   :", _boolToString(summary.queueUpdated));
        console2.log("Rebalance Call  :", _boolToString(summary.rebalanceCalled));
        console2.log("Total Assets Delta :", int256(post.totalAssets) - int256(pre.totalAssets));
        console2.log("Idle Balance Delta :", int256(post.idleBalance) - int256(pre.idleBalance));
        console2.log("Total Supply Delta :", int256(post.totalSupply) - int256(pre.totalSupply));
        console2.log("User Shares Delta  :", int256(post.userShares) - int256(pre.userShares));
        console2.log("User Assets Delta  :", int256(post.userAssets) - int256(pre.userAssets));
    }

    function _loadTargetOverrides(uint256 length, uint16[] memory currentTargets, uint16 currentIdle)
        internal
        view
        returns (uint16[] memory targets, bool configured, uint16 idleOverride)
    {
        targets = new uint16[](length);
        bool anySet;
        for (uint256 i; i < length; ++i) {
            string memory key = string.concat("NEW_TARGET_BPS_", vm.toString(i));
            (uint256 raw, bool exists) = _envUintMaybe(key);
            if (exists) {
                require(raw <= BPS, "target override > BPS");
                targets[i] = uint16(raw);
                anySet = true;
            } else {
                targets[i] = currentTargets[i];
            }
        }
        (uint256 idleRaw, bool idleExists) = _envUintMaybe("NEW_IDLE_BPS");
        if (idleExists) {
            require(idleRaw <= BPS, "idle override > BPS");
            idleOverride = uint16(idleRaw);
            anySet = true;
        } else {
            idleOverride = currentIdle;
        }
        return (targets, anySet, idleOverride);
    }

    function _loadQueueOverrides(uint256 length) internal view returns (uint16[] memory queue, bool configured) {
        if (length == 0) return (new uint16[](0), false);
        queue = new uint16[](length);
        for (uint256 i; i < length; ++i) {
            string memory key = string.concat("NEW_QUEUE_", vm.toString(i));
            (uint256 raw, bool exists) = _envUintMaybe(key);
            if (!exists) {
                if (i == 0) return (new uint16[](0), false);
                revert(string.concat("missing ", key));
            }
            require(raw < length, "queue index out of range");
            queue[i] = uint16(raw);
        }
        return (queue, true);
    }

    function _envUintMaybe(string memory key) internal view returns (uint256 value, bool exists) {
        try vm.envUint(key) returns (uint256 parsed) {
            return (parsed, true);
        } catch {
            return (0, false);
        }
    }

    function _writeReport(VaultSnapshot memory preSnap, VaultSnapshot memory postSnap, FlowSummary memory summary)
        internal
    {
        string memory dir = "reports/spark/multistrategy";
        vm.createDir(dir, true);
        string memory path =
            string.concat(dir, "/run-", vm.toString(block.chainid), "-", vm.toString(block.number), ".json");

        string memory label = "run";
        string memory json = vm.serializeUint(label, "chainId", block.chainid);
        json = vm.serializeUint(label, "blockNumber", block.number);
        json = vm.serializeAddress(label, "vault", vault);
        json = vm.serializeAddress(label, "asset", asset);
        json = vm.serializeAddress(label, "user", user);
        json = vm.serializeUint(label, "depositAssets", depositAssets);
        json = vm.serializeBool(label, "doApprove", doApprove);
        json = vm.serializeBool(label, "doDeposit", doDeposit);
        json = vm.serializeBool(label, "doWithdraw", doWithdraw);
        json = vm.serializeBool(label, "doRedeem", doRedeem);
        json = vm.serializeBool(label, "doRebalance", doRebalance);
        json = vm.serializeBool(label, "doSetTargets", doSetTargets);
        json = vm.serializeBool(label, "doSetQueue", doSetQueue);
        json = vm.serializeBool(label, "withdrawAll", withdrawAll);
        json = vm.serializeBool(label, "redeemAll", redeemAll);
        json = vm.serializeUint(label, "withdrawBps", withdrawBps);
        json = vm.serializeUint(label, "withdrawAssetsOverride", withdrawAssetsOverride);
        json = vm.serializeUint(label, "redeemSharesOverride", redeemSharesOverride);
        json = vm.serializeUint(label, "depositedAssets", summary.depositedAssets);
        json = vm.serializeUint(label, "mintedShares", summary.mintedShares);
        json = vm.serializeUint(label, "withdrawnAssets", summary.withdrawnAssets);
        json = vm.serializeUint(label, "burnedShares", summary.burnedShares);
        json = vm.serializeUint(label, "redeemedAssets", summary.redeemedAssets);
        json = vm.serializeUint(label, "redeemedShares", summary.redeemedShares);
        json = vm.serializeBool(label, "targetsUpdated", summary.targetsUpdated);
        json = vm.serializeBool(label, "queueUpdated", summary.queueUpdated);
        json = vm.serializeBool(label, "rebalanceCalled", summary.rebalanceCalled);
        json = vm.serializeUint(label, "preTotalAssets", preSnap.totalAssets);
        json = vm.serializeUint(label, "postTotalAssets", postSnap.totalAssets);
        json = vm.serializeUint(label, "preIdleBalance", preSnap.idleBalance);
        json = vm.serializeUint(label, "postIdleBalance", postSnap.idleBalance);
        json = vm.serializeUint(label, "preTotalSupply", preSnap.totalSupply);
        json = vm.serializeUint(label, "postTotalSupply", postSnap.totalSupply);
        json = vm.serializeUint(label, "preUserShares", preSnap.userShares);
        json = vm.serializeUint(label, "postUserShares", postSnap.userShares);
        json = vm.serializeUint(label, "preUserAssets", preSnap.userAssets);
        json = vm.serializeUint(label, "postUserAssets", postSnap.userAssets);
        json = vm.serializeUint(label, "idleTargetBpsBefore", preSnap.idleTargetBps);
        json = vm.serializeUint(label, "idleTargetBpsAfter", postSnap.idleTargetBps);
        for (uint256 i; i < preSnap.strategies.length; ++i) {
            string memory prefix = string.concat("pre_strategy_", vm.toString(i));
            json = vm.serializeAddress(label, string.concat(prefix, "_vault"), preSnap.strategies[i].vault);
            json = vm.serializeUint(label, string.concat(prefix, "_targetBps"), preSnap.strategies[i].targetBps);
            json = vm.serializeUint(label, string.concat(prefix, "_shares"), preSnap.strategies[i].shares);
            json = vm.serializeUint(label, string.concat(prefix, "_assets"), preSnap.strategies[i].assets);
        }
        for (uint256 i; i < postSnap.strategies.length; ++i) {
            string memory prefix = string.concat("post_strategy_", vm.toString(i));
            json = vm.serializeAddress(label, string.concat(prefix, "_vault"), postSnap.strategies[i].vault);
            json = vm.serializeUint(label, string.concat(prefix, "_targetBps"), postSnap.strategies[i].targetBps);
            json = vm.serializeUint(label, string.concat(prefix, "_shares"), postSnap.strategies[i].shares);
            json = vm.serializeUint(label, string.concat(prefix, "_assets"), postSnap.strategies[i].assets);
        }
        for (uint256 i; i < preSnap.queue.length; ++i) {
            json = vm.serializeUint(label, string.concat("pre_queue_", vm.toString(i)), preSnap.queue[i]);
        }
        for (uint256 i; i < postSnap.queue.length; ++i) {
            json = vm.serializeUint(label, string.concat("post_queue_", vm.toString(i)), postSnap.queue[i]);
        }
        vm.writeJson(json, path);
        console2.log("Report written   :", path);
    }
}

