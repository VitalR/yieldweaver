// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { BaseScript } from "script/common/BaseScript.sol";
import { console2 } from "forge-std/console2.sol";
import { SparkSavingsDonationStrategyFactory } from "src/spark/SparkSavingsDonationStrategyFactory.sol";
import { ISparkVault } from "src/spark/ISparkVault.sol";

/// @dev Env vars (recommended):
///   DEPLOYER_PRIVATE_KEY (uint)
///   FACTORY (address, optional; if zero or unset, deploy a new factory)
///   SPARK_VAULT (address)  -> e.g., spUSDC
///   UNDERLYING  (address)  -> e.g., USDC mainnet addr (mirrored in VNet)
///   NAME        (string)   -> e.g., "Spark USDC YDS Tokenized"
///   MANAGEMENT  (address)
///   KEEPER      (address)
///   EMERGENCY_ADMIN (address)
///   DONATION    (address)
///   ENABLE_BURNING (bool)  -> "true"/"false"
///   REFERRAL    (uint16)   -> 0 to disable
contract DeploySparkYDSScript is BaseScript {
    uint256 deployerKey;
    address deployer;
    address initialOwner;
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

    function setUp() public {
        // --- Load env ---
        deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        deployer = vm.addr(deployerKey);
        initialOwner = deployer;

        // Ethereum SparkVault.sol: Spark USDC spUSDC
        // https://etherscan.io/address/0x28B3a8fb53B741A8Fd78c0fb9A6B2393d896a43d#code
        sparkVault = vm.envAddress("SPARK_VAULT");
        // Ethereum USDC USDC
        // https://etherscan.io/address/0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48#code
        asset = vm.envAddress("UNDERLYING");
        name = vm.envString("NAME");

        management = vm.envAddress("MANAGEMENT");
        keeper = vm.envAddress("KEEPER");
        emergencyAdmin = vm.envAddress("EMERGENCY_ADMIN");
        donationAddress = vm.envAddress("DONATION");

        enableBurning = _envBool("ENABLE_BURNING");
        referral = uint16(_envUintOr("REFERRAL", 0));

        // optional factory
        factoryMaybe = _addrOrZero("FACTORY");
    }

    function run() public {
        // --- Sanity checks (script-level policy; strategy will also enforce invariants in constructor) ---
        require(sparkVault != address(0) && asset != address(0), "sparkVault/asset is zero");
        require(bytes(name).length != 0, "NAME empty");
        require(
            management != address(0) && keeper != address(0) && emergencyAdmin != address(0)
                && donationAddress != address(0),
            "role addr zero"
        );

        // Verify the ERC-4626 invariant on-chain before spending gas deploying:
        address vaultAsset = ISparkVault(sparkVault).asset();
        require(vaultAsset == asset, "vault.asset() mismatch");

        // Align the local simulation nonce with the on-chain nonce so CREATE addresses match reality.
        uint256 deployerNonceBefore = _syncDeployerNonce(deployer);
        bool deploysFactory = factoryMaybe == address(0);

        vm.startBroadcast(deployerKey);

        // --- Use existing factory or deploy a new one owned by the deployer EOA ---
        SparkSavingsDonationStrategyFactory factory = deploysFactory
            ? new SparkSavingsDonationStrategyFactory(vm.addr(deployerKey))
            : SparkSavingsDonationStrategyFactory(factoryMaybe);
        address factoryAddr = address(factory);

        // --- Predict addresses (so we can print & store them before deploying) ---
        (address tokenizedPred, address strategyPred) = factory.predictAddresses(
            sparkVault, asset, name, management, keeper, emergencyAdmin, donationAddress, enableBurning, referral
        );

        // --- Deploy pair (CREATE2 for TokenizedStrategy + CREATE2 for Strategy) ---
        (address strategy, address tokenized) = factory.deployPair(
            sparkVault, asset, name, management, keeper, emergencyAdmin, donationAddress, enableBurning, referral
        );

        vm.stopBroadcast();

        // --- Console report ---
        console2.log("=== Spark YDS Deployment ===");
        console2.log("Chain ID         :", block.chainid);
        console2.log("Deployer         :", deployer);
        console2.log("Deployer nonce   :", deployerNonceBefore);
        console2.log("Factory          :", factoryAddr);
        console2.log("Spark Vault (v2) :", sparkVault);
        console2.log("Underlying asset :", asset);
        console2.log("Name             :", name);
        console2.log("Referral         :", referral);
        console2.log("Enable burning   :", enableBurning);

        console2.log("Tokenized (pred) :", tokenizedPred);
        console2.log("Tokenized (real) :", tokenized);
        console2.log("Strategy  (pred) :", strategyPred);
        console2.log("Strategy  (real) :", strategy);

        // --- Persist deployment info (single folder, rolling latest + versioned by block) ---
        // ./reports/spark-yds/deployment-<chainId>-<blockNumber>.json
        string memory dir = string.concat(vm.projectRoot(), "/reports/spark-yds");
        vm.createDir(dir, true);

        string memory file =
            string.concat(dir, "/deployment-", vm.toString(block.chainid), "-", vm.toString(block.number), ".json");

        uint256 pairTxNonce = deployerNonceBefore + (deploysFactory ? 1 : 0);

        string memory payload = string.concat(
            "{",
            "\"core\":{",
            "\"chainId\":",
            vm.toString(block.chainid),
            ",",
            "\"factory\":\"",
            vm.toString(factoryAddr),
            "\",",
            "\"sparkVault\":\"",
            vm.toString(sparkVault),
            "\",",
            "\"asset\":\"",
            vm.toString(asset),
            "\",",
            "\"name\":\"",
            name,
            "\",",
            "\"enableBurning\":",
            (enableBurning ? "true" : "false"),
            ",",
            "\"referral\":",
            vm.toString(uint256(referral)),
            "},",
            "\"addresses\":{",
            "\"tokenized\":\"",
            vm.toString(tokenized),
            "\",",
            "\"strategy\":\"",
            vm.toString(strategy),
            "\"",
            "},",
            "\"roles\":{",
            "\"management\":\"",
            vm.toString(management),
            "\",",
            "\"keeper\":\"",
            vm.toString(keeper),
            "\",",
            "\"emergencyAdmin\":\"",
            vm.toString(emergencyAdmin),
            "\",",
            "\"donationAddress\":\"",
            vm.toString(donationAddress),
            "\"",
            "},",
            "\"tx\":{",
            "\"deployer\":\"",
            vm.toString(deployer),
            "\",",
            "\"nonceStart\":",
            vm.toString(deployerNonceBefore),
            ",",
            "\"factoryNonce\":",
            deploysFactory ? vm.toString(deployerNonceBefore) : "null",
            ",",
            "\"pairNonce\":",
            vm.toString(pairTxNonce),
            ",",
            "\"deployedFactory\":",
            deploysFactory ? "true" : "false",
            ",",
            "\"factoryAddress\":\"",
            vm.toString(factoryAddr),
            "\"",
            "}",
            "}"
        );
        vm.writeJson(payload, file);
    }
}

// == Logs ==
//   === Spark YDS Deployment ===
//   Chain ID         : 8
//   Factory          : 0x14c35DdF059f82f2Eff39B6cA5807f5090496fBC
//   Spark Vault (v2) : 0x28B3a8fb53B741A8Fd78c0fb9A6B2393d896a43d
//   Underlying asset : 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
//   Name             : Spark USDC YDS Tokenized
//   Referral         : 0
//   Enable burning   : true
//   Tokenized (pred) : 0x6BfF139Ca54Ae7d3890F2F8d69Ec026e5ee7ba78
//   Tokenized (real) : 0x6BfF139Ca54Ae7d3890F2F8d69Ec026e5ee7ba78
//   Strategy  (pred) : 0xA506072661441Aee374f35390D8A459aba9a4322
//   Strategy  (real) : 0xA506072661441Aee374f35390D8A459aba9a4322

// # asset() should be USDC on mainnet
// set -a; source .env; set +a
// cast call 0x28B3a8fb53B741A8Fd78c0fb9A6B2393d896a43d "asset()(address)" \
//   --rpc-url "$ETH_RPC_URL"

// # optional: name/version/totalAssets
// cast call 0x28B3a8fb53B741A8Fd78c0fb9A6B2393d896a43d "name()(string)" \
//   --rpc-url "$ETH_RPC_URL"
// cast call 0x28B3a8fb53B741A8Fd78c0fb9A6B2393d896a43d "totalAssets()(uint256)" \
//   --rpc-url "$ETH_RPC_URL"

// # underlying token (USDC) quick check
// cast call 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 "symbol()(string)" \
//   --rpc-url "$ETH_RPC_URL"
// cast call 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 "decimals()(uint8)" \
//   --rpc-url "$ETH_RPC_URL"

// set -a; source .env; set +a
// forge script script/spark/DeploySparkYDS.s.sol:DeploySparkYDSScript \
//   --rpc-url "$ETH_RPC_URL" \
//   --private-key "$DEPLOYER_PRIVATE_KEY" \
//   --broadcast -vvvv
