// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IYieldStrategy } from "src/interfaces/IYieldStrategy.sol";

/// @dev Lightweight mock strategy used for vault unit tests. Implements the `IYieldStrategy` interface while
///      stubbing the additional Octant-specific hooks with minimal logic so the vault can exercise its flows.
contract MockYieldStrategy is ERC20, ERC20Permit, ERC4626, IYieldStrategy {
    using SafeERC20 for ERC20;

    uint256 public lastManagedAssets;
    bool private _burningEnabled;
    bool private _shutdown;
    address private _management;
    address private _pendingManagement;
    address private _keeper;
    address private _emergencyAdmin;
    address private _dragonRouter;
    address private _pendingDragonRouter;
    uint256 private _dragonRouterChangeTimestamp;
    uint256 private _lastReport;

    constructor(ERC20Mock _asset)
        ERC20("Mock Strategy Share", "MSTR")
        ERC20Permit("Mock Strategy Share")
        ERC4626(_asset)
    {
        _management = msg.sender;
        _keeper = msg.sender;
        _emergencyAdmin = msg.sender;
        _dragonRouter = msg.sender;
        lastManagedAssets = totalAssets();
        _lastReport = block.timestamp;
    }

    function decimals() public view override(ERC20, ERC4626, IERC20Metadata) returns (uint8) {
        return ERC4626.decimals();
    }

    function nonces(address owner) public view override(ERC20Permit, IERC20Permit) returns (uint256) {
        return super.nonces(owner);
    }

    /*//////////////////////////////////////////////////////////////
                          IYieldStrategy Hooks
    //////////////////////////////////////////////////////////////*/

    function deploy(uint256) external override {
        lastManagedAssets = totalAssets();
        _lastReport = block.timestamp;
    }

    function withdraw(uint256 _amount, address _receiver) external override returns (uint256 withdrawnAmount) {
        ERC20 underlying = ERC20(asset());
        uint256 balance = underlying.balanceOf(address(this));
        withdrawnAmount = _amount > balance ? balance : _amount;
        if (withdrawnAmount > 0) {
            underlying.safeTransfer(_receiver, withdrawnAmount);
        }
        lastManagedAssets = totalAssets();
        _lastReport = block.timestamp;
    }

    function harvest() external override returns (uint256 harvestedAmount) {
        uint256 currentAssets = totalAssets();
        if (currentAssets >= lastManagedAssets) {
            harvestedAmount = currentAssets - lastManagedAssets;
        }
        lastManagedAssets = currentAssets;
        _lastReport = block.timestamp;
    }

    function emergencyWithdraw(address _receiver) external override returns (uint256 withdrawnAmount) {
        ERC20 underlying = ERC20(asset());
        withdrawnAmount = underlying.balanceOf(address(this));
        if (withdrawnAmount > 0) {
            underlying.safeTransfer(_receiver, withdrawnAmount);
        }
        lastManagedAssets = totalAssets();
        _lastReport = block.timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                   Test helpers to simulate profit / loss
    //////////////////////////////////////////////////////////////*/

    function simulateProfit(uint256 _amount) external {
        ERC20Mock(address(asset())).mint(address(this), _amount);
    }

    function simulateLoss(uint256 _amount) external {
        ERC20Mock token = ERC20Mock(address(asset()));
        uint256 balance = token.balanceOf(address(this));
        if (_amount > balance) {
            _amount = balance;
        }
        token.burn(address(this), _amount);
    }

    /*//////////////////////////////////////////////////////////////
                    ITokenizedStrategy compatibility layer
    //////////////////////////////////////////////////////////////*/

    function initialize(
        address _asset,
        string memory _name,
        address _management_,
        address _keeper_,
        address _emergencyAdmin_,
        address _dragonRouter_,
        bool _enableBurning
    ) external override {
        require(_asset == asset(), "asset mismatch");
        require(bytes(_name).length > 0, "name is required");
        _management = _management_;
        _keeper = _keeper_;
        _emergencyAdmin = _emergencyAdmin_;
        _dragonRouter = _dragonRouter_;
        _burningEnabled = _enableBurning;
        lastManagedAssets = totalAssets();
        _lastReport = block.timestamp;
    }

    function withdraw(uint256 assets, address receiver, address owner, uint256) external override returns (uint256) {
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner, uint256) external override returns (uint256) {
        return super.redeem(shares, receiver, owner);
    }

    function maxWithdraw(address owner, uint256) external view override returns (uint256) {
        return super.maxWithdraw(owner);
    }

    function maxRedeem(address owner, uint256) external view override returns (uint256) {
        return super.maxRedeem(owner);
    }

    function requireManagement(address _sender) external view override {
        require(_sender == _management, "not management");
    }

    function requireKeeperOrManagement(address _sender) external view override {
        require(_sender == _keeper || _sender == _management, "not keeper/management");
    }

    function requireEmergencyAuthorized(address _sender) external view override {
        require(_sender == _emergencyAdmin || _sender == _management, "not emergency");
    }

    function tend() external pure override { }

    function report() external override returns (uint256 profit, uint256 loss) {
        uint256 currentAssets = totalAssets();
        if (currentAssets >= lastManagedAssets) {
            profit = currentAssets - lastManagedAssets;
        } else {
            loss = lastManagedAssets - currentAssets;
        }
        lastManagedAssets = currentAssets;
        _lastReport = block.timestamp;
    }

    function apiVersion() external pure override returns (string memory) {
        return "0.0.1";
    }

    function pricePerShare() external view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? 1e18 : convertToAssets(1e18);
    }

    function management() external view override returns (address) {
        return _management;
    }

    function pendingManagement() external view override returns (address) {
        return _pendingManagement;
    }

    function keeper() external view override returns (address) {
        return _keeper;
    }

    function emergencyAdmin() external view override returns (address) {
        return _emergencyAdmin;
    }

    function dragonRouter() external view override returns (address) {
        return _dragonRouter;
    }

    function pendingDragonRouter() external view override returns (address) {
        return _pendingDragonRouter;
    }

    function dragonRouterChangeTimestamp() external view override returns (uint256) {
        return _dragonRouterChangeTimestamp;
    }

    function lastReport() external view override returns (uint256) {
        return _lastReport;
    }

    function isShutdown() external view override returns (bool) {
        return _shutdown;
    }

    function setPendingManagement(address _management_) external override {
        _pendingManagement = _management_;
    }

    function acceptManagement() external override {
        require(_pendingManagement != address(0), "no pending");
        _management = _pendingManagement;
        _pendingManagement = address(0);
    }

    function setKeeper(address _keeper_) external override {
        _keeper = _keeper_;
    }

    function setEmergencyAdmin(address _emergencyAdmin_) external override {
        _emergencyAdmin = _emergencyAdmin_;
    }

    function setDragonRouter(address _dragonRouter_) external override {
        _pendingDragonRouter = _dragonRouter_;
        _dragonRouterChangeTimestamp = block.timestamp;
    }

    function finalizeDragonRouterChange() external override {
        _dragonRouter = _pendingDragonRouter;
        _pendingDragonRouter = address(0);
        _dragonRouterChangeTimestamp = 0;
    }

    function cancelDragonRouterChange() external override {
        _pendingDragonRouter = address(0);
        _dragonRouterChangeTimestamp = 0;
    }

    function setName(string calldata) external override { }

    function shutdownStrategy() external override {
        _shutdown = true;
    }

    function emergencyWithdraw(uint256 _amount) external override {
        ERC20 underlying = ERC20(asset());
        uint256 balance = underlying.balanceOf(address(this));
        if (_amount > balance) {
            _amount = balance;
        }
        if (_amount > 0) {
            underlying.safeTransfer(msg.sender, _amount);
        }
        lastManagedAssets = totalAssets();
        _lastReport = block.timestamp;
    }
}
