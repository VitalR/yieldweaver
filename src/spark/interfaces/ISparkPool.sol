// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title ISparkPool
/// @notice Minimal subset of the SparkLend (Aave V3) Pool required by donation strategies.
/// @dev Exposes only the `supply` and `withdraw` entry points used when supplying/withdrawing liquidity.
interface ISparkPool {
    /// @notice Supplies assets to the Aave pool on behalf of a user.
    /// @param asset The ERC-20 token address being supplied.
    /// @param amount The amount of `asset` to supply.
    /// @param onBehalfOf Address that will receive the corresponding aTokens.
    /// @param referralCode Optional referral code (0 for none).
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    /// @notice Withdraws assets from the pool, redeeming aTokens.
    /// @param asset The ERC-20 token address to withdraw.
    /// @param amount The amount of `asset` to withdraw (type(uint256).max to withdraw entire balance).
    /// @param to The recipient address receiving the underlying assets.
    /// @return withdrawnAmount The actual amount withdrawn.
    function withdraw(address asset, uint256 amount, address to) external returns (uint256 withdrawnAmount);
}
