// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { Errors } from "src/common/Errors.sol";

/**
 * @title SparkMultiStrategyVault
 * @notice ERC-4626 wrapper that allocates a single Spark curated asset across the Savings and Lend donation strategies.
 * @dev This contract purposely keeps a subset of the features present in the full Octant MultistrategyVault:
 *      - governance-defined target weights and idle buffer (expressed in basis points);
 *      - deterministic withdrawal queue for capital retrieval;
 *      - quick rebalance helpers that mirror the debt management primitives in the upstream implementation.
 *
 *      Strategies are fixed at deployment—there are no add/remove mutators—because the business goal is to
 *      showcase a curated Spark Savings + SparkLend pair rather than a general-purpose multi-strategy registry.
 */
contract SparkMultiStrategyVault is ERC4626, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Percentage denominator used for target weights (10,000 basis points = 100%).
    uint256 internal constant BPS = 10_000;

    /*//////////////////////////////////////////////////////////////
                               STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Allocation metadata for each managed ERC-4626 strategy.
    struct StrategyConfig {
        /// @notice ERC-4626 strategy that accepts the same underlying asset as the vault.
        IERC4626 vault;
        /// @notice Target allocation in basis points relative to total managed assets.
        uint16 targetBps;
    }

    /*//////////////////////////////////////////////////////////////
                         STORAGE & CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Active strategies managed by the vault.
    StrategyConfig[] private _strategies;

    /// @notice Withdrawal queue encoded as strategy indices (highest priority first).
    uint16[] private _withdrawQueue;

    /// @notice Target idle buffer expressed in basis points.
    uint16 public idleTargetBps;

    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted whenever strategy targets or idle buffer are updated.
    /// @param idleBps Idle buffer expressed in basis points.
    /// @param strategyBps Array of strategy target weights matching `strategies()`.
    event TargetsUpdated(uint16 idleBps, uint16[] strategyBps);

    /// @notice Emitted after a successful rebalance cycle.
    /// @param totalAssets Total assets accounted by the vault after rebalance.
    /// @param idleAssets Idle assets held directly by the vault post rebalance.
    event Rebalanced(uint256 totalAssets, uint256 idleAssets);

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Constructs the Spark Multi Strategy Vault.
    /// @param _asset Underlying ERC-20 asset managed by the vault (e.g. USDS, USDC, etc.).
    /// @param _name Share token name.
    /// @param _symbol Share token symbol.
    /// @param _owner Governance address controlling configuration.
    /// @param _strategyVaults Initial ERC-4626 strategies (Spark Savings / SparkLend) to manage.
    /// @param _targetBps Target allocation for each strategy in basis points (e.g. 4000 for 40%, 4000 for 40%).
    /// @param _idleBps Target idle buffer expressed in basis points (e.g. 1000 for 10%, 1000 for 10%).
    constructor(
        IERC20 _asset,
        string memory _name,
        string memory _symbol,
        address _owner,
        address[] memory _strategyVaults,
        uint16[] memory _targetBps,
        uint16 _idleBps
    ) ERC20(_name, _symbol) ERC4626(_asset) Ownable(_owner) {
        require(address(_asset) != address(0), Errors.InvalidAsset());
        if (bytes(_name).length == 0 || bytes(_symbol).length == 0) revert Errors.InvalidName();
        _configureStrategies(_strategyVaults, _targetBps, _idleBps);
    }

    /*//////////////////////////////////////////////////////////////
                        USER-FACING OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ERC4626
    /// @dev After depositing assets, the vault attempts to rebalance to the configured targets.
    function deposit(uint256 _assets, address _receiver) public override nonReentrant returns (uint256 shares) {
        require(_receiver != address(0), Errors.InvalidReceiver());
        require(_assets != 0, Errors.ZeroAmount());
        shares = super.deposit(_assets, _receiver);
        _rebalance();
    }

    /// @inheritdoc ERC4626
    function mint(uint256 _shares, address _receiver) public override nonReentrant returns (uint256 assets) {
        require(_receiver != address(0), Errors.InvalidReceiver());
        require(_shares != 0, Errors.ZeroAmount());
        assets = super.mint(_shares, _receiver);
        _rebalance();
    }

    /// @inheritdoc ERC4626
    function withdraw(uint256 _assets, address _receiver, address _owner)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        require(_receiver != address(0), Errors.InvalidReceiver());
        require(_owner != address(0), Errors.InvalidOwner());
        require(_assets != 0, Errors.ZeroAmount());
        _ensureIdle(_assets);
        shares = super.withdraw(_assets, _receiver, _owner);
        _rebalance();
    }

    /// @inheritdoc ERC4626
    function redeem(uint256 _shares, address _receiver, address _owner)
        public
        override
        nonReentrant
        returns (uint256 assets)
    {
        require(_receiver != address(0), Errors.InvalidReceiver());
        require(_owner != address(0), Errors.InvalidOwner());
        require(_shares != 0, Errors.ZeroAmount());
        assets = previewRedeem(_shares);
        _ensureIdle(assets);
        assets = super.redeem(_shares, _receiver, _owner);
        _rebalance();
    }

    /*//////////////////////////////////////////////////////////////
                           GOVERNANCE HOOKS
    //////////////////////////////////////////////////////////////*/

    /// @notice Updates target weights and idle buffer, rebalancing afterwards.
    /// @param _idleBps Target idle buffer expressed in basis points.
    /// @param _targetBps Target allocation for each strategy in basis points.
    function setTargets(uint16 _idleBps, uint16[] calldata _targetBps) external onlyOwner {
        uint256 length = _strategies.length;
        require(_targetBps.length == length, Errors.InvalidTargetsLength());

        uint256 sumBps = _idleBps;
        for (uint256 i; i < length; i++) {
            sumBps += _targetBps[i];
            _strategies[i].targetBps = _targetBps[i];
        }
        require(sumBps == BPS, Errors.TargetSumMismatch());

        idleTargetBps = _idleBps;

        emit TargetsUpdated(idleTargetBps, _targetBps);
        _rebalance();
    }

    /// @notice Sets withdrawal queue order (strategy indices).
    /// @param _queue Withdrawal queue encoded as strategy indices (highest priority first).
    function setWithdrawalQueue(uint16[] calldata _queue) external onlyOwner {
        uint256 length = _strategies.length;
        uint256 queueLength = _queue.length;
        bool[] memory seen = new bool[](length);

        for (uint256 i; i < queueLength; ++i) {
            uint256 index = _queue[i];
            if (index >= length || seen[index]) revert Errors.InvalidQueue();
            seen[index] = true;
        }

        _withdrawQueue = _queue;
    }

    /// @notice Triggers a manual rebalance to the current targets.
    function rebalance() external onlyOwner {
        _rebalance();
    }

    /*//////////////////////////////////////////////////////////////
                               VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the managed strategies and their target weights.
    function strategies() external view returns (address[] memory vaults, uint16[] memory strategyBps, uint16 idleBps) {
        uint256 length = _strategies.length;
        vaults = new address[](length);
        strategyBps = new uint16[](length);
        for (uint256 i; i < length; ++i) {
            StrategyConfig memory cfg = _strategies[i];
            vaults[i] = address(cfg.vault);
            strategyBps[i] = cfg.targetBps;
        }
        idleBps = idleTargetBps;
    }

    /// @notice Returns the current withdrawal queue (strategy indices).
    function withdrawalQueue() external view returns (uint16[] memory queue) {
        queue = _withdrawQueue;
    }

    /// @inheritdoc ERC4626
    function totalAssets() public view override returns (uint256 total) {
        total = IERC20(asset()).balanceOf(address(this));
        uint256 length = _strategies.length;
        for (uint256 i; i < length; ++i) {
            StrategyConfig memory cfg = _strategies[i];
            uint256 shares = cfg.vault.balanceOf(address(this));
            if (shares == 0) continue;
            total += cfg.vault.convertToAssets(shares);
        }
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @dev Validates and stores the initial strategy configuration.
    /// @param _strategyVaults Initial ERC-4626 strategies (Spark Savings / SparkLend) to manage.
    /// @param _targetBps Target allocation for each strategy in basis points.
    /// @param _idleBps Target idle buffer expressed in basis points.
    function _configureStrategies(address[] memory _strategyVaults, uint16[] memory _targetBps, uint16 _idleBps)
        internal
    {
        if (_strategyVaults.length != _targetBps.length) revert Errors.InvalidTargetsLength();
        if (_strategyVaults.length == 0) revert Errors.NoStrategiesDefined();
        if (_strategies.length != 0) revert Errors.StrategiesAlreadyConfigured();

        uint256 sumBps = _idleBps;
        for (uint256 i; i < _strategyVaults.length; ++i) {
            if (_strategyVaults[i] == address(0)) revert Errors.InvalidStrategyAddress();
            sumBps += _targetBps[i];
            _strategies.push(StrategyConfig({ vault: IERC4626(_strategyVaults[i]), targetBps: _targetBps[i] }));
        }
        if (sumBps != BPS) revert Errors.TargetSumMismatch();

        idleTargetBps = _idleBps;

        // Default withdraw queue follows array ordering if not explicitly set later.
        uint16[] memory queue = new uint16[](_strategyVaults.length);
        for (uint16 i = 0; i < _strategyVaults.length; ++i) {
            queue[i] = i;
        }
        _withdrawQueue = queue;

        emit TargetsUpdated(idleTargetBps, _targetBps);
    }

    /// @dev Internal helper that synchronises idle and deployed balances to match targets.
    function _rebalance() internal {
        uint256 total = totalAssets();
        if (total == 0) {
            emit Rebalanced(0, 0);
            return;
        }

        uint256 desiredIdle = (total * idleTargetBps) / BPS;
        uint256 idleBalance = IERC20(asset()).balanceOf(address(this));

        if (idleBalance > desiredIdle) {
            uint256 investable = idleBalance - desiredIdle;
            _deploySurplus(investable, total);
        } else if (idleBalance < desiredIdle) {
            uint256 shortfall = desiredIdle - idleBalance;
            _withdrawFromStrategies(shortfall);
        }

        emit Rebalanced(totalAssets(), IERC20(asset()).balanceOf(address(this)));
    }

    /// @dev Deploys surplus idle capital across strategies, filling the largest gaps first.
    /// @param _amount Amount of assets to deploy.
    /// @param _total Total assets in the vault.
    function _deploySurplus(uint256 _amount, uint256 _total) internal {
        if (_amount == 0) return;

        uint256 length = _strategies.length;
        for (uint256 i; i < length && _amount > 0; ++i) {
            StrategyConfig memory cfg = _strategies[i];
            uint256 desired = (_total * cfg.targetBps) / BPS;
            uint256 current = _strategyAssets(cfg);
            if (current >= desired) continue;

            uint256 missing = desired - current;
            uint256 toInvest = Math.min(missing, _amount);
            if (toInvest == 0) continue;

            IERC4626 vault = cfg.vault;
            IERC20(asset()).forceApprove(address(vault), toInvest);
            vault.deposit(toInvest, address(this));
            _amount -= toInvest;
        }
    }

    /// @dev Ensures the vault holds enough idle assets to honour an upcoming withdrawal.
    /// @param _amountNeeded Assets required to honour the withdrawal.
    function _ensureIdle(uint256 _amountNeeded) internal {
        uint256 idleBalance = IERC20(asset()).balanceOf(address(this));
        if (idleBalance >= _amountNeeded) return;
        uint256 shortfall = _amountNeeded - idleBalance;
        _withdrawFromStrategies(shortfall);
    }

    /// @dev Iterates the withdrawal queue freeing funds until the requested shortfall is satisfied.
    /// @param _shortfall Assets required to honour the withdrawal.
    function _withdrawFromStrategies(uint256 _shortfall) internal {
        if (_shortfall == 0) return;

        uint256 queueLength = _withdrawQueue.length;
        for (uint256 i; i < queueLength && _shortfall > 0; ++i) {
            StrategyConfig memory cfg = _strategies[_withdrawQueue[i]];
            IERC4626 vault = cfg.vault;

            uint256 shares = vault.balanceOf(address(this));
            if (shares == 0) continue;

            uint256 available = vault.convertToAssets(shares);
            if (available == 0) continue;

            uint256 toWithdraw = Math.min(available, _shortfall);
            vault.withdraw(toWithdraw, address(this), address(this));
            _shortfall -= toWithdraw;
        }

        if (_shortfall > 0) revert Errors.InsufficientLiquidity();
    }

    /// @dev Returns the amount of underlying assets currently deployed in a given strategy.
    /// @param _cfg Strategy configuration.
    function _strategyAssets(StrategyConfig memory _cfg) internal view returns (uint256 assets) {
        uint256 shares = _cfg.vault.balanceOf(address(this));
        assets = shares == 0 ? 0 : _cfg.vault.convertToAssets(shares);
    }
}
