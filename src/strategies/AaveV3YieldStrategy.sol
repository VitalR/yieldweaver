// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IYieldStrategy } from "src/interfaces/IYieldStrategy.sol";
import { IPool } from "src/external/aave/IPool.sol";
import { Errors } from "src/common/Errors.sol";

/// @title AaveV3YieldStrategy
/// @notice ERC-4626 strategy adapter that supplies vault assets into an Aave V3 lending pool.
/// @dev The adapter implements Octant's `IYieldStrategy` interface so it can be orchestrated by
///      `YieldWeaverVault` while remaining compatible with Octant's TokenizedStrategy expectations.
contract AaveV3YieldStrategy is ERC20, ERC20Permit, ERC4626, IYieldStrategy {
    using SafeERC20 for IERC20;

    /// @notice Aave V3 pool used to supply/withdraw liquidity.
    IPool public immutable pool;

    /// @notice aToken representing supplied liquidity within the pool.
    IERC20 public immutable aToken;

    /// @notice Vault permitted to call privileged strategy hooks (deploy/withdraw/harvest).
    address public immutable vault;

    /// @dev Cached reference to the underlying asset (saves repeated casting of `asset()`).
    IERC20 private immutable _underlying;

    /// @notice Last observed total managed assets, used for profit/loss deltas.
    uint256 public lastManagedAssets;

    /// @notice Tracks whether loss-buffer burning is enabled (Octant compatibility flag).
    bool private _burningEnabled;

    /// @notice Indicates whether the strategy has been shut down.
    bool private _shutdown;

    /// @notice Address with management permissions (Octant compatibility).
    address private _management;

    /// @notice Pending management address awaiting acceptance.
    address private _pendingManagement;

    /// @notice Address allowed to call keeper operations.
    address private _keeper;

    /// @notice Address allowed to trigger emergency procedures.
    address private _emergencyAdmin;

    /// @notice Octant dragon router address used for donation flows.
    address private _dragonRouter;

    /// @notice Pending dragon router that will replace the current one after cooldown.
    address private _pendingDragonRouter;

    /// @notice Timestamp when the dragon router change was initiated.
    uint256 private _dragonRouterChangeTimestamp;

    /// @notice Timestamp of the last harvest report.
    uint256 private _lastReport;

    modifier onlyVault() {
        require(msg.sender == vault, Errors.NotVault());
        _;
    }

    constructor(IERC20 _asset, IPool _pool, IERC20 _aToken, address _vault)
        ERC20("Aave V3 Strategy Share", "AV3S")
        ERC20Permit("Aave V3 Strategy Share")
        ERC4626(_asset)
    {
        require(address(_asset) != address(0), Errors.InvalidAsset());
        require(address(_pool) != address(0), Errors.InvalidPool());
        require(address(_aToken) != address(0), Errors.InvalidAToken());
        require(_vault != address(0), Errors.InvalidVault());

        pool = _pool;
        aToken = _aToken;
        vault = _vault;
        _underlying = _asset;
        _management = msg.sender;
        _keeper = msg.sender;
        _emergencyAdmin = msg.sender;
        _dragonRouter = msg.sender;
        lastManagedAssets = totalAssets();
        _lastReport = block.timestamp;
    }

    // =============================================================
    //                       VIEW OVERRIDES
    // =============================================================

    function decimals() public view override(ERC20, ERC4626, IERC20Metadata) returns (uint8) {
        return ERC4626.decimals();
    }

    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256) {
        uint256 idle = _underlying.balanceOf(address(this));
        uint256 invested = aToken.balanceOf(address(this));
        return idle + invested;
    }

    function nonces(address owner) public view override(ERC20Permit, IERC20Permit) returns (uint256) {
        return super.nonces(owner);
    }

    // =============================================================
    //                  IYieldStrategy Hooks
    // =============================================================

    function deploy(uint256) external override onlyVault {
        if (_shutdown) return;

        uint256 idleBalance = _underlying.balanceOf(address(this));
        if (idleBalance == 0) return;

        SafeERC20.forceApprove(_underlying, address(pool), idleBalance);
        pool.supply(address(_underlying), idleBalance, address(this), 0);

        lastManagedAssets = totalAssets();
        _lastReport = block.timestamp;
    }

    function withdraw(uint256 _amount, address _receiver)
        external
        override
        onlyVault
        returns (uint256 withdrawnAmount)
    {
        uint256 idleBalance = _underlying.balanceOf(address(this));
        if (idleBalance < _amount) {
            uint256 shortfall = _amount - idleBalance;
            uint256 withdrawnFromPool = pool.withdraw(address(_underlying), shortfall, address(this));
            idleBalance += withdrawnFromPool;
        }

        withdrawnAmount = _amount > idleBalance ? idleBalance : _amount;
        if (withdrawnAmount > 0) {
            _underlying.safeTransfer(_receiver, withdrawnAmount);
        }

        lastManagedAssets = totalAssets();
        _lastReport = block.timestamp;
    }

    function harvest() external override onlyVault returns (uint256 harvestedAmount) {
        uint256 currentAssets = totalAssets();
        if (currentAssets >= lastManagedAssets) {
            harvestedAmount = currentAssets - lastManagedAssets;
        }
        lastManagedAssets = currentAssets;
        _lastReport = block.timestamp;
    }

    function emergencyWithdraw(address _receiver) external override onlyVault returns (uint256 withdrawnAmount) {
        uint256 invested = aToken.balanceOf(address(this));
        if (invested > 0) {
            withdrawnAmount = pool.withdraw(address(_underlying), invested, _receiver);
        }
        uint256 idle = _underlying.balanceOf(address(this));
        if (idle > 0) {
            _underlying.safeTransfer(_receiver, idle);
            withdrawnAmount += idle;
        }
        lastManagedAssets = totalAssets();
        _lastReport = block.timestamp;
    }

    // =============================================================
    //            ITokenizedStrategy Compatibility Layer
    // =============================================================

    function initialize(
        address _asset,
        string memory,
        address _management_,
        address _keeper_,
        address _emergencyAdmin_,
        address _dragonRouter_,
        bool _enableBurning
    ) external override {
        if (_asset != address(_underlying)) revert Errors.InvalidAsset();
        _management = _management_;
        _keeper = _keeper_;
        _emergencyAdmin = _emergencyAdmin_;
        _dragonRouter = _dragonRouter_;
        _burningEnabled = _enableBurning;
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
        if (_sender != _management) revert Errors.NotManagement();
    }

    function requireKeeperOrManagement(address _sender) external view override {
        if (_sender != _keeper && _sender != _management) revert Errors.NotKeeperOrManagement();
    }

    function requireEmergencyAuthorized(address _sender) external view override {
        if (_sender != _emergencyAdmin && _sender != _management) revert Errors.NotEmergencyAuthorized();
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
        if (_pendingManagement == address(0)) revert Errors.NoPendingManagement();
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
        pool.withdraw(address(_underlying), _amount, msg.sender);
        lastManagedAssets = totalAssets();
        _lastReport = block.timestamp;
    }
}
