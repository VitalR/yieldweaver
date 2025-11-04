// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import { AaveV3YieldStrategy } from "src/strategies/AaveV3YieldStrategy.sol";
import { IPool } from "src/external/aave/IPool.sol";
import { MockAavePool } from "test/mocks/MockAavePool.sol";
import { Errors } from "src/common/Errors.sol";

contract AaveV3YieldStrategyUnitTests is Test {
    using SafeERC20 for ERC20Mock;

    ERC20Mock internal assetToken;
    MockAavePool internal mockPool;
    AaveV3YieldStrategy internal strategy;
    address internal vault;

    function setUp() public {
        assetToken = new ERC20Mock();
        mockPool = new MockAavePool(assetToken);
        vault = makeAddr("vault");
        strategy = new AaveV3YieldStrategy({
            _asset: assetToken,
            _pool: IPool(address(mockPool)),
            _aToken: IERC20(mockPool.aTokenAddress()),
            _vault: vault
        });
    }

    function test_onlyVaultCanDeploy() public {
        vm.expectRevert(Errors.NotVault.selector);
        strategy.deploy(0);
    }

    function test_deploySuppliesIdleBalanceToAave() public {
        assetToken.mint(address(strategy), 1000 ether);

        vm.prank(vault);
        strategy.deploy(0);

        assertEq(assetToken.balanceOf(address(mockPool)), 1000 ether, "pool receives asset");
        assertEq(IERC20(mockPool.aTokenAddress()).balanceOf(address(strategy)), 1000 ether, "strategy aToken balance");
    }

    function test_withdrawRedeemsFromAave() public {
        assetToken.mint(address(strategy), 1000 ether);
        vm.prank(vault);
        strategy.deploy(0);

        vm.prank(vault);
        uint256 withdrawn = strategy.withdraw(400 ether, address(this));

        assertEq(withdrawn, 400 ether, "withdraw amount");
        assertEq(assetToken.balanceOf(address(this)), 400 ether, "receiver balance");
        assertEq(IERC20(mockPool.aTokenAddress()).balanceOf(address(strategy)), 600 ether, "aToken balance reduced");
    }

    function test_harvestReturnsAccruedProfit() public {
        assetToken.mint(address(strategy), 1000 ether);
        vm.prank(vault);
        strategy.deploy(0);

        mockPool.accrueInterest(address(strategy), 100 ether);

        vm.prank(vault);
        uint256 profit = strategy.harvest();
        assertEq(profit, 100 ether, "harvested profit");
    }

    function test_emergencyWithdrawToReceiver() public {
        assetToken.mint(address(strategy), 1000 ether);
        vm.prank(vault);
        strategy.deploy(0);

        address receiver = makeAddr("receiver");
        vm.prank(vault);
        uint256 amount = strategy.emergencyWithdraw(receiver);

        assertEq(assetToken.balanceOf(receiver), 1000 ether, "receiver gets assets");
        assertEq(amount, 1000 ether, "returned amount matches");
        assertEq(IERC20(mockPool.aTokenAddress()).balanceOf(address(strategy)), 0, "aToken cleared");
    }

    function test_emergencyWithdrawForTokenizedInterface() public {
        assetToken.mint(address(strategy), 1000 ether);
        vm.prank(vault);
        strategy.deploy(0);

        vm.prank(address(this));
        uint256 beforeBalance = assetToken.balanceOf(address(this));
        strategy.emergencyWithdraw(600 ether);
        assertEq(assetToken.balanceOf(address(this)) - beforeBalance, 600 ether, "caller receives");
    }

    function test_totalAssetsReflectsIdleAndInvested() public {
        assetToken.mint(address(strategy), 1000 ether);
        vm.prank(vault);
        strategy.deploy(0);

        assetToken.mint(address(strategy), 50 ether); // idle balance
        uint256 expected = 1000 ether + 50 ether;
        assertEq(strategy.totalAssets(), expected, "total assets includes idle and invested");
    }

    function test_initialize_setsRoleAddresses() public {
        address management = makeAddr("management");
        address keeper = makeAddr("keeper");
        address emergency = makeAddr("emergency");
        address dragon = makeAddr("dragon");

        strategy.initialize(address(assetToken), "", management, keeper, emergency, dragon, true);

        assertEq(strategy.management(), management, "management updated");
        assertEq(strategy.keeper(), keeper, "keeper updated");
        assertEq(strategy.emergencyAdmin(), emergency, "emergency updated");
        assertEq(strategy.dragonRouter(), dragon, "dragon router updated");
    }

    function test_initialize_revertsForMismatchedAsset() public {
        address otherAsset = makeAddr("otherAsset");
        vm.expectRevert(Errors.InvalidAsset.selector);
        strategy.initialize(otherAsset, "", address(this), address(this), address(this), address(this), false);
    }

    function test_requireManagement_checksSender() public {
        address management = makeAddr("managementRole");
        strategy.initialize(address(assetToken), "", management, address(0x1), address(0x2), address(0x3), false);
        strategy.requireManagement(management);
        vm.expectRevert(Errors.NotManagement.selector);
        strategy.requireManagement(address(0xBEEF));
    }

    function test_requireKeeperOrManagement_checksBoth() public {
        address management = makeAddr("managementRole");
        address keeper = makeAddr("keeperRole");
        strategy.initialize(address(assetToken), "", management, keeper, address(0x2), address(0x3), false);
        strategy.requireKeeperOrManagement(management);
        strategy.requireKeeperOrManagement(keeper);
        vm.expectRevert(Errors.NotKeeperOrManagement.selector);
        strategy.requireKeeperOrManagement(address(0xBEEF));
    }

    function test_requireEmergencyAuthorized_checksRoles() public {
        address management = makeAddr("managementRole");
        address emergency = makeAddr("emergencyRole");
        strategy.initialize(address(assetToken), "", management, address(0x1), emergency, address(0x3), false);
        strategy.requireEmergencyAuthorized(management);
        strategy.requireEmergencyAuthorized(emergency);
        vm.expectRevert(Errors.NotEmergencyAuthorized.selector);
        strategy.requireEmergencyAuthorized(address(0xBEEF));
    }

    function test_setPendingManagement_andAccept() public {
        address management = makeAddr("managementRole");
        address successor = makeAddr("successor");
        strategy.initialize(address(assetToken), "", management, address(0x1), address(0x2), address(0x3), false);

        strategy.setPendingManagement(successor);
        assertEq(strategy.pendingManagement(), successor, "pending set");

        vm.startPrank(successor);
        strategy.acceptManagement();
        vm.stopPrank();

        assertEq(strategy.management(), successor, "management transferred");
        assertEq(strategy.pendingManagement(), address(0), "pending cleared");
    }

    function test_acceptManagement_revertsWhenNoPending() public {
        vm.expectRevert(Errors.NoPendingManagement.selector);
        strategy.acceptManagement();
    }

    function test_dragonRouterChangeLifecycle() public {
        address dragon = makeAddr("dragon");
        address pendingDragon = makeAddr("pendingDragon");
        strategy.initialize(address(assetToken), "", address(this), address(this), address(this), dragon, false);

        strategy.setDragonRouter(pendingDragon);
        assertEq(strategy.pendingDragonRouter(), pendingDragon, "pending router set");
        assertEq(strategy.dragonRouterChangeTimestamp(), block.timestamp, "timestamp recorded");

        strategy.finalizeDragonRouterChange();
        assertEq(strategy.dragonRouter(), pendingDragon, "router updated");
        assertEq(strategy.pendingDragonRouter(), address(0), "pending cleared");
        assertEq(strategy.dragonRouterChangeTimestamp(), 0, "timestamp cleared");
    }

    function test_cancelDragonRouterChange_resetsState() public {
        address dragon = makeAddr("dragon");
        address pendingDragon = makeAddr("pendingDragon");
        strategy.initialize(address(assetToken), "", address(this), address(this), address(this), dragon, false);

        strategy.setDragonRouter(pendingDragon);
        strategy.cancelDragonRouterChange();

        assertEq(strategy.pendingDragonRouter(), address(0), "pending cleared");
        assertEq(strategy.dragonRouterChangeTimestamp(), 0, "timestamp reset");
        assertEq(strategy.dragonRouter(), dragon, "router unchanged");
    }

    function test_shutdownStrategy_preventsFutureDeploys() public {
        assetToken.mint(address(strategy), 1000 ether);
        vm.prank(vault);
        strategy.deploy(0);
        assertEq(assetToken.balanceOf(address(mockPool)), 1000 ether, "initial supply");

        strategy.shutdownStrategy();
        assetToken.mint(address(strategy), 500 ether);
        vm.prank(vault);
        strategy.deploy(0);

        assertEq(assetToken.balanceOf(address(mockPool)), 1000 ether, "no additional supply after shutdown");
    }

    function test_emergencyWithdraw_ITokenizedFlushesToCaller() public {
        assetToken.mint(address(strategy), 1000 ether);
        vm.prank(vault);
        strategy.deploy(0);

        uint256 before = assetToken.balanceOf(address(this));
        strategy.emergencyWithdraw(700 ether);
        uint256 afterBalance = assetToken.balanceOf(address(this));

        assertEq(afterBalance - before, 700 ether, "caller receives underlying");
    }

    function test_setKeeper_updatesRole() public {
        address keeper = makeAddr("newKeeper");
        strategy.setKeeper(keeper);
        assertEq(strategy.keeper(), keeper, "keeper updated");
    }

    function test_setEmergencyAdmin_updatesRole() public {
        address emergency = makeAddr("newEmergency");
        strategy.setEmergencyAdmin(emergency);
        assertEq(strategy.emergencyAdmin(), emergency, "emergency admin updated");
    }

    function test_setName_doesNotRevert() public {
        strategy.setName("Updated Strategy Name");
    }

    function test_pricePerShareReflectsGains() public {
        address depositor = makeAddr("depositor");
        assetToken.mint(depositor, 100 ether);
        vm.prank(depositor);
        assetToken.approve(address(strategy), 100 ether);
        vm.prank(depositor);
        strategy.deposit(100 ether, depositor);

        mockPool.accrueInterest(address(strategy), 50 ether);

        uint256 pps = strategy.pricePerShare();
        assertApproxEqAbs(pps, 1.5e18, 1 wei, "price per share tracks gains");
    }

    function test_maxWithdrawReflectsAccruedYield() public {
        address depositor = makeAddr("depositor");
        assetToken.mint(depositor, 200 ether);
        vm.prank(depositor);
        assetToken.approve(address(strategy), 200 ether);
        vm.prank(depositor);
        strategy.deposit(200 ether, depositor);

        mockPool.accrueInterest(address(strategy), 80 ether);

        uint256 maxWithdrawAmount = strategy.maxWithdraw(depositor, 0);
        assertApproxEqAbs(maxWithdrawAmount, 280 ether, 1, "max withdraw includes interest");

        uint256 maxRedeemShares = strategy.maxRedeem(depositor, 0);
        assertEq(maxRedeemShares, strategy.balanceOf(depositor), "max redeem equals share balance");
    }
}
