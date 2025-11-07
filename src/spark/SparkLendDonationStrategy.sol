// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { BaseStrategy } from "@octant-v2-core/core/BaseStrategy.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IPool } from "src/external/aave/IPool.sol";
import { Errors } from "../common/Errors.sol";

/// @title SparkLendDonationStrategy
/// @notice Yield-Donating Strategy (YDS) that integrates **SparkLend** (Aave v3-style pool) by supplying the underlying
///         reserve. The strategy keeps idle buffers on the contract, deploys excess liquidity to the SparkLend pool,
///         and realizes profit during `report()` so the paired TokenizedStrategy mints donation shares (or burns on
/// loss) per Octant v2 semantics.
///
/// @dev Primary integration surface:
///      - Deploy:   `IPool.supply(asset, amount, onBehalfOf, referral)`
///      - Withdraw: `IPool.withdraw(asset, amount, to)`
///      - Harvest:  `ATOKEN.balanceOf(strategy) + idle()`
///
///      References:
///      - SparkLend pool documentation: https://docs.spark.fi/dev/lend/overview
///      - Octant v2 YDS pattern:        https://docs.v2.octant.build/docs/yield_donating_strategy/introduction-to-yds
contract SparkLendDonationStrategy is BaseStrategy {
    using SafeERC20 for ERC20;

    /*//////////////////////////////////////////////////////////////
                        STORAGE & CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice SparkLend pool that provides supply / withdraw entry points (Aave v3 compatible).
    IPool public immutable POOL;

    /// @notice Interest-bearing aToken returned by supplying `asset()` into the SparkLend pool.
    ERC20 public immutable ATOKEN;

    /// @notice Minimum idle balance (asset units) required before deploying to the pool.
    /// @dev Acts as a warm buffer and prevents dust deployments that would spend more gas than value.
    uint256 public deployThreshold;

    /// @notice Idle balance threshold (asset units) that should trigger keeper-maintained `tend()` runs.
    uint256 public tendIdleThreshold = 1000;

    /// @notice Optional Spark referral code applied to `IPool.supply` (0 disables referrals).
    uint16 public referral;

    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when the deploy threshold is updated.
    event DeployThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);

    /// @notice Emitted when the tend threshold is updated.
    event TendThresholdUpdated(uint256 threshold);

    /// @notice Emitted when the Spark referral code is updated.
    event ReferralUpdated(uint16 referral);

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Constructs the SparkLend Yield Donating Strategy.
    /// @param _pool             Address of the SparkLend pool (Aave v3-compatible `IPool`).
    /// @param _aToken           Address of the interest-bearing aToken for the configured reserve.
    /// @param _asset            ERC-20 asset supplied as underlying (reserve token backing the aToken).
    /// @param _name             Strategy name forwarded to BaseStrategy (for UIs / logging).
    /// @param _management       Management role allowed to adjust thresholds / referral.
    /// @param _keeper           Keeper role that can invoke keeper endpoints (e.g., `tend()`).
    /// @param _emergencyAdmin   Address with emergency powers (shutdown / emergency withdraw).
    /// @param _donationAddress  Donation sink (receives minted shares on profit).
    /// @param _enableBurning    Whether to burn donation shares when reporting a loss.
    /// @param _tokenized        TokenizedStrategy implementation paired with this strategy.
    /// @param _referral         SparkLend referral code to use when supplying (0 means disabled).
    constructor(
        address _pool,
        address _aToken,
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
            _asset != address(0) && _pool != address(0) && _aToken != address(0) && _management != address(0)
                && _keeper != address(0) && _emergencyAdmin != address(0) && _donationAddress != address(0),
            Errors.ZeroAddress()
        );

        // Underlying sanity: ensure the aToken is for our asset if exposed
        // Best-effort consistency: if aToken exposes decimals, we assume it's the correct reserve token.

        POOL = IPool(_pool);
        ATOKEN = ERC20(_aToken);
        referral = _referral;

        _initDeployThreshold();

        // Approve Pool to pull underlying for supply
        ERC20(_asset).forceApprove(address(POOL), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                    OVERRIDES FROM YDS BASE STRATEGY
    //////////////////////////////////////////////////////////////*/

    /// @dev Deploys idle assets into SparkLend when above the configured `deployThreshold`.
    /// @param _amount Amount of assets (in underlying units) forwarded by BaseStrategy for deployment.
    function _deployFunds(uint256 _amount) internal override {
        if (idle() < deployThreshold) return;
        POOL.supply(address(asset), _amount, address(this), referral);
    }

    /// @dev Frees funds from SparkLend during withdrawals/redemptions.
    /// @param _amount Amount of assets requested by BaseStrategy to satisfy a withdraw.
    function _freeFunds(uint256 _amount) internal override {
        if (_amount == 0) return;
        // Pool returns actual withdrawn; ignore discrepancy and rely on upstream revert policy if needed
        POOL.withdraw(address(asset), _amount, address(this));
    }

    /// @dev Produces the total asset valuation for `report()` by summing deployed (aToken) and idle balances.
    /// @return _totalAssets Total asset value in underlying units.
    function _harvestAndReport() internal view override returns (uint256 _totalAssets) {
        uint256 deployedAssets = ATOKEN.balanceOf(address(this));
        _totalAssets = deployedAssets + idle();
    }

    /// @dev Attempts to satisfy an emergency withdraw by first consuming idle funds, then pulling from SparkLend.
    /// @param _amount Assets requested by BaseStrategy to honour the emergency withdraw.
    function _emergencyWithdraw(uint256 _amount) internal override {
        uint256 _idle = asset.balanceOf(address(this));
        if (_idle < _amount) {
            uint256 toPull = _amount - _idle;
            try POOL.withdraw(address(asset), toPull, address(this)) returns (uint256) { } catch { }
        }
    }

    /*//////////////////////////////////////////////////////////////
                       SAFETY CHECKS AND LIMITS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the deposit limit advertised by the strategy.
    /// @dev SparkLend exposes supply caps via risk steering. To keep the surface simple, we expose `type(uint256).max`
    ///      and rely on upstream cap management. Spark may still revert if caps are hit.
    /// @return Maximum assets that can be deposited (strategy-level view).
    function availableDepositLimit(address) public view override returns (uint256) {
        // Pool-level supply caps vary per reserve; to keep the surface simple return max
        return type(uint256).max;
    }

    /// @notice Returns the withdraw limit advertised by the strategy.
    /// @dev `ATOKEN.balanceOf` already reflects accrued interest, so deployed + idle mirrors what can be pulled.
    /// @return Maximum assets that can be withdrawn at the strategy level.
    function availableWithdrawLimit(address) public view override returns (uint256) {
        // Idle + aToken value (aToken.balanceOf already reflects interest accrual)
        return idle() + ATOKEN.balanceOf(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                OPS / TEND CONFIG (KEEPERS / MANAGEMENT)
    //////////////////////////////////////////////////////////////*/

    /// @dev Keeper trigger hook invoked by BaseStrategy to check whether a tend run is warranted.
    /// @return True when the strategy is not shutdown and idle assets exceed `tendIdleThreshold`.
    function _tendTrigger() internal view override returns (bool) {
        if (TokenizedStrategy.isShutdown()) return false;
        return idle() >= tendIdleThreshold;
    }

    /// @dev Keeper maintenance hook that deploys all idle funds once the trigger condition is satisfied.
    /// @param _totalIdle Idle assets (in underlying units) currently held by the strategy.
    function _tend(uint256 _totalIdle) internal override {
        if (_totalIdle >= tendIdleThreshold && !TokenizedStrategy.isShutdown()) {
            _deployFunds(_totalIdle);
        }
    }

    /// @notice Updates the idle threshold that dictates when keepers should call `tend()`.
    /// @param _threshold New tend threshold (asset units).
    function setTendThreshold(uint256 _threshold) external onlyManagement {
        tendIdleThreshold = _threshold;
        emit TendThresholdUpdated(_threshold);
    }

    /// @notice Updates the minimum idle buffer required before deploying to SparkLend.
    /// @param _newThreshold New deploy threshold (asset units).
    function setDeployThreshold(uint256 _newThreshold) external onlyManagement {
        emit DeployThresholdUpdated(deployThreshold, _newThreshold);
        deployThreshold = _newThreshold;
    }

    /// @notice Updates the Spark referral code applied on `IPool.supply`.
    /// @param _referral Referral code (0 disables).
    function setReferral(uint16 _referral) external onlyManagement {
        referral = _referral;
        emit ReferralUpdated(_referral);
    }

    /// @dev Initializes the deploy threshold to a sensible default based on the asset decimals.
    function _initDeployThreshold() internal {
        uint8 dec = ERC20(asset).decimals();
        uint256 def = (dec >= 4) ? 10 ** (dec - 4) : 1;
        deployThreshold = def;
    }

    /*//////////////////////////////////////////////////////////////
                      OPS / OBSERVABILITY HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the idle asset balance held by the strategy (in underlying units).
    function idle() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /// @notice Returns the total assets currently deployed inside SparkLend (aToken balance).
    function deployed() public view returns (uint256) {
        return ATOKEN.balanceOf(address(this));
    }

    /// @notice Convenience view returning `idle() + deployed()` for dashboards and ops tooling.
    /// @return Total assets across both idle and deployed balances.
    function totalView() external view returns (uint256) {
        return idle() + deployed();
    }
}
