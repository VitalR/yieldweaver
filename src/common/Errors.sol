// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title YieldWeaverErrors
/// @notice Common custom errors shared across YieldWeaver contracts.
library Errors {
    /// @dev Thrown when a strategy is already deployed.
    error AlreadyDeployed();

    /// @dev Thrown when allocations array length mismatches the number of strategies.
    error AllocationMismatch();

    /// @dev Thrown when a donation address is set to the zero address.
    error DonationAddressZero();

    /// @dev Thrown when an invalid ERC-20 asset address is supplied.
    error InvalidAsset();

    /// @dev Thrown when an invalid name is supplied.
    error InvalidName();

    /// @dev Thrown when an invalid Aave pool address is supplied.
    error InvalidPool();

    /// @dev Thrown when an invalid aToken address is supplied.
    error InvalidAToken();

    /// @dev Thrown when an invalid vault address is supplied.
    error InvalidVault();

    /// @dev Thrown when a strategy address does not match expectations.
    error InvalidStrategyAddress();

    /// @dev Thrown when strategy allocations exceed the allowed basis points.
    error InvalidAllocationSum(uint256 allocationSum);

    /// @dev Thrown when caller is not authorized vault contract.
    error NotVault();

    /// @dev Thrown when caller is not authorized management address.
    error NotManagement();

    /// @dev Thrown when caller is neither keeper nor management.
    error NotKeeperOrManagement();

    /// @dev Thrown when caller is neither emergency admin nor management.
    error NotEmergencyAuthorized();

    /// @dev Thrown when attempting to accept management without a pending nominee.
    error NoPendingManagement();

    /// @dev Thrown when a strategy is registered more than once.
    error StrategyAlreadyExists();

    /// @dev Thrown when accessing a strategy index that is inactive or out of bounds.
    error StrategyNotActive(uint256 strategyId);

    /// @dev Thrown when an address is the zero address.
    error ZeroAddress();
}
