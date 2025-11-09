// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { BaseScript } from "script/common/BaseScript.sol";
import { console2 } from "forge-std/console2.sol";

import { SparkMultiStrategyVault } from "src/spark/multistrategy/SparkMultiStrategyVault.sol";

contract DeploySparkMultiStrategyVaultScript is BaseScript {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_STRATEGIES = 5;

    struct Config {
        uint256 deployerKey;
        address deployer;
        address asset;
        string name;
        string symbol;
        address owner;
        uint16 idleBps;
        address[] strategies;
        uint16[] targetBps;
        uint16[] withdrawQueue;
        bool hasQueueOverride;
    }

    Config internal cfg;
    mapping(address => bool) internal seenStrategy;

    function setUp() public {
        cfg.deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        cfg.deployer = vm.addr(cfg.deployerKey);

        cfg.asset = vm.envAddress("UNDERLYING");
        cfg.name = _envStringOr("MULTI_NAME", _envStringOr("NAME_MULTI", _envStringOr("NAME", "")));
        if (bytes(cfg.name).length == 0) {
            cfg.name = "Spark Multi Strategy Vault";
        }
        cfg.symbol = _envStringOr("MULTI_SYMBOL", _envStringOr("SYMBOL_MULTI", "smSPARK"));

        cfg.owner = _addrOrZero("OWNER");
        if (cfg.owner == address(0)) cfg.owner = cfg.deployer;

        (uint256 idleRaw, bool idleExists) = _envUintMaybe("IDLE_BPS");
        cfg.idleBps = uint16(idleExists ? idleRaw : 1000);

        _collectStrategy("STRATEGY_SAVINGS", "TARGET_BPS_SAVINGS");
        _collectStrategy("STRATEGY_LEND", "TARGET_BPS_LEND");

        for (uint256 i; i < MAX_STRATEGIES; ++i) {
            string memory suffix = vm.toString(i);
            _collectStrategy(string.concat("STRATEGY_", suffix), string.concat("TARGET_BPS_", suffix));
            _collectStrategy(string.concat("STRATEGY_VAULT_", suffix), string.concat("TARGET_BPS_", suffix));
        }

        require(cfg.strategies.length != 0, "no strategies configured");

        (cfg.withdrawQueue, cfg.hasQueueOverride) = _loadWithdrawQueue(cfg.strategies.length);
    }

    function run() public {
        require(cfg.deployerKey != 0, "DEPLOYER_PRIVATE_KEY required");
        require(cfg.asset != address(0), "asset zero");
        require(bytes(cfg.symbol).length != 0, "symbol empty");
        require(cfg.owner != address(0), "owner zero");

        uint256 sumBps = cfg.idleBps;
        for (uint256 i; i < cfg.targetBps.length; ++i) {
            sumBps += cfg.targetBps[i];
        }
        require(sumBps == BPS, "BPS mismatch");

        vm.startBroadcast(cfg.deployerKey);
        SparkMultiStrategyVault vault = new SparkMultiStrategyVault(
            IERC20(cfg.asset), cfg.name, cfg.symbol, cfg.owner, cfg.strategies, cfg.targetBps, cfg.idleBps
        );

        if (cfg.hasQueueOverride) {
            vault.setWithdrawalQueue(cfg.withdrawQueue);
        }
        vm.stopBroadcast();

        _logDeployment(address(vault));
        _writeReport(address(vault));
    }

    function _collectStrategy(string memory addrKey, string memory targetKey) internal {
        address strategyAddr = _addrOrZero(addrKey);
        if (strategyAddr == address(0) || seenStrategy[strategyAddr]) return;

        (uint256 targetRaw, bool exists) = _envUintMaybe(targetKey);
        require(exists, string.concat("missing ", targetKey));
        require(targetRaw <= BPS, string.concat("target exceeds BPS: ", targetKey));

        seenStrategy[strategyAddr] = true;
        cfg.strategies.push(strategyAddr);
        cfg.targetBps.push(uint16(targetRaw));
    }

    function _loadWithdrawQueue(uint256 length) internal view returns (uint16[] memory queue, bool configured) {
        uint16[] memory temp = new uint16[](length);
        for (uint256 i; i < length; ++i) {
            string memory key = string.concat("WITHDRAW_QUEUE_", vm.toString(i));
            (uint256 indexRaw, bool exists) = _envUintMaybe(key);
            if (!exists) {
                if (i == 0) {
                    return (new uint16[](0), false);
                }
                revert(string.concat("missing ", key));
            }
            require(indexRaw < length, "queue index out of range");
            temp[i] = uint16(indexRaw);
        }
        return (temp, true);
    }

    function _envUintMaybe(string memory key) internal view returns (uint256 value, bool exists) {
        try vm.envUint(key) returns (uint256 parsed) {
            return (parsed, true);
        } catch {
            return (0, false);
        }
    }

    function _logDeployment(address vault) internal view {
        console2.log("=== Spark Multi Strategy Vault Deployment ===");
        console2.log("Chain ID       :", block.chainid);
        console2.log("Deployer       :", cfg.deployer);
        console2.log("Vault          :", vault);
        console2.log("Asset          :", cfg.asset);
        console2.log("Owner          :", cfg.owner);
        console2.log("Name           :", cfg.name);
        console2.log("Symbol         :", cfg.symbol);
        console2.log("Idle BPS       :", cfg.idleBps);
        console2.log("Strategies     :", cfg.strategies.length);
        for (uint256 i; i < cfg.strategies.length; ++i) {
            console2.log(string.concat("  Strategy[", vm.toString(i), "] :", vm.toString(cfg.strategies[i])));
            console2.log("    targetBps :", cfg.targetBps[i]);
        }
        if (cfg.hasQueueOverride) {
            console2.log("Withdraw queue override set");
            for (uint256 i; i < cfg.withdrawQueue.length; ++i) {
                console2.log(string.concat("  queue[", vm.toString(i), "] :", vm.toString(cfg.withdrawQueue[i])));
            }
        } else {
            console2.log("Withdraw queue  : default (sequential)");
        }
    }

    function _writeReport(address vault) internal {
        string memory dir = "reports/spark/multistrategy";
        vm.createDir(dir, true);
        string memory path =
            string.concat(dir, "/deployment-", vm.toString(block.chainid), "-", vm.toString(block.number), ".json");

        string memory label = "deployment";
        string memory json = vm.serializeUint(label, "chainId", block.chainid);
        json = vm.serializeUint(label, "blockNumber", block.number);
        json = vm.serializeAddress(label, "deployer", cfg.deployer);
        json = vm.serializeAddress(label, "vault", vault);
        json = vm.serializeAddress(label, "asset", cfg.asset);
        json = vm.serializeString(label, "name", cfg.name);
        json = vm.serializeString(label, "symbol", cfg.symbol);
        json = vm.serializeAddress(label, "owner", cfg.owner);
        json = vm.serializeUint(label, "idleBps", cfg.idleBps);
        for (uint256 i; i < cfg.strategies.length; ++i) {
            string memory stratKey = string.concat("strategy_", vm.toString(i));
            string memory targetKey = string.concat("targetBps_", vm.toString(i));
            json = vm.serializeAddress(label, stratKey, cfg.strategies[i]);
            json = vm.serializeUint(label, targetKey, cfg.targetBps[i]);
        }
        if (cfg.hasQueueOverride) {
            for (uint256 i; i < cfg.withdrawQueue.length; ++i) {
                string memory queueKey = string.concat("queue_", vm.toString(i));
                json = vm.serializeUint(label, queueKey, cfg.withdrawQueue[i]);
            }
        }
        vm.writeJson(json, path);
        console2.log("Report written   :", path);
    }
}

