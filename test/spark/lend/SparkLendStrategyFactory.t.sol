// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { SparkLendStrategyFactory } from "src/spark/lend/SparkLendStrategyFactory.sol";
import { SparkLendDonationStrategy } from "src/spark/lend/SparkLendDonationStrategy.sol";
import { MockAavePool } from "test/mocks/MockAavePool.sol";
import { MockUSDC } from "test/mocks/MockUSDC.sol";
import { Errors } from "src/common/Errors.sol";

contract SparkLendStrategyFactoryUnitTest is Test {
    SparkLendStrategyFactory factory;
    MockUSDC asset;
    MockAavePool pool;
    address aToken;

    address management = makeAddr("management");
    address keeper = makeAddr("keeper");
    address emergencyAdmin = makeAddr("emergencyAdmin");
    address donation = makeAddr("donation");

    function setUp() public {
        asset = new MockUSDC();
        pool = new MockAavePool(asset);
        aToken = pool.aTokenAddress();
        factory = new SparkLendStrategyFactory(address(this));
    }

    function _params()
        internal
        view
        returns (
            address poolAddress,
            address aTokenAddress,
            address lendAsset,
            string memory name,
            address _management,
            address _keeper,
            address _emergencyAdmin,
            address _donation,
            bool enableBurning,
            uint16 referral
        )
    {
        poolAddress = address(pool);
        aTokenAddress = aToken;
        lendAsset = address(asset);
        name = "Spark Lend Test";
        _management = management;
        _keeper = keeper;
        _emergencyAdmin = emergencyAdmin;
        _donation = donation;
        enableBurning = false;
        referral = 11;
    }

    struct DeploymentResult {
        address strategy;
        address tokenized;
        address strategyPred;
        address tokenizedPred;
        address lendAsset;
        address poolAddress;
        address aTokenAddress;
        uint16 referral;
    }

    function test_deployRegistersAndMatchesPredict() public {
        DeploymentResult memory res = _deployAndPredict();

        assertEq(res.strategy, res.strategyPred);
        assertEq(res.tokenized, res.tokenizedPred);
        assertEq(factory.getDeployedLendStrategy(res.lendAsset, res.poolAddress), res.strategy);

        SparkLendDonationStrategy deployed = SparkLendDonationStrategy(res.strategy);
        assertEq(address(deployed.POOL()), res.poolAddress);
        assertEq(address(deployed.ATOKEN()), res.aTokenAddress);
        assertEq(deployed.referral(), res.referral);
    }

    function _deployAndPredict() internal returns (DeploymentResult memory res) {
        (
            address poolAddress,
            address aTokenAddress,
            address lendAsset,
            string memory name,
            address _management,
            address _keeper,
            address _emergencyAdmin,
            address _donation,
            bool enableBurning,
            uint16 referral
        ) = _params();

        (res.tokenizedPred, res.strategyPred) = factory.predictLendAddresses(
            poolAddress,
            aTokenAddress,
            lendAsset,
            name,
            _management,
            _keeper,
            _emergencyAdmin,
            _donation,
            enableBurning,
            referral
        );

        (res.strategy, res.tokenized) = factory.deployLendPair(
            poolAddress,
            aTokenAddress,
            lendAsset,
            name,
            _management,
            _keeper,
            _emergencyAdmin,
            _donation,
            enableBurning,
            referral
        );

        res.lendAsset = lendAsset;
        res.poolAddress = poolAddress;
        res.aTokenAddress = aTokenAddress;
        res.referral = referral;
    }

    function test_deploySecondTimeReverts() public {
        (
            address poolAddress,
            address aTokenAddress,
            address lendAsset,
            string memory name,
            address _management,
            address _keeper,
            address _emergencyAdmin,
            address _donation,
            bool enableBurning,
            uint16 referral
        ) = _params();

        factory.deployLendPair(
            poolAddress,
            aTokenAddress,
            lendAsset,
            name,
            _management,
            _keeper,
            _emergencyAdmin,
            _donation,
            enableBurning,
            referral
        );

        vm.expectRevert(Errors.AlreadyDeployed.selector);
        factory.deployLendPair(
            poolAddress,
            aTokenAddress,
            lendAsset,
            name,
            _management,
            _keeper,
            _emergencyAdmin,
            _donation,
            enableBurning,
            referral
        );
    }

    function test_onlyOwnerCanDeploy() public {
        (
            address poolAddress,
            address aTokenAddress,
            address lendAsset,
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
        factory.deployLendPair(
            poolAddress,
            aTokenAddress,
            lendAsset,
            name,
            _management,
            _keeper,
            _emergencyAdmin,
            _donation,
            enableBurning,
            referral
        );
    }

    function test_zeroPoolReverts() public {
        (
            ,
            address aTokenAddress,
            address lendAsset,
            string memory name,
            address _management,
            address _keeper,
            address _emergencyAdmin,
            address _donation,
            bool enableBurning,
            uint16 referral
        ) = _params();

        vm.expectRevert(Errors.ZeroAddress.selector);
        factory.deployLendPair(
            address(0),
            aTokenAddress,
            lendAsset,
            name,
            _management,
            _keeper,
            _emergencyAdmin,
            _donation,
            enableBurning,
            referral
        );
    }
}
