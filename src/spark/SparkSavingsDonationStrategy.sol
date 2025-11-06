// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { BaseStrategy } from "@octant-v2-core/core/BaseStrategy.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

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
///      - Octant v2: Writing a YDS strategy (ERC-4626 direct-deposit pattern).
///        https://docs.v2.octant.build/docs/yield_donating_strategy/introduction-to-yds
contract SparkSavingsDonationStrategy is BaseStrategy {
    using SafeERC20 for ERC20;

    /*//////////////////////////////////////////////////////////////
                        STORAGE & CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Spark Savings Vault being used as the yield source (e.g., spETH or spUSDC on Ethereum).
    ISparkVault public immutable sparkVault;

    /// @notice Minimum idle required before deploying to the vault (asset base units).
    /// @dev Keeps a small “warm buffer” and avoids burning gas on dust.
    ///      Manager can tune per-asset as needed.
    uint256 public deployThreshold;

    /// @notice Idle threshold (in asset units) above which keepers should `tend()` and deploy idle.
    uint256 public tendIdleThreshold = 1000;

    /// @notice Optional Spark referral code (0 = disabled). Applied on 3-arg `deposit()`.
    uint16 public referral;

    /// @notice Emitted when the deploy threshold is updated.
    event DeployThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);

    /// @notice Emitted when the referral code is updated.
    event ReferralUpdated(uint16 referral);

    /// @notice Emitted when the idle deployment threshold is updated.
    event TendThresholdUpdated(uint256 threshold);

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Constructs the Spark Savings Yield Donating Strategy.
    /// @param _sparkVault       Address of the Spark Savings Vault (must accept `_asset`).
    /// @param _asset            Address of the Spark ERC-20 asset (e.g., USDS, DAI, USDC).
    /// @param _name             Strategy name.
    /// @param _management       Management role.
    /// @param _keeper           Keeper role.
    /// @param _emergencyAdmin   Emergency admin role.
    /// @param _donationAddress  Donation sink (receives minted yield shares on profit).
    /// @param _enableBurning    Enable donation-share burning on loss.
    /// @param _tokenized        TokenizedStrategy implementation address (must implement `ITokenizedStrategy`).
    /// @param _referral         Spark referral code (0 = disabled).
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

        _initDeployThreshold();

        // Max allow Spark Savings Vault to withdraw assets.
        ERC20(_asset).forceApprove(address(sparkVault), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                    OVERRIDES FROM YDS BASE STRATEGY
    //////////////////////////////////////////////////////////////*/

    /// @dev After deposit/mint: move idle asset into the Spark Savings Vault. Uses stored `referral` if non-zero.
    /// @param _amount Amount of assets to deploy.
    function _deployFunds(uint256 _amount) internal override {
        // Only deploy if our idle buffer is meaningful (above deployThreshold).
        if (idle() < deployThreshold) return;
        if (referral != 0) sparkVault.deposit(_amount, address(this), referral); // Spark V2 overload.
        else sparkVault.deposit(_amount, address(this)); // ERC-4626 standard deposit.
    }

    /// @dev During withdraw/redeem: pull asset back out of the Spark Savings Vault.
    /// @param _amount Amount of assets to withdraw.
    function _freeFunds(uint256 _amount) internal override {
        if (_amount == 0) return;
        // If upstream has limits, withdraw what is possible or revert (depending on your policy).
        // Here we request the exact amount; Spark Savings Vault should revert if impossible.
        sparkVault.withdraw(_amount, address(this), address(this));
    }

    /// @dev Keeper/management path: return total assets (idle + wrapper assets) in underlying units.
    /// @notice Base compares this vs last report and mints/burns donation shares accordingly.
    function _harvestAndReport() internal view override returns (uint256 _totalAssets) {
        // Get strategy's share balance in the compounder vault.
        uint256 shares = sparkVault.balanceOf(address(this));
        uint256 vaultAssets = sparkVault.convertToAssets(shares);

        _totalAssets = vaultAssets + idle();
    }

    /// @notice Best-effort pull of funds after shutdown (called via Tokenized.emergencyWithdraw()).
    /// @dev     Does not realize PnL; management can follow with a `report()` to account final totals.
    /// @param _amount Amount of assets to withdraw.
    function _emergencyWithdraw(uint256 _amount) internal override {
        uint256 _idle = asset.balanceOf(address(this));
        if (_idle < _amount) {
            uint256 toPull = _amount - _idle;
            // If vault can’t satisfy, swallow and return what we have; ops can try smaller chunks.
            try sparkVault.withdraw(toPull, address(this), address(this)) { } catch { }
        }
    }

    /// @notice Returns true when keepers should call `tend()` (idle above threshold and not shutdown).
    function tendTrigger() public view override returns (bool, bytes memory) {
        if (TokenizedStrategy.isShutdown()) return (false, bytes(""));
        bool should = idle() >= tendIdleThreshold;
        return (should, bytes(""));
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
        // Honour upstream maxWithdraw for this address if present.
        try sparkVault.maxWithdraw(address(this)) returns (uint256 lim) {
            return lim;
        } catch {
            // Otherwise, advertise our on-hand idle + what our shares are worth.
            uint256 shares = sparkVault.balanceOf(address(this));
            return idle() + sparkVault.convertToAssets(shares);
        }
    }

    /*//////////////////////////////////////////////////////////////
                OPS / TEND CONFIG (KEEPERS / MANAGEMENT)
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns true when keepers should call `tend()` (idle above threshold and not shutdown).
    function _tendTrigger() internal view override returns (bool) {
        if (TokenizedStrategy.isShutdown()) return false;
        return idle() >= tendIdleThreshold;
    }

    /// @notice Keeper maintenance hook to deploy idle funds in batch between reports.
    /// @param _totalIdle Current idle funds available to be deployed (passed from Tokenized).
    function _tend(uint256 _totalIdle) internal override {
        if (_totalIdle >= tendIdleThreshold && !TokenizedStrategy.isShutdown()) {
            _deployFunds(_totalIdle);
        }
    }

    /// @notice Sets the idle deployment threshold used by keepers in `tend()`.
    /// @param _threshold Amount (in asset base units) above which `tend()` will deploy idle funds.
    function setTendThreshold(uint256 _threshold) external onlyManagement {
        tendIdleThreshold = _threshold;
        emit TendThresholdUpdated(_threshold);
    }

    /// @notice Updates the referral code for staking.
    /// @param _referral Referral code (uint16)
    function setReferral(uint16 _referral) external onlyManagement {
        referral = _referral;
        emit ReferralUpdated(_referral);
    }

    /// @notice Manager-setter with no upper bound (0 allowed to disable).
    /// @param _newThreshold New deploy threshold (asset base units).
    function setDeployThreshold(uint256 _newThreshold) external onlyManagement {
        emit DeployThresholdUpdated(deployThreshold, _newThreshold);
        deployThreshold = _newThreshold;
    }

    /// @dev Call this once in your initializer/constructor path.
    function _initDeployThreshold() internal {
        // Default to ~0.0001 token units regardless of decimals.
        // For 6-dec (USDC): 10**(6-4)=100 (0.0001 USDC)
        // For 18-dec:       10**(18-4)=1e14 (0.0001 tokens)
        uint8 dec = ERC20(asset).decimals();
        uint256 def = (dec >= 4) ? 10 ** (dec - 4) : 1; // Safe fallback for very low-dec assets.
        deployThreshold = def;
    }

    /*//////////////////////////////////////////////////////////////
                      OPS / OBSERVABILITY HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns current Vault Savings Rate (VSR) if exposed by the vault; 0 if not supported.
    /// @dev    Useful for dashboards/keepers to understand expected accrual velocity without simulating.
    function sparkVsr() external view returns (uint256) {
        try sparkVault.vsr() returns (uint256 v) {
            return v;
        } catch {
            return 0;
        }
    }

    /// @notice Returns current accumulator (chi) if exposed by the vault.
    /// @dev    Some vaults expose `nowChi()` (up-to-block), others expose `chi()`; we try both.
    ///         Observing chi growth over time is a sanity-check that interest accrues as expected.
    function sparkChi() external view returns (uint256) {
        try sparkVault.nowChi() returns (uint256 n) {
            return n;
        } catch {
            try sparkVault.chi() returns (uint192 c) {
                return uint256(c);
            } catch {
                return 0;
            }
        }
    }

    /// @notice Current idle balance in underlying asset.
    function idle() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /// @notice Current deployed balance as underlying (convertToAssets(shares)).
    function deployed() public view returns (uint256) {
        uint256 sh = sparkVault.balanceOf(address(this));
        return sparkVault.convertToAssets(sh);
    }

    /// @notice Convenience total = idle + deployed (same formula used in harvest).
    function totalView() external view returns (uint256) {
        return idle() + deployed();
    }
}
