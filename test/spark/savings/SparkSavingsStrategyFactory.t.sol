// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { SparkSavingsStrategyFactory } from "src/spark/savings/SparkSavingsStrategyFactory.sol";
import { SparkSavingsDonationStrategy } from "src/spark/savings/SparkSavingsDonationStrategy.sol";
import { MockSparkVault } from "test/mocks/MockSparkVault.sol";
import { MockUSDC } from "test/mocks/MockUSDC.sol";
import { Errors } from "src/common/Errors.sol";

contract SparkSavingsStrategyFactoryUnitTest is Test {
    SparkSavingsStrategyFactory factory;
    MockUSDC asset;
    MockSparkVault vault;

    address management = makeAddr("management");
    address keeper = makeAddr("keeper");
    address emergencyAdmin = makeAddr("emergencyAdmin");
    address donation = makeAddr("donation");

    function setUp() public {
        asset = new MockUSDC();
        vault = new MockSparkVault(asset, "Mock spUSDC", "mspUSDC");
        factory = new SparkSavingsStrategyFactory(address(this));
    }

    function _params()
        internal
        view
        returns (
            address sparkVault,
            address savingsAsset,
            string memory name,
            address _management,
            address _keeper,
            address _emergencyAdmin,
            address _donation,
            bool enableBurning,
            uint16 referral
        )
    {
        sparkVault = address(vault);
        savingsAsset = address(asset);
        name = "Spark Savings Test";
        _management = management;
        _keeper = keeper;
        _emergencyAdmin = emergencyAdmin;
        _donation = donation;
        enableBurning = true;
        referral = 7;
    }

    struct DeploymentResult {
        address strategy;
        address tokenized;
        address strategyPred;
        address tokenizedPred;
        address savingsAsset;
        address sparkVault;
        uint16 referral;
    }

    function test_deployRegistersAndMatchesPredict() public {
        DeploymentResult memory res = _deployAndPredict();

        assertEq(res.strategy, res.strategyPred);
        assertEq(res.tokenized, res.tokenizedPred);
        assertEq(factory.getDeployedSavingsStrategy(res.savingsAsset, res.sparkVault), res.strategy);

        SparkSavingsDonationStrategy deployed = SparkSavingsDonationStrategy(res.strategy);
        assertEq(address(deployed.SPARK_VAULT()), res.sparkVault);
        assertEq(deployed.referral(), res.referral);
    }

    function _deployAndPredict() internal returns (DeploymentResult memory res) {
        (
            address sparkVault,
            address savingsAsset,
            string memory name,
            address _management,
            address _keeper,
            address _emergencyAdmin,
            address _donation,
            bool enableBurning,
            uint16 referral
        ) = _params();

        (res.tokenizedPred, res.strategyPred) = factory.predictSavingsAddresses(
            sparkVault, savingsAsset, name, _management, _keeper, _emergencyAdmin, _donation, enableBurning, referral
        );

        (res.strategy, res.tokenized) = factory.deploySavingsPair(
            sparkVault, savingsAsset, name, _management, _keeper, _emergencyAdmin, _donation, enableBurning, referral
        );

        res.savingsAsset = savingsAsset;
        res.sparkVault = sparkVault;
        res.referral = referral;
    }

    function test_deploySecondTimeReverts() public {
        (
            address sparkVault,
            address savingsAsset,
            string memory name,
            address _management,
            address _keeper,
            address _emergencyAdmin,
            address _donation,
            bool enableBurning,
            uint16 referral
        ) = _params();

        factory.deploySavingsPair(
            sparkVault, savingsAsset, name, _management, _keeper, _emergencyAdmin, _donation, enableBurning, referral
        );

        vm.expectRevert(Errors.AlreadyDeployed.selector);
        factory.deploySavingsPair(
            sparkVault, savingsAsset, name, _management, _keeper, _emergencyAdmin, _donation, enableBurning, referral
        );
    }

    function test_onlyOwnerCanDeploy() public {
        (
            address sparkVault,
            address savingsAsset,
            string memory name,
            address _management,
            address _keeper,
            address _emergencyAdmin,
            address _donation,
            bool enableBurning,
            uint16 referral
        ) = _params();

        address intruder = makeAddr("intruder");
        vm.prank(intruder);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, intruder));
        factory.deploySavingsPair(
            sparkVault, savingsAsset, name, _management, _keeper, _emergencyAdmin, _donation, enableBurning, referral
        );
    }

    function test_zeroVaultReverts() public {
        (
            ,
            address savingsAsset,
            string memory name,
            address _management,
            address _keeper,
            address _emergencyAdmin,
            address _donation,
            bool enableBurning,
            uint16 referral
        ) = _params();

        vm.expectRevert(Errors.ZeroAddress.selector);
        factory.deploySavingsPair(
            address(0), savingsAsset, name, _management, _keeper, _emergencyAdmin, _donation, enableBurning, referral
        );
    }
}
