// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import { YieldWeaverVault } from "src/YieldWeaverVault.sol";
import { IYieldStrategy } from "src/interfaces/IYieldStrategy.sol";
import { AaveV3YieldStrategy } from "src/strategies/AaveV3YieldStrategy.sol";
import { MockAavePool } from "test/mocks/MockAavePool.sol";

contract YieldWeaverVaultAaveIntegrationTests is Test {
    using SafeERC20 for ERC20Mock;

    ERC20Mock internal assetToken;
    MockAavePool internal mockPool;
    YieldWeaverVault internal vault;
    AaveV3YieldStrategy internal strategy;
    address internal donation;
    address internal user;

    function setUp() public {
        assetToken = new ERC20Mock();
        mockPool = new MockAavePool(assetToken);
        donation = makeAddr("donation");
        user = makeAddr("user");

        vault = new YieldWeaverVault({
            _asset: assetToken,
            _name: "Yield Weaver Share",
            _symbol: "YWS",
            _donationAddress: donation,
            _initialOwner: address(this)
        });

        strategy = new AaveV3YieldStrategy({
            _asset: assetToken, _pool: mockPool, _aToken: IERC20(mockPool.aTokenAddress()), _vault: address(vault)
        });

        vault.addStrategy(IYieldStrategy(address(strategy)), 10_000, true);
    }

    function test_depositRoutesFundsIntoAave() public {
        assetToken.mint(user, 1000 ether);
        vm.prank(user);
        assetToken.approve(address(vault), 1000 ether);

        vm.prank(user);
        vault.deposit(1000 ether, user);

        assertEq(assetToken.balanceOf(address(mockPool)), 1000 ether, "pool holds principal");
        assertEq(IERC20(mockPool.aTokenAddress()).balanceOf(address(strategy)), 1000 ether, "strategy aToken balance");
    }

    function test_harvestMintsDonationSharesAfterProfit() public {
        _deposit(user, 1000 ether);

        mockPool.accrueInterest(address(strategy), 200 ether);

        vm.prank(address(this));
        vault.harvest();

        uint256 donationShares = vault.balanceOf(donation);
        uint256 donationAssets = vault.convertToAssets(donationShares);
        assertApproxEqAbs(donationAssets, 200 ether, 1 wei, "donation minted");
        assertEq(vault.totalAssets(), 1200 ether, "total assets grew");
    }

    function test_withdrawBurnsSharesAndReturnsUnderlying() public {
        _deposit(user, 1000 ether);

        uint256 userBefore = assetToken.balanceOf(user);
        vm.prank(user);
        vault.withdraw(400 ether, user, user);

        assertEq(assetToken.balanceOf(user), userBefore + 400 ether, "user receives withdrawal");
        assertEq(assetToken.balanceOf(address(mockPool)), 600 ether, "pool reduced principal");
    }

    function test_emergencyWithdrawFromVault() public {
        _deposit(user, 1000 ether);

        address receiver = makeAddr("receiver");
        vm.prank(address(vault));
        strategy.emergencyWithdraw(receiver);

        assertEq(assetToken.balanceOf(receiver), 1000 ether, "receiver recovers principal");
        assertEq(IERC20(mockPool.aTokenAddress()).balanceOf(address(strategy)), 0, "strategy cleared");
    }

    function _deposit(address _user, uint256 _amount) internal {
        assetToken.mint(_user, _amount);
        vm.prank(_user);
        assetToken.approve(address(vault), _amount);
        vm.prank(_user);
        vault.deposit(_amount, _user);
    }
}
