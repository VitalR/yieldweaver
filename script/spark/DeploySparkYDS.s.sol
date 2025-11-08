// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { BaseScript } from "script/common/BaseScript.sol";
import { console2 } from "forge-std/console2.sol";

import { SparkSavingsStrategyFactory } from "src/spark/savings/SparkSavingsStrategyFactory.sol";
import { SparkLendStrategyFactory } from "src/spark/lend/SparkLendStrategyFactory.sol";
import { ISparkVault } from "src/spark/savings/interfaces/ISparkVault.sol";

contract DeploySparkYDSScript is BaseScript {
    enum Kind {
        SAVINGS,
        LEND
    }

    uint256 internal deployerKey;
    address internal deployer;

    // Common configuration
    string internal name;
    address internal management;
    address internal keeper;
    address internal emergencyAdmin;
    address internal donationAddress;
    bool internal enableBurning;
    uint16 internal referral;

    // Savings specific
    address internal sparkVault;

    // Lend specific
    address internal pool;
    address internal aToken;

    address internal asset;
    address internal factoryMaybe;
    Kind internal strategyKind;

    function setUp() public {
        deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        deployer = vm.addr(deployerKey);

        strategyKind = _readStrategyKind();

        if (strategyKind == Kind.SAVINGS) {
            sparkVault = vm.envAddress("SPARK_VAULT");
            asset = vm.envAddress("UNDERLYING");
            name = _envStringOr("NAME_SAVINGS", _envStringOr("NAME", ""));
        } else {
            pool = vm.envAddress("SPARK_POOL");
            aToken = _addrOrZero("SPARK_ATOKEN");
            if (aToken == address(0)) {
                aToken = vm.envAddress("ATOKEN");
            }
            asset = _addrOrZero("UNDERLYING_LEND");
            if (asset == address(0)) {
                asset = vm.envAddress("UNDERLYING");
            }
            name = _envStringOr("NAME_LEND", _envStringOr("NAME", ""));
        }

        management = vm.envAddress("MANAGEMENT");
        keeper = vm.envAddress("KEEPER");
        emergencyAdmin = vm.envAddress("EMERGENCY_ADMIN");
        donationAddress = vm.envAddress("DONATION");

        enableBurning = _envBool("ENABLE_BURNING");
        referral = uint16(_envUintOr("REFERRAL", 0));

        if (strategyKind == Kind.SAVINGS) {
            factoryMaybe = _addrOrZero("FACTORY_SAVINGS");
            if (factoryMaybe == address(0)) {
                factoryMaybe = _addrOrZero("FACTORY");
            }
        } else {
            factoryMaybe = _addrOrZero("FACTORY_LEND");
            if (factoryMaybe == address(0)) {
                factoryMaybe = _addrOrZero("FACTORY");
            }
        }
    }

    function run() public {
        bool isSavings = strategyKind == Kind.SAVINGS;

        // Sanity checks
        require(bytes(name).length != 0, "NAME empty");
        require(
            management != address(0) && keeper != address(0) && emergencyAdmin != address(0)
                && donationAddress != address(0),
            "role addr zero"
        );
        require(asset != address(0), "asset zero");

        if (isSavings) {
            require(sparkVault != address(0), "sparkVault zero");
            address vaultAsset = ISparkVault(sparkVault).asset();
            require(vaultAsset == asset, "vault.asset mismatch");
        } else {
            require(pool != address(0) && aToken != address(0), "pool/aToken zero");
        }

        uint256 deployerNonceBefore = _syncDeployerNonce(deployer);
        bool deploysFactory = factoryMaybe == address(0);

        vm.startBroadcast(deployerKey);
        address factoryAddr;

        address strategy;
        address tokenized;
        address strategyPred;
        address tokenizedPred;

        if (isSavings) {
            SparkSavingsStrategyFactory factory =
                deploysFactory ? new SparkSavingsStrategyFactory(deployer) : SparkSavingsStrategyFactory(factoryMaybe);
            factoryAddr = address(factory);
            (tokenizedPred, strategyPred) = factory.predictSavingsAddresses(
                sparkVault, asset, name, management, keeper, emergencyAdmin, donationAddress, enableBurning, referral
            );
            (strategy, tokenized) = factory.deploySavingsPair(
                sparkVault, asset, name, management, keeper, emergencyAdmin, donationAddress, enableBurning, referral
            );
        } else {
            SparkLendStrategyFactory factory =
                deploysFactory ? new SparkLendStrategyFactory(deployer) : SparkLendStrategyFactory(factoryMaybe);
            factoryAddr = address(factory);
            (tokenizedPred, strategyPred) = factory.predictLendAddresses(
                pool, aToken, asset, name, management, keeper, emergencyAdmin, donationAddress, enableBurning, referral
            );
            (strategy, tokenized) = factory.deployLendPair(
                pool, aToken, asset, name, management, keeper, emergencyAdmin, donationAddress, enableBurning, referral
            );
        }
        vm.stopBroadcast();

        string memory kindLabel = isSavings ? "Savings" : "Lend";
        console2.log(string.concat("=== Spark ", kindLabel, " YDS Deployment ==="));
        console2.log("Chain ID         :", block.chainid);
        console2.log("Deployer         :", deployer);
        console2.log("Factory          :", factoryAddr);
        console2.log("Name             :", name);
        console2.log("Underlying asset :", asset);
        if (isSavings) {
            console2.log("Spark Vault      :", sparkVault);
        } else {
            console2.log("Spark Pool       :", pool);
            console2.log("aToken           :", aToken);
        }
        console2.log("Referral         :", referral);
        console2.log("Enable burning   :", enableBurning);
        console2.log("Tokenized (pred) :", tokenizedPred);
        console2.log("Tokenized (real) :", tokenized);
        console2.log("Strategy  (pred) :", strategyPred);
        console2.log("Strategy  (real) :", strategy);

        _writeDeploymentReport(
            isSavings,
            factoryAddr,
            strategy,
            tokenized,
            strategyPred,
            tokenizedPred,
            deployerNonceBefore,
            deploysFactory
        );
    }

    function _writeDeploymentReport(
        bool isSavings,
        address factoryAddr,
        address strategy,
        address tokenized,
        address strategyPred,
        address tokenizedPred,
        uint256 deployerNonceBefore,
        bool deploysFactory
    ) internal {
        string memory dir = string.concat(vm.projectRoot(), "/reports/spark-yds");
        vm.createDir(dir, true);
        string memory file =
            string.concat(dir, "/deployment-", vm.toString(block.chainid), "-", vm.toString(block.number), ".json");

        uint256 pairNonce = deployerNonceBefore + (deploysFactory ? 1 : 0);
        string memory kindValue = isSavings ? "savings" : "lend";

        bytes memory core = abi.encodePacked(
            "\"chainId\":",
            vm.toString(block.chainid),
            ",\"factory\":\"",
            vm.toString(factoryAddr),
            "\",\"kind\":\"",
            kindValue,
            "\",\"asset\":\"",
            vm.toString(asset),
            "\",\"name\":\"",
            name,
            "\",\"enableBurning\":",
            enableBurning ? "true" : "false",
            ",\"referral\":",
            vm.toString(uint256(referral))
        );

        if (isSavings) {
            core = abi.encodePacked(core, ",\"sparkVault\":\"", vm.toString(sparkVault), "\"");
        } else {
            core = abi.encodePacked(
                core, ",\"pool\":\"", vm.toString(pool), "\",\"aToken\":\"", vm.toString(aToken), "\""
            );
        }

        bytes memory payload = abi.encodePacked(
            "{\"core\":{",
            core,
            "},\"addresses\":{\"tokenized\":\"",
            vm.toString(tokenized),
            "\",\"tokenizedPred\":\"",
            vm.toString(tokenizedPred),
            "\",\"strategy\":\"",
            vm.toString(strategy),
            "\",\"strategyPred\":\"",
            vm.toString(strategyPred),
            "\"},\"roles\":{",
            "\"management\":\"",
            vm.toString(management),
            "\",\"keeper\":\"",
            vm.toString(keeper),
            "\",\"emergencyAdmin\":\"",
            vm.toString(emergencyAdmin),
            "\",\"donationAddress\":\"",
            vm.toString(donationAddress),
            "\"},\"tx\":{",
            "\"deployer\":\"",
            vm.toString(deployer),
            "\",\"nonceStart\":",
            vm.toString(deployerNonceBefore),
            ",\"factoryNonce\":",
            deploysFactory ? vm.toString(deployerNonceBefore) : "null",
            ",\"pairNonce\":",
            vm.toString(pairNonce),
            ",\"deployedFactory\":",
            deploysFactory ? "true" : "false",
            ",\"factoryAddress\":\"",
            vm.toString(factoryAddr),
            "\"}}"
        );

        vm.writeJson(string(payload), file);
    }

    function _readStrategyKind() internal view returns (Kind kind) {
        bool set;
        try vm.envUint("STRAT_KIND") returns (uint256 raw) {
            require(raw <= uint256(Kind.LEND), "invalid STRAT_KIND value");
            kind = Kind(raw);
            set = true;
        } catch { }

        if (!set) {
            string memory label = _envStringOr("STRAT_KIND", "SAVINGS");
            bytes32 h = keccak256(bytes(_lower(label)));
            if (h == keccak256("lend")) {
                kind = Kind.LEND;
            } else {
                kind = Kind.SAVINGS;
            }
        }
    }
}
