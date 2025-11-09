// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { BaseScript } from "script/common/BaseScript.sol";
import { console2 } from "forge-std/console2.sol";

import { SparkSavingsStrategyFactory } from "src/spark/savings/SparkSavingsStrategyFactory.sol";
import { ISparkVault } from "src/spark/savings/interfaces/ISparkVault.sol";

contract DeploySparkSavingsYDSScript is BaseScript {
    struct Config {
        uint256 deployerKey;
        address deployer;
        address sparkVault;
        address asset;
        string name;
        address management;
        address keeper;
        address emergencyAdmin;
        address donationAddress;
        bool enableBurning;
        uint16 referral;
        address factoryMaybe;
    }

    struct DeploymentResult {
        address factory;
        address strategy;
        address tokenized;
        address strategyPred;
        address tokenizedPred;
        bool deployedFactory;
        uint256 nonceStart;
    }

    Config internal cfg;

    function setUp() public {
        cfg.deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        cfg.deployer = vm.addr(cfg.deployerKey);

        cfg.sparkVault = vm.envAddress("SPARK_VAULT");
        cfg.asset = _addrOrZero("UNDERLYING");
        if (cfg.asset == address(0)) {
            cfg.asset = ISparkVault(cfg.sparkVault).asset();
        }

        cfg.name = _envStringOr("NAME_SAVINGS", _envStringOr("NAME", ""));
        if (bytes(cfg.name).length == 0) {
            cfg.name = string.concat("SparkSavings-", vm.toString(cfg.sparkVault));
        }

        cfg.management = vm.envAddress("MANAGEMENT");
        cfg.keeper = vm.envAddress("KEEPER");
        cfg.emergencyAdmin = vm.envAddress("EMERGENCY_ADMIN");
        cfg.donationAddress = vm.envAddress("DONATION");

        cfg.enableBurning = _envBoolOr("ENABLE_BURNING", false);
        cfg.referral = uint16(_envUintOr("REFERRAL", 0));

        cfg.factoryMaybe = _addrOrZero("FACTORY_SAVINGS");
        if (cfg.factoryMaybe == address(0)) {
            cfg.factoryMaybe = _addrOrZero("FACTORY");
        }
    }

    function run() public {
        require(cfg.deployerKey != 0, "DEPLOYER_PRIVATE_KEY required");
        require(bytes(cfg.name).length != 0, "name empty");
        require(cfg.management != address(0), "management zero");
        require(cfg.keeper != address(0), "keeper zero");
        require(cfg.emergencyAdmin != address(0), "emergency zero");
        require(cfg.donationAddress != address(0), "donation zero");
        require(cfg.asset != address(0), "asset zero");
        require(cfg.sparkVault != address(0), "sparkVault zero");
        require(ISparkVault(cfg.sparkVault).asset() == cfg.asset, "vault.asset mismatch");

        DeploymentResult memory res;
        res.nonceStart = _syncDeployerNonce(cfg.deployer);
        res.deployedFactory = cfg.factoryMaybe == address(0);

        vm.startBroadcast(cfg.deployerKey);
        SparkSavingsStrategyFactory factory = res.deployedFactory
            ? new SparkSavingsStrategyFactory(cfg.deployer)
            : SparkSavingsStrategyFactory(cfg.factoryMaybe);
        res.factory = address(factory);

        (res.tokenizedPred, res.strategyPred) = factory.predictSavingsAddresses(
            cfg.sparkVault,
            cfg.asset,
            cfg.name,
            cfg.management,
            cfg.keeper,
            cfg.emergencyAdmin,
            cfg.donationAddress,
            cfg.enableBurning,
            cfg.referral
        );

        (res.strategy, res.tokenized) = factory.deploySavingsPair(
            cfg.sparkVault,
            cfg.asset,
            cfg.name,
            cfg.management,
            cfg.keeper,
            cfg.emergencyAdmin,
            cfg.donationAddress,
            cfg.enableBurning,
            cfg.referral
        );
        vm.stopBroadcast();

        _logResult(res);
        _writeReport(res);
    }

    function _logResult(DeploymentResult memory res) internal view {
        console2.log("=== Spark Savings YDS Deployment ===");
        console2.log("Chain ID         :", block.chainid);
        console2.log("Deployer         :", cfg.deployer);
        console2.log("Factory          :", res.factory);
        console2.log("Name             :", cfg.name);
        console2.log("Underlying asset :", cfg.asset);
        console2.log("Spark Vault      :", cfg.sparkVault);
        console2.log("Referral         :", cfg.referral);
        console2.log("Enable burning   :", cfg.enableBurning);
        console2.log("Tokenized (pred) :", res.tokenizedPred);
        console2.log("Tokenized (real) :", res.tokenized);
        console2.log("Strategy  (pred) :", res.strategyPred);
        console2.log("Strategy  (real) :", res.strategy);
    }

    function _writeReport(DeploymentResult memory res) internal {
        string memory dir = "reports/spark/savings";
        vm.createDir(dir, true);
        string memory path =
            string.concat(dir, "/deployment-", vm.toString(block.chainid), "-", vm.toString(block.number), ".json");

        string memory label = "deployment";
        string memory json = vm.serializeUint(label, "chainId", block.chainid);
        json = vm.serializeUint(label, "blockNumber", block.number);
        json = vm.serializeAddress(label, "deployer", cfg.deployer);
        json = vm.serializeAddress(label, "factory", res.factory);
        json = vm.serializeString(label, "name", cfg.name);
        json = vm.serializeAddress(label, "sparkVault", cfg.sparkVault);
        json = vm.serializeAddress(label, "asset", cfg.asset);
        json = vm.serializeAddress(label, "strategy", res.strategy);
        json = vm.serializeAddress(label, "tokenized", res.tokenized);
        json = vm.serializeBool(label, "enableBurning", cfg.enableBurning);
        json = vm.serializeUint(label, "referral", cfg.referral);
        json = vm.serializeUint(label, "nonceStart", res.nonceStart);
        vm.writeJson(json, path);
        console2.log("Report written   :", path);
    }
}

