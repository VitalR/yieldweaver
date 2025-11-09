// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { BaseScript } from "script/common/BaseScript.sol";
import { console2 } from "forge-std/console2.sol";

import { SparkLendStrategyFactory } from "src/spark/lend/SparkLendStrategyFactory.sol";

contract DeploySparkLendYDSScript is BaseScript {
    struct Config {
        uint256 deployerKey;
        address deployer;
        address pool;
        address aToken;
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

        cfg.pool = vm.envAddress("SPARK_POOL");

        cfg.aToken = _addrOrZero("SPARK_ATOKEN");
        if (cfg.aToken == address(0)) {
            cfg.aToken = vm.envAddress("ATOKEN");
        }

        cfg.asset = _addrOrZero("UNDERLYING_LEND");
        if (cfg.asset == address(0)) {
            cfg.asset = vm.envAddress("UNDERLYING");
        }

        cfg.name = _envStringOr("NAME_LEND", _envStringOr("NAME", ""));
        if (bytes(cfg.name).length == 0) {
            cfg.name = string.concat("SparkLend-", vm.toString(cfg.pool));
        }

        cfg.management = vm.envAddress("MANAGEMENT");
        cfg.keeper = vm.envAddress("KEEPER");
        cfg.emergencyAdmin = vm.envAddress("EMERGENCY_ADMIN");
        cfg.donationAddress = vm.envAddress("DONATION");

        cfg.enableBurning = _envBoolOr("ENABLE_BURNING", false);
        cfg.referral = uint16(_envUintOr("REFERRAL", 0));

        cfg.factoryMaybe = _addrOrZero("FACTORY_LEND");
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
        require(cfg.pool != address(0), "pool zero");
        require(cfg.aToken != address(0), "aToken zero");

        DeploymentResult memory res;
        res.nonceStart = _syncDeployerNonce(cfg.deployer);
        res.deployedFactory = cfg.factoryMaybe == address(0);

        vm.startBroadcast(cfg.deployerKey);
        SparkLendStrategyFactory factory = res.deployedFactory
            ? new SparkLendStrategyFactory(cfg.deployer)
            : SparkLendStrategyFactory(cfg.factoryMaybe);
        res.factory = address(factory);

        (res.tokenizedPred, res.strategyPred) = factory.predictLendAddresses(
            cfg.pool,
            cfg.aToken,
            cfg.asset,
            cfg.name,
            cfg.management,
            cfg.keeper,
            cfg.emergencyAdmin,
            cfg.donationAddress,
            cfg.enableBurning,
            cfg.referral
        );

        (res.strategy, res.tokenized) = factory.deployLendPair(
            cfg.pool,
            cfg.aToken,
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
        console2.log("=== Spark Lend YDS Deployment ===");
        console2.log("Chain ID         :", block.chainid);
        console2.log("Deployer         :", cfg.deployer);
        console2.log("Factory          :", res.factory);
        console2.log("Name             :", cfg.name);
        console2.log("Underlying asset :", cfg.asset);
        console2.log("Spark Pool       :", cfg.pool);
        console2.log("aToken           :", cfg.aToken);
        console2.log("Referral         :", cfg.referral);
        console2.log("Enable burning   :", cfg.enableBurning);
        console2.log("Tokenized (pred) :", res.tokenizedPred);
        console2.log("Tokenized (real) :", res.tokenized);
        console2.log("Strategy  (pred) :", res.strategyPred);
        console2.log("Strategy  (real) :", res.strategy);
    }

    function _writeReport(DeploymentResult memory res) internal {
        string memory dir = "reports/spark/lend";
        vm.createDir(dir, true);
        string memory path =
            string.concat(dir, "/deployment-", vm.toString(block.chainid), "-", vm.toString(block.number), ".json");

        string memory label = "deployment";
        string memory json = vm.serializeUint(label, "chainId", block.chainid);
        json = vm.serializeUint(label, "blockNumber", block.number);
        json = vm.serializeAddress(label, "deployer", cfg.deployer);
        json = vm.serializeAddress(label, "factory", res.factory);
        json = vm.serializeString(label, "name", cfg.name);
        json = vm.serializeAddress(label, "pool", cfg.pool);
        json = vm.serializeAddress(label, "aToken", cfg.aToken);
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
