// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ITokenizedStrategy } from "@octant-v2-core/core/interfaces/ITokenizedStrategy.sol";

/**
 * @title IYieldStrategy
 * @notice Octant-compatible interface for YieldWeaver strategy adapters.
 * @dev Extends `ITokenizedStrategy` so existing Octant strategies can be wrapped without modifications.
 */
interface IYieldStrategy is ITokenizedStrategy {
    /// @notice Emitted when the strategy realises new yield that remains managed by the strategy.
    event Harvest(uint256 harvestedAssets);

    /**
     * @notice Deploy freshly deposited assets into the underlying yield source.
     * @dev The strategy assumes the caller (vault) has transferred `_amount` assets beforehand.
     * @param _amount Amount of assets to deploy.
     */
    function deploy(uint256 _amount) external;

    /**
     * @notice Withdraw assets from the strategy back to the vault.
     * @param _amount Amount of assets requested by the vault.
     * @param _receiver Address that should receive the withdrawn assets.
     * @return withdrawn Actual amount of assets withdrawn (may be lower on loss, higher on slippage gains).
     */
    function withdraw(uint256 _amount, address _receiver) external returns (uint256 withdrawn);

    /**
     * @notice Perform any maintenance work and report newly realised yield to the vault.
     * @dev Implementations should realise any accumulated rewards and either transfer them to the vault
     *      or keep them accounted inside `totalAssets()`.
     * @return harvestedAmount Amount of newly realised underlying assets.
     */
    function harvest() external returns (uint256 harvestedAmount);

    /**
     * @notice Emergency hook that forces the strategy to unwind all positions and return funds to the vault.
     * @param _receiver Address that should receive any emergency withdrawn assets.
     * @return withdrawnAmount Total amount of assets recovered.
     */
    function emergencyWithdraw(address _receiver) external returns (uint256 withdrawnAmount);
}
