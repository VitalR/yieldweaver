// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { BaseStrategy } from "@octant-v2-core/core/BaseStrategy.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import { ISparkVault } from "./ISparkVault.sol";
import { Errors } from "../common/Errors.sol";

/// @title SparkSavingsDonationStrategy
/// @notice Yield-Donating Strategy (YDS) that integrates **Spark Savings Vaults V2** (e.g. spUSDC/spUSDT/spETH),
///         which are ERC-4626 vaults governed by Spark and accruing a Vault Savings Rate (VSR) with a continuous
///         accumulator (`chi`). Strategy donates realized profit at `report()` time via the associated
///         TokenizedStrategy (donation mint / dragon burn) per Octant v2 YDS semantics.
///
/// @dev Primary target: **Spark Savings Vaults V2** (ERC-4626 + referral deposit/mint overloads).
///      Compatible with **Sky** savings wrappers (e.g., **sUSDS**, **sDAI**) on networks where they expose ERC-4626
///      and `asset()` matches the configured underlying. Core accounting is pure ERC-4626:
///      - deploy:   `deposit(assets, this [, referral])`
///      - withdraw: `withdraw(assets, this, this)`
///      - harvest:  `total = idle + convertToAssets(shares)`
///
///      References:
///      - Spark Savings Vaults V2 overview & ERC-4626 surface (VSR/chi/referral).
///        https://docs.spark.fi/dev/savings/spark-vaults-v2
///      - sUSDC/sUSDS/sDAI ERC-4626 wrappers (Sky).
///        https://github.com/sky-ecosystem/sdai/blob/susds/src/SUsds.sol
///      - Octant v2: Writing a YDS strategy (ERC-4626 direct-deposit pattern).
///        https://docs.v2.octant.build/docs/yield_donating_strategy/introduction-to-yds
contract SparkSavingsDonationStrategy is BaseStrategy {
    using SafeERC20 for ERC20;

    /// @notice @notice Spark Savings Vault being used as the yield source (e.g., spETH or spUSDC on Ethereum).
    ISparkVault public immutable sparkVault;

    /// @notice Optional Spark referral code (0 = disabled). Applied on 3-arg `deposit()`.
    uint16 public immutable referral;

    /// @param _sparkVault       Address of the Spark Savings Vault (must accept `_asset`)
    /// @param _asset            Address of the Spark ERC-20 asset (e.g., USDS, DAI, USDC)
    /// @param _name             Strategy name
    /// @param _management       Management role
    /// @param _keeper           Keeper role
    /// @param _emergencyAdmin   Emergency admin role
    /// @param _donationAddress  Donation sink (receives minted yield shares on profit)
    /// @param _enableBurning    Enable donation-share burning on loss
    /// @param _tokenized        TokenizedStrategy implementation address
    constructor(
        address _sparkVault,
        address _asset,
        string memory _name,
        address _management,
        address _keeper,
        address _emergencyAdmin,
        address _donationAddress,
        bool _enableBurning,
        address _tokenized,
        uint16 _referral
    ) BaseStrategy(_asset, _name, _management, _keeper, _emergencyAdmin, _donationAddress, _enableBurning, _tokenized) {
        require(
            _asset != address(0) && _sparkVault != address(0) && _management != address(0) && _keeper != address(0)
                && _emergencyAdmin != address(0) && _donationAddress != address(0),
            Errors.ZeroAddress()
        );
        require(ISparkVault(_sparkVault).asset() == _asset, Errors.InvalidAsset());

        sparkVault = ISparkVault(_sparkVault);
        referral = _referral;

        // Max allow Spark Savings Vault to withdraw assets.
        ERC20(_asset).forceApprove(address(sparkVault), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                         REQUIRED YDS OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /// @dev After deposit/mint: move idle asset into the Spark Savings Vault.
    function _deployFunds(uint256 _amount, uint16 _referral) internal override {
        if (_amount == 0) return;
        if (_referral != 0) sparkVault.deposit(_amount, address(this), _referral);
        else sparkVault.deposit(_amount, address(this));
    }

    /// @dev During withdraw/redeem: pull asset back out of the Spark Savings Vault.
    function _freeFunds(uint256 _amount) internal override {
        if (_amount == 0) return;
        // If upstream has limits, withdraw what is possible or revert (depending on your policy).
        // Here we request the exact amount; Spark Savings Vault should revert if impossible.
        sparkVault.withdraw(_amount, address(this), address(this));
    }

    /// @dev Keeper/management path: return total assets (idle + wrapper assets) in underlying units.
    /// @notice Base compares this vs last report and mints/burns donation shares accordingly.
    function _harvestAndReport() internal override returns (uint256 _totalAssets) {
        // Get strategy's share balance in the compounder vault
        uint256 shares = sparkVault.balanceOf(address(this));
        uint256 vaultAssets = sparkVault.convertToAssets(shares);

        // Include idle funds as per BaseStrategy specification
        uint256 idleAssets = asset.balanceOf(address(this));

        _totalAssets = vaultAssets + idleAssets;
    }

    /*//////////////////////////////////////////////////////////////
                       SAFETY CHECKS AND LIMITS
    //////////////////////////////////////////////////////////////*/

    /// @dev Mirror Spark Savings Vault limits into strategy-level limits.
    function availableDepositLimit(address) public view override returns (uint256) {
        // If the upstream vault implements maxDeposit, honour it; otherwise return type(uint256).max
        // Most savings wrappers set no fee and wide limits, but we propagate if present.
        try sparkVault.maxDeposit(address(this)) returns (uint256 lim) {
            return lim;
        } catch {
            return type(uint256).max;
        }
    }

    /// @dev Mirror Spark Savings Vault limits into strategy-level limits.
    function availableWithdrawLimit(address) public view override returns (uint256) {
        // Honour upstream maxWithdraw for this address if present
        try sparkVault.maxWithdraw(address(this)) returns (uint256 lim) {
            return lim;
        } catch {
            // Otherwise, advertise our on-hand idle + what our shares are worth
            uint256 idle = asset.balanceOf(address(this));
            uint256 shares = sparkVault.balanceOf(address(this));
            return idle + sparkVault.convertToAssets(shares);
        }
    }
}
