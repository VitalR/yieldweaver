// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import { YieldWeaverVault } from "src/YieldWeaverVault.sol";
import { IYieldStrategy } from "src/interfaces/IYieldStrategy.sol";
import { MockYieldStrategy } from "test/mocks/MockYieldStrategy.sol";

contract YieldWeaverVaultUnitTests is Test {
    using SafeERC20 for ERC20Mock;

    ERC20Mock internal assetToken;
    YieldWeaverVault internal vault;
    address internal donation;
    MockYieldStrategy internal strategyA;
    MockYieldStrategy internal strategyB;

    function setUp() public {
        assetToken = new ERC20Mock();
        donation = makeAddr("donation");
        vault = new YieldWeaverVault({
            _asset: assetToken,
            _name: "Yield Weaver Share",
            _symbol: "YWS",
            _donationAddress: donation,
            _initialOwner: address(this)
        });

        strategyA = new MockYieldStrategy(assetToken);
        strategyB = new MockYieldStrategy(assetToken);
    }

    function test_constructor_revertsWhenAssetZero() public {
        vm.expectRevert(YieldWeaverVault.InvalidAsset.selector);
        new YieldWeaverVault({
            _asset: ERC20Mock(address(0)),
            _name: "Bad",
            _symbol: "BAD",
            _donationAddress: donation,
            _initialOwner: address(this)
        });
    }

    function test_constructor_revertsWhenDonationZero() public {
        vm.expectRevert(YieldWeaverVault.DonationAddressZero.selector);
        new YieldWeaverVault({
            _asset: assetToken, _name: "Bad", _symbol: "BAD", _donationAddress: address(0), _initialOwner: address(this)
        });
    }

    function test_setDonationAddress_updatesAndEmits() public {
        address newDonation = makeAddr("newDonation");
        vm.expectEmit(true, true, false, false);
        emit YieldWeaverVault.DonationAddressUpdated(donation, newDonation);
        vault.setDonationAddress(newDonation);
        assertEq(vault.donationAddress(), newDonation);
    }

    function test_setDonationAddress_revertsOnZero() public {
        vm.expectRevert(YieldWeaverVault.DonationAddressZero.selector);
        vault.setDonationAddress(address(0));
    }

    function test_addStrategy_registersStrategy() public {
        vault.addStrategy(IYieldStrategy(address(strategyA)), 6000, true);

        YieldWeaverVault.StrategyPosition[] memory positions = vault.strategies();
        assertEq(positions.length, 1, "strategy count");
        assertEq(address(positions[0].strategy), address(strategyA), "strategy address");
        assertEq(positions[0].allocationBps, 6000, "allocation");
        assertTrue(positions[0].isActive, "active flag");
        assertEq(vault.activeAllocationBps(), 6000, "active sum");
    }

    function test_addStrategy_revertsOnDuplicate() public {
        vault.addStrategy(IYieldStrategy(address(strategyA)), 5000, true);
        vm.expectRevert(YieldWeaverVault.StrategyAlreadyExists.selector);
        vault.addStrategy(IYieldStrategy(address(strategyA)), 1000, true);
    }

    function test_addStrategy_revertsOnAssetMismatch() public {
        ERC20Mock altToken = new ERC20Mock();
        MockYieldStrategy badStrategy = new MockYieldStrategy(altToken);
        vm.expectRevert(YieldWeaverVault.InvalidAsset.selector);
        vault.addStrategy(IYieldStrategy(address(badStrategy)), 1000, true);
    }

    function test_updateStrategy_updatesAllocation() public {
        vault.addStrategy(IYieldStrategy(address(strategyA)), 3000, true);
        vault.addStrategy(IYieldStrategy(address(strategyB)), 2000, true);

        vault.updateStrategy(0, 7000, true);

        YieldWeaverVault.StrategyPosition[] memory positions = vault.strategies();
        assertEq(positions[0].allocationBps, 7000, "updated allocation");
        assertEq(vault.activeAllocationBps(), 9000, "active sum updated");
    }

    function test_updateStrategy_revertsWhenOutOfBounds() public {
        vm.expectRevert(abi.encodeWithSelector(YieldWeaverVault.StrategyNotActive.selector, 0));
        vault.updateStrategy(0, 1000, true);
    }

    function test_setAllocations_updatesAll() public {
        vault.addStrategy(IYieldStrategy(address(strategyA)), 5000, true);
        vault.addStrategy(IYieldStrategy(address(strategyB)), 4000, true);

        uint16[] memory allocations = new uint16[](2);
        allocations[0] = 6000;
        allocations[1] = 1000;

        vault.setAllocations(allocations);

        YieldWeaverVault.StrategyPosition[] memory positions = vault.strategies();
        assertEq(positions[0].allocationBps, 6000);
        assertEq(positions[1].allocationBps, 1000);
        assertEq(vault.activeAllocationBps(), 7000);
    }

    function test_setAllocations_revertsOnLengthMismatch() public {
        vault.addStrategy(IYieldStrategy(address(strategyA)), 5000, true);
        uint16[] memory allocations = new uint16[](2);
        vm.expectRevert(YieldWeaverVault.AllocationMismatch.selector);
        vault.setAllocations(allocations);
    }

    function test_addStrategy_revertsWhenAllocationExceedsBasis() public {
        vault.addStrategy(IYieldStrategy(address(strategyA)), 9000, true);
        vm.expectRevert(abi.encodeWithSelector(YieldWeaverVault.InvalidAllocationSum.selector, 11_000));
        vault.addStrategy(IYieldStrategy(address(strategyB)), 2000, true);
    }

    function test_setAllocations_revertsWhenAllocationExceedsBasis() public {
        vault.addStrategy(IYieldStrategy(address(strategyA)), 6000, true);
        vault.addStrategy(IYieldStrategy(address(strategyB)), 3000, true);

        uint16[] memory allocations = new uint16[](2);
        allocations[0] = 7000;
        allocations[1] = 4000;

        vm.expectRevert(abi.encodeWithSelector(YieldWeaverVault.InvalidAllocationSum.selector, 11_000));
        vault.setAllocations(allocations);
    }

    function test_updateStrategy_canDeactivate() public {
        vault.addStrategy(IYieldStrategy(address(strategyA)), 5000, true);
        vault.addStrategy(IYieldStrategy(address(strategyB)), 4000, true);

        vault.updateStrategy(0, 5000, false);

        YieldWeaverVault.StrategyPosition[] memory positions = vault.strategies();
        assertFalse(positions[0].isActive, "strategy deactivated");
        assertEq(vault.activeAllocationBps(), 4000, "active sum updated");
    }

    function test_totalStrategyAssets_ignoresInactiveStrategies() public {
        vault.addStrategy(IYieldStrategy(address(strategyA)), 6000, true);
        vault.addStrategy(IYieldStrategy(address(strategyB)), 4000, true);
        vault.updateStrategy(1, 4000, false);

        _mintAndApprove(address(this), 1000 ether);
        vault.deposit(1000 ether, address(this));

        uint256 expected = assetToken.balanceOf(address(strategyA));
        assertEq(vault.totalStrategyAssets(), expected, "inactive strategy ignored");
    }

    function test_harvestNoChangeKeepsBaseline() public {
        vault.addStrategy(IYieldStrategy(address(strategyA)), 10_000, true);
        _mintAndApprove(address(this), 1000 ether);
        vault.deposit(1000 ether, address(this));

        (uint256 profit, uint256 loss) = vault.harvest();
        assertEq(profit, 0, "profit zero");
        assertEq(loss, 0, "loss zero");
        assertEq(vault.balanceOf(donation), 0, "no donation shares");
    }

    function test_harvestWithLossBufferDisabled_doesNotBurnDonationShares() public {
        vault.addStrategy(IYieldStrategy(address(strategyA)), 10_000, true);

        _mintAndApprove(address(this), 1000 ether);
        vault.deposit(1000 ether, address(this));
        strategyA.simulateProfit(200 ether);
        vault.harvest();
        uint256 before = vault.balanceOf(donation);
        assertGt(before, 0, "donation shares minted");

        vault.setDonationLossBufferEnabled(false);
        strategyA.simulateLoss(200 ether);
        vault.harvest();
        assertEq(vault.balanceOf(donation), before, "donation shares unchanged when buffer disabled");
    }

    function test_withdrawHandlesStrategyShortfall() public {
        vault.addStrategy(IYieldStrategy(address(strategyA)), 6000, true);
        vault.addStrategy(IYieldStrategy(address(strategyB)), 4000, true);

        _mintAndApprove(address(this), 1000 ether);
        vault.deposit(1000 ether, address(this));

        strategyA.simulateLoss(600 ether);

        uint256 beforeUserBalance = assetToken.balanceOf(address(this));
        vault.withdraw(400 ether, address(this), address(this));

        assertEq(assetToken.balanceOf(address(this)), beforeUserBalance + 400 ether, "user receives withdrawal");
        assertEq(vault.totalAssets(), 0, "total assets updated");
    }

    function test_depositWithoutStrategies_keepsIdleBalance() public {
        _mintAndApprove(address(this), 1000 ether);
        vault.deposit(1000 ether, address(this));
        assertEq(assetToken.balanceOf(address(vault)), 1000 ether, "vault retains idle");
        assertEq(vault.totalAssets(), 1000 ether, "total assets reflects idle");
    }

    function test_depositWithStrategies_distributesProportionally() public {
        vault.addStrategy(IYieldStrategy(address(strategyA)), 6000, true);
        vault.addStrategy(IYieldStrategy(address(strategyB)), 4000, true);

        _mintAndApprove(address(this), 1000 ether);
        vault.deposit(1000 ether, address(this));

        assertEq(assetToken.balanceOf(address(strategyA)), 600 ether, "strategyA balance");
        assertEq(assetToken.balanceOf(address(strategyB)), 400 ether, "strategyB balance");
        assertEq(vault.totalAssets(), 1000 ether, "total assets after deploy");
    }

    function test_withdrawPullsLiquidityFromStrategies() public {
        vault.addStrategy(IYieldStrategy(address(strategyA)), 6000, true);
        vault.addStrategy(IYieldStrategy(address(strategyB)), 4000, true);

        _mintAndApprove(address(this), 1000 ether);
        vault.deposit(1000 ether, address(this));

        uint256 beforeBalance = assetToken.balanceOf(address(this));
        uint256 beforeTotalAssets = vault.totalAssets();
        uint256 beforeStrategyAShare = assetToken.balanceOf(address(strategyA));
        uint256 beforeStrategyBShare = assetToken.balanceOf(address(strategyB));

        vault.withdraw(250 ether, address(this), address(this));

        assertEq(assetToken.balanceOf(address(this)), beforeBalance + 250 ether, "withdrawn to user");
        assertEq(vault.totalAssets(), beforeTotalAssets - 250 ether, "total assets reduced");
        assertLe(assetToken.balanceOf(address(strategyA)), beforeStrategyAShare, "strategyA drained");
        assertLe(assetToken.balanceOf(address(strategyB)), beforeStrategyBShare, "strategyB drained");
    }

    function test_harvestWithProfit_mintsDonationShares() public {
        vault.addStrategy(IYieldStrategy(address(strategyA)), 10_000, true);

        _mintAndApprove(address(this), 1000 ether);
        vault.deposit(1000 ether, address(this));

        strategyA.simulateProfit(200 ether);

        vault.harvest();

        uint256 donationShares = vault.balanceOf(donation);
        uint256 donationAssets = vault.convertToAssets(donationShares);
        assertApproxEqAbs(donationAssets, 200 ether, 1 wei, "donation minted");
        assertEq(vault.totalAssets(), 1200 ether, "total assets includes profit");
    }

    function test_harvestWithLoss_burnsDonationShares() public {
        vault.addStrategy(IYieldStrategy(address(strategyA)), 10_000, true);

        _mintAndApprove(address(this), 1000 ether);
        vault.deposit(1000 ether, address(this));

        strategyA.simulateProfit(200 ether);
        vault.harvest();
        uint256 donationSharesBeforeLoss = vault.balanceOf(donation);
        assertGt(donationSharesBeforeLoss, 0, "donation minted");

        strategyA.simulateLoss(250 ether);

        vault.harvest();

        assertEq(vault.balanceOf(donation), 0, "donation shares burned first");
    }

    function _mintAndApprove(address _user, uint256 _amount) internal {
        assetToken.mint(_user, _amount);
        vm.prank(_user);
        assetToken.approve(address(vault), _amount);
    }
}
