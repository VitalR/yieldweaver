// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IYieldStrategy } from "./interfaces/IYieldStrategy.sol";

/// @title YieldWeaverVault
/// @notice Multi-strategy ERC-4626 vault that routes capital across several Octant-compatible strategies and donates
///         realised profits to a designated beneficiary (Yield Donating Strategy behaviour).
/// @dev The contract intentionally mirrors the observable surface of `MultistrategyVault` where practical so it can act
///      as a lightweight, hackathon-friendly counterpart. It keeps strategy debt management simple (fixed allocations),
///      emits `StrategyChanged` events, and treats strategy adapters as Octant `ITokenizedStrategy` implementations.
/// @custom:octant-compatibility Shares events and high-level semantics with Octant v2 vaults for straightforward
///                               integration and testing.
contract YieldWeaverVault is ERC4626, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =============================================================
    //                   STORAGE & CONFIGURATION
    // =============================================================

    /// @notice Basis points denominator used for strategy allocation weights (100% == 10_000 bps).
    uint256 public constant ALLOCATION_BASIS_POINTS = 10_000;

    /// @notice Address that receives newly minted shares representing realised strategy profits.
    address public donationAddress;

    /// @notice Tracks the last observed total managed assets to measure profit/loss deltas on harvest.
    uint256 public lastTotalManagedAssets;

    /// @notice Flag toggling whether the donation buffer absorbs losses before depositors.
    bool public donationLossBufferEnabled = true;

    /// @notice Enumerates the type of mutation applied to the strategy set (aligned with Octant semantics).
    /// @dev Signatures mirror Octant's `StrategyChanged` event payload for ecosystem tooling compatibility.
    enum StrategyChangeType {
        ADDED,
        UPDATED
    }

    /// @notice Storage describing strategy target allocation and activation flag.
    /// @dev Lightweight analogue to Octant's `StrategyParams` focusing on allocation rather than debt accounting.
    struct StrategyPosition {
        IYieldStrategy strategy;
        uint16 allocationBps;
        bool isActive;
    }

    /// @notice Array of strategy positions currently registered with the vault (ordered for deterministic iteration).
    StrategyPosition[] private _strategies;

    /// @notice Sum of allocation basis points across strategies marked as active.
    uint256 private _activeAllocationBps;

    // =============================================================
    //                       EVENTS & ERRORS
    // =============================================================

    /// @notice Emitted when the donation address is updated.
    event DonationAddressUpdated(address indexed previousDonationAddress, address indexed newDonationAddress);

    /// @notice Emitted when the donation loss buffer toggle changes.
    event DonationLossBufferUpdated(bool donationLossBufferEnabled);

    /// @notice Emitted when a strategy is added or updated (mirrors Octant's `StrategyChanged`).
    event StrategyChanged(address indexed strategy, StrategyChangeType indexed changeType, uint16 allocationBps);

    /// @notice Emitted after a strategy's harvest hook reports realised yield.
    event StrategyHarvested(uint256 indexed strategyId, uint256 harvestedAssets);

    /// @notice Emitted whenever deposited capital is (re)distributed across strategies.
    event StrategiesRebalanced(uint256 deployedAssets, uint256 idleAssets);

    /// @notice Emitted after the vault-level harvest completes with net profit/loss information.
    event VaultHarvest(uint256 profit, uint256 loss, uint256 totalManagedAfter);

    /// @notice Thrown when the provided list of allocations does not match the number of strategies.
    error AllocationMismatch();

    /// @notice Thrown when attempting to set the donation address to the zero address.
    error DonationAddressZero();

    /// @notice Thrown when strategy allocations exceed 100% of capital.
    error InvalidAllocationSum(uint256 allocationSum);

    /// @notice Thrown when a supplied asset address does not match the vault's underlying token.
    error InvalidAsset();

    /// @notice Thrown when attempting to register a duplicate strategy.
    error StrategyAlreadyExists();

    /// @notice Thrown when interacting with an index that does not reference an active strategy.
    error StrategyNotActive(uint256 strategyId);

    // =============================================================
    //                         CONSTRUCTOR
    // =============================================================

    /// @param _asset Underlying ERC-20 asset accepted by the vault.
    /// @param _name ERC-20 name of the vault share token.
    /// @param _symbol ERC-20 symbol of the vault share token.
    /// @param _donationAddress Initial address receiving profit donations.
    /// @param _initialOwner Address that receives ownership of administrative controls.
    constructor(
        IERC20 _asset,
        string memory _name,
        string memory _symbol,
        address _donationAddress,
        address _initialOwner
    ) ERC20(_name, _symbol) ERC4626(_asset) Ownable(_initialOwner) {
        require(address(_asset) != address(0), InvalidAsset());
        require(_donationAddress != address(0), DonationAddressZero());
        donationAddress = _donationAddress;
    }

    // =============================================================
    //                         ADMIN ACTIONS
    // =============================================================

    /// @notice Updates the donation address that receives newly minted profit shares.
    /// @param _newDonationAddress Address that will receive future donated shares.
    function setDonationAddress(address _newDonationAddress) external onlyOwner {
        require(_newDonationAddress != address(0), DonationAddressZero());

        address previousDonationAddress = donationAddress;
        donationAddress = _newDonationAddress;

        emit DonationAddressUpdated(previousDonationAddress, _newDonationAddress);
    }

    /// @notice Enables or disables the donation loss buffer mechanic.
    /// @param _enabled True to let donation shares absorb losses before depositors, false to disable.
    function setDonationLossBufferEnabled(bool _enabled) external onlyOwner {
        donationLossBufferEnabled = _enabled;
        emit DonationLossBufferUpdated(_enabled);
    }

    /// @notice Registers a new strategy and optionally activates it with a target allocation.
    /// @dev Ensures the strategy manages the same asset and that active allocations remain within 100%.
    /// @param _strategy Strategy adapter implementing `IYieldStrategy` (and Octant tokenized strategy semantics).
    /// @param _allocationBps Target allocation expressed in basis points.
    /// @param _isActive Whether the strategy should be active immediately.
    function addStrategy(IYieldStrategy _strategy, uint16 _allocationBps, bool _isActive) external onlyOwner {
        require(address(_strategy) != address(0), InvalidAsset());
        require(_strategy.asset() == asset(), InvalidAsset());

        for (uint256 i = 0; i < _strategies.length; ++i) {
            require(address(_strategies[i].strategy) != address(_strategy), StrategyAlreadyExists());
        }

        _strategies.push(StrategyPosition({ strategy: _strategy, allocationBps: _allocationBps, isActive: _isActive }));

        if (_isActive) {
            _activeAllocationBps += _allocationBps;
            if (_activeAllocationBps > ALLOCATION_BASIS_POINTS) revert InvalidAllocationSum(_activeAllocationBps);
        }

        emit StrategyChanged(address(_strategy), StrategyChangeType.ADDED, _allocationBps);
    }

    /// @notice Updates allocation and activation status for an existing strategy.
    /// @param _strategyId Index of the strategy in storage.
    /// @param _allocationBps New allocation in basis points.
    /// @param _isActive Whether the strategy remains active after the update.
    function updateStrategy(uint256 _strategyId, uint16 _allocationBps, bool _isActive) external onlyOwner {
        require(_strategyId < _strategies.length, StrategyNotActive(_strategyId));
        StrategyPosition storage strategyPosition = _strategies[_strategyId];

        if (strategyPosition.isActive) {
            _activeAllocationBps -= strategyPosition.allocationBps;
        }

        strategyPosition.allocationBps = _allocationBps;
        strategyPosition.isActive = _isActive;

        if (_isActive) {
            _activeAllocationBps += _allocationBps;
            if (_activeAllocationBps > ALLOCATION_BASIS_POINTS) revert InvalidAllocationSum(_activeAllocationBps);
        }

        emit StrategyChanged(address(strategyPosition.strategy), StrategyChangeType.UPDATED, _allocationBps);
    }

    /// @notice Bulk-updates allocation basis points for all strategies.
    /// @param _newAllocationsBps Array of allocation basis points matching the number of strategies.
    function setAllocations(uint16[] calldata _newAllocationsBps) external onlyOwner {
        require(_newAllocationsBps.length == _strategies.length, AllocationMismatch());

        uint256 newActiveSum;
        for (uint256 i = 0; i < _newAllocationsBps.length; ++i) {
            StrategyPosition storage strategyPosition = _strategies[i];
            strategyPosition.allocationBps = _newAllocationsBps[i];
            if (strategyPosition.isActive) {
                newActiveSum += _newAllocationsBps[i];
            }
        }

        if (newActiveSum > ALLOCATION_BASIS_POINTS) revert InvalidAllocationSum(newActiveSum);
        _activeAllocationBps = newActiveSum;
    }

    // =============================================================
    //                   EXTERNAL / VIEW FUNCTIONS
    // =============================================================

    /// @notice Returns the full strategy array (intended for off-chain reads / SDKs).
    function strategies() external view returns (StrategyPosition[] memory strategyList) {
        strategyList = _strategies;
    }

    /// @notice Returns the number of registered strategies.
    function strategiesLength() external view returns (uint256) {
        return _strategies.length;
    }

    /// @notice Returns the sum of allocations for currently active strategies.
    function activeAllocationBps() external view returns (uint256) {
        return _activeAllocationBps;
    }

    /// @inheritdoc ERC4626
    function totalAssets() public view override returns (uint256) {
        uint256 totalManaged = IERC20(asset()).balanceOf(address(this));
        for (uint256 i = 0; i < _strategies.length; ++i) {
            StrategyPosition memory strategyPosition = _strategies[i];
            if (strategyPosition.isActive) {
                totalManaged += strategyPosition.strategy.totalAssets();
            }
        }
        return totalManaged;
    }

    /// @notice Returns the total amount of assets currently managed by all active strategies.
    function totalStrategyAssets() public view returns (uint256 totalManaged) {
        for (uint256 i = 0; i < _strategies.length; ++i) {
            StrategyPosition memory strategyPosition = _strategies[i];
            if (strategyPosition.isActive) {
                totalManaged += strategyPosition.strategy.totalAssets();
            }
        }
    }

    // =============================================================
    //                      ERC-4626 HOOKS
    // =============================================================

    /// @inheritdoc ERC4626
    /// @dev After minting shares the freshly deposited assets are forwarded to strategies following allocation weights.
    function _deposit(address _caller, address _receiver, uint256 _assets, uint256 _shares) internal override {
        super._deposit(_caller, _receiver, _assets, _shares);
        _deployToStrategies(_assets);
        _syncManagedBaseline();
    }

    /// @inheritdoc ERC4626
    /// @dev Ensures sufficient liquidity exists locally before executing the parent withdrawal routine.
    function _withdraw(address _caller, address _receiver, address _owner, uint256 _assets, uint256 _shares)
        internal
        override
    {
        _ensureLiquidity(_assets);
        super._withdraw(_caller, _receiver, _owner, _assets, _shares);
        _syncManagedBaseline();
    }

    // =============================================================
    //                        HARVEST LOGIC
    // =============================================================

    /// @notice Harvests strategies, donates profits, and applies optional loss buffering.
    /// @return profit Net profit realised across all strategies (denominated in the underlying asset).
    /// @return loss Net loss realised across all strategies (denominated in the underlying asset).
    function harvest() external nonReentrant returns (uint256 profit, uint256 loss) {
        uint256 previousBaseline = lastTotalManagedAssets;
        uint256 managedBefore = totalAssets();
        if (previousBaseline == 0) {
            previousBaseline = managedBefore;
        }

        for (uint256 i = 0; i < _strategies.length; ++i) {
            StrategyPosition memory strategyPosition = _strategies[i];
            if (!strategyPosition.isActive) continue;

            uint256 harvestedAssets = strategyPosition.strategy.harvest();
            emit StrategyHarvested(i, harvestedAssets);
        }

        uint256 managedAfter = totalAssets();
        if (managedAfter > previousBaseline) {
            profit = managedAfter - previousBaseline;
            _donateProfit(profit, previousBaseline);
        } else if (managedAfter < previousBaseline) {
            loss = previousBaseline - managedAfter;
            _absorbLoss(loss);
        }

        lastTotalManagedAssets = managedAfter;
        emit VaultHarvest(profit, loss, managedAfter);
    }

    // =============================================================
    //                 INTERNAL STRATEGY LOGIC
    // =============================================================

    /// @dev Deploys `_assets` across all active strategies according to target allocation ratios.
    /// @param _assets Amount of assets to distribute.
    function _deployToStrategies(uint256 _assets) internal {
        if (_assets == 0 || _activeAllocationBps == 0) {
            emit StrategiesRebalanced(0, _assets);
            return;
        }

        uint256 remaining = _assets;
        uint256 activeSum = _activeAllocationBps;

        for (uint256 i = 0; i < _strategies.length; ++i) {
            StrategyPosition memory strategyPosition = _strategies[i];
            if (!strategyPosition.isActive || strategyPosition.allocationBps == 0) continue;

            uint256 amount = (_assets * strategyPosition.allocationBps) / activeSum;
            if (i == _strategies.length - 1 || amount > remaining) {
                amount = remaining;
            }

            if (amount == 0) continue;

            remaining -= amount;
            IERC20(asset()).safeTransfer(address(strategyPosition.strategy), amount);
            strategyPosition.strategy.deploy(amount);
        }

        emit StrategiesRebalanced(_assets - remaining, IERC20(asset()).balanceOf(address(this)));
    }

    /// @dev Ensures sufficient idle liquidity exists to fulfil a withdrawal, unwinding strategies proportionally.
    /// @param _amountNeeded Assets required to honour the withdrawal.
    function _ensureLiquidity(uint256 _amountNeeded) internal {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle >= _amountNeeded) {
            return;
        }

        uint256 shortfall = _amountNeeded - idle;
        for (uint256 i = 0; i < _strategies.length && shortfall > 0; ++i) {
            StrategyPosition memory strategyPosition = _strategies[i];
            if (!strategyPosition.isActive) continue;

            uint256 toWithdraw =
                (shortfall * strategyPosition.allocationBps) / (_activeAllocationBps == 0 ? 1 : _activeAllocationBps);
            if (toWithdraw == 0) {
                toWithdraw = shortfall;
            }

            uint256 withdrawn = strategyPosition.strategy.withdraw(toWithdraw, address(this));
            if (withdrawn >= shortfall) {
                shortfall = 0;
            } else {
                shortfall -= withdrawn;
            }
        }

        if (shortfall > 0) {
            for (uint256 i = 0; i < _strategies.length && shortfall > 0; ++i) {
                StrategyPosition memory strategyPosition = _strategies[i];
                if (!strategyPosition.isActive) continue;

                uint256 withdrawn = strategyPosition.strategy.withdraw(shortfall, address(this));
                if (withdrawn >= shortfall) {
                    shortfall = 0;
                } else {
                    shortfall -= withdrawn;
                }
            }
        }
    }

    /// @dev Mints additional shares to the donation address representing realised profit.
    /// @param _profit Amount of profit realised.
    function _donateProfit(uint256 _profit, uint256 _baselineAssets) internal {
        if (_profit == 0 || donationAddress == address(0)) return;

        uint256 currentSupply = totalSupply();
        if (currentSupply == 0) {
            _mint(donationAddress, _profit);
            return;
        }

        if (_baselineAssets == 0) {
            _mint(donationAddress, _profit);
            return;
        }

        uint256 sharesToMint = (_profit * currentSupply) / _baselineAssets;
        if (sharesToMint == 0) return;
        _mint(donationAddress, sharesToMint);
    }

    /// @dev Burns donated shares to offset losses before distributing them to depositors.
    /// @param _loss Amount of loss realised.
    function _absorbLoss(uint256 _loss) internal {
        if (!donationLossBufferEnabled || donationAddress == address(0) || _loss == 0) return;

        uint256 sharesToBurn;
        if (totalSupply() == 0) {
            sharesToBurn = 0;
        } else {
            sharesToBurn = previewWithdraw(_loss);
        }

        uint256 donationBalance = balanceOf(donationAddress);
        if (sharesToBurn > donationBalance) {
            sharesToBurn = donationBalance;
        }

        if (sharesToBurn > 0) {
            _burn(donationAddress, sharesToBurn);
        }
    }

    /// @dev Updates the baseline used to compute profit/loss on the next harvest.
    function _syncManagedBaseline() internal {
        lastTotalManagedAssets = totalAssets();
    }
}
