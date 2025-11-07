// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import {
    YieldDonatingTokenizedStrategy
} from "@octant-v2-core/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";

import { SparkLendDonationStrategy } from "./SparkLendDonationStrategy.sol";
import { Errors } from "../../common/Errors.sol";

/**
 * @title SparkLendStrategyFactory
 * @notice CREATE2 factory that deploys Octant v2 YDS pairs for SparkLend (Aave v3-style pool + aToken).
 * @notice Each deployment mints:
 *         (1) a fresh `YieldDonatingTokenizedStrategy`, and
 *         (2) a fresh `SparkLendDonationStrategy` wired to the configured SparkLend pool/aToken pair.
 *
 * @dev Rationale:
 *      - `YieldDonatingTokenizedStrategy` holds ERC-4626-style share accounting and donation mint/burn logic.
 *      - `SparkLendDonationStrategy` integrates with SparkLend (Aave v3) supply/withdraw flows.
 *      - CREATE2 ensures deterministic addresses so scripts can pre-compute deployments.
 *
 * Determinism:
 *      - Tokenized and Strategy are deployed with distinct salts derived from (pool, aToken, asset, name, referral).
 *      - Use `predictLendAddresses(...)` to pre-compute both addresses off-chain/on-chain.
 *
 * Registry:
 *      - Enforces a single strategy per (asset, pool) pair via `_lendStrategies[asset][pool]`.
 *
 * Security:
 *      - OnlyOwner (ideally a multisig) may deploy.
 *      - Factory performs minimal validation; strategy constructors enforce invariants (non-zero params, etc.).
 */
contract SparkLendStrategyFactory is Ownable {
    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a new SparkLend pair is deployed.
    /// @param strategy       Deployed SparkLendDonationStrategy address.
    /// @param tokenized      Deployed YieldDonatingTokenizedStrategy address.
    /// @param asset          Underlying ERC-20 handled by the strategy.
    /// @param pool           SparkLend pool address.
    /// @param aToken         SparkLend aToken address.
    /// @param name           Human-readable strategy name.
    /// @param referral       Spark referral code (0 if disabled).
    /// @param enableBurning  Whether donation-burn-on-loss is enabled in this pair.
    event RegisteredSparkLendStrategy(
        address indexed strategy,
        address indexed tokenized,
        address indexed asset,
        address pool,
        address aToken,
        string name,
        uint16 referral,
        bool enableBurning
    );

    /*//////////////////////////////////////////////////////////////
                        STORAGE & CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Precomputed hash of the YieldDonatingTokenizedStrategy creation code.
    bytes32 internal constant YDS_CREATION_HASH = keccak256(type(YieldDonatingTokenizedStrategy).creationCode);

    /// @notice Mapping of deployed lend strategies keyed by underlying asset and pool.
    mapping(address asset => mapping(address pool => address strategy)) private _lendStrategies;

    /// @param _initialOwner Address that will own the factory.
    constructor(address _initialOwner) Ownable(_initialOwner) { }

    /*//////////////////////////////////////////////////////////////
                    LEND (AAVE-STYLE) DEPLOY & PREDICT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploy a complete Octant v2 YDS pair using CREATE2 (deterministic addresses).
     * @dev Constructors of both contracts WILL run. Addresses depend on salt+init code hash.
     *
     * @param _pool            Spark Lend Pool address.
     * @param _aToken          Spark Lend aToken address.
     * @param _asset           Underlying token accepted by the vault (must equal ISparkPool(pool).asset()).
     * @param _name            Strategy name (forwarded to BaseStrategy).
     * @param _management      Management role address.
     * @param _keeper          Keeper role address.
     * @param _emergencyAdmin  Emergency admin role address.
     * @param _donationAddress Donation sink (dragon router) for TokenizedStrategy.
     * @param _enableBurning   If true, losses first burn donation shares (dragon) before affecting PPS.
     * @param _referral        Spark referral code (0 to disable).
     *
     * @return strategy  The deployed SparkLendDonationStrategy.
     * @return tokenized The deployed YieldDonatingTokenizedStrategy.
     */
    function deployLendPair(
        address _pool,
        address _aToken,
        address _asset,
        string calldata _name,
        address _management,
        address _keeper,
        address _emergencyAdmin,
        address _donationAddress,
        bool _enableBurning,
        uint16 _referral
    ) external onlyOwner returns (address strategy, address tokenized) {
        require(_pool != address(0) && _aToken != address(0) && _asset != address(0), Errors.ZeroAddress());
        require(bytes(_name).length != 0, Errors.InvalidName());
        require(_lendStrategies[_asset][_pool] == address(0), Errors.AlreadyDeployed());

        bytes memory ydsBytecode = type(YieldDonatingTokenizedStrategy).creationCode;
        bytes32 saltT = _saltTokenizedLend(_pool, _aToken, _asset, _name, _referral);
        tokenized = Create2.deploy(0, saltT, ydsBytecode);

        bytes memory stratBytecode = abi.encodePacked(
            type(SparkLendDonationStrategy).creationCode,
            abi.encode(
                _pool,
                _aToken,
                _asset,
                _name,
                _management,
                _keeper,
                _emergencyAdmin,
                _donationAddress,
                _enableBurning,
                tokenized,
                _referral
            )
        );
        bytes32 saltS = _saltStrategyLend(_pool, _aToken, _asset, _name, _referral);
        strategy = Create2.deploy(0, saltS, stratBytecode);

        _lendStrategies[_asset][_pool] = strategy;

        emit RegisteredSparkLendStrategy(strategy, tokenized, _asset, _pool, _aToken, _name, _referral, _enableBurning);
    }

    /**
     * @notice Predict CREATE2 addresses for the YDS pair given the exact constructor inputs.
     * @dev You MUST pass the *same* parameters here as you will to `deployLendPair(...)` to get identical
     * predictions.
     *
     * @param _pool            Spark Lend Pool address.
     * @param _aToken          Spark Lend aToken address.
     * @param _asset           Underlying token accepted by the vault.
     * @param _name            Strategy name (forwarded to BaseStrategy).
     * @param _management      Management role address.
     * @param _keeper          Keeper role address.
     * @param _emergencyAdmin  Emergency admin role address.
     * @param _donationAddress Donation sink (dragon router).
     * @param _enableBurning   Donation burn flag.
     * @param _referral        Spark referral code (0 to disable).
     *
     * @return tokenizedPred Predicted YieldDonatingTokenizedStrategy address.
     * @return strategyPred  Predicted SparkLendDonationStrategy address.
     */
    function predictLendAddresses(
        address _pool,
        address _aToken,
        address _asset,
        string calldata _name,
        address _management,
        address _keeper,
        address _emergencyAdmin,
        address _donationAddress,
        bool _enableBurning,
        uint16 _referral
    ) external view returns (address tokenizedPred, address strategyPred) {
        bytes32 saltT = _saltTokenizedLend(_pool, _aToken, _asset, _name, _referral);
        tokenizedPred = Create2.computeAddress(saltT, YDS_CREATION_HASH, address(this));

        bytes memory stratBytecode = abi.encodePacked(
            type(SparkLendDonationStrategy).creationCode,
            abi.encode(
                _pool,
                _aToken,
                _asset,
                _name,
                _management,
                _keeper,
                _emergencyAdmin,
                _donationAddress,
                _enableBurning,
                tokenizedPred,
                _referral
            )
        );
        bytes32 saltS = _saltStrategyLend(_pool, _aToken, _asset, _name, _referral);
        bytes32 stratHash = keccak256(stratBytecode);
        strategyPred = Create2.computeAddress(saltS, stratHash, address(this));
    }

    /**
     * @notice Lookup a deployed strategy by (asset, pool) pair.
     * @param _asset  Underlying token.
     * @param _pool  Spark Lend Pool address.
     * @return strategy The deployed strategy address, or `address(0)` if none.
     */
    function getDeployedLendStrategy(address _asset, address _pool) external view returns (address) {
        return _lendStrategies[_asset][_pool];
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Deterministic salt for the TokenizedStrategy (SparkLend variant).
    /// @param _pool Spark Lend Pool address.
    /// @param _asset Underlying token accepted by the vault.
    /// @param _name Strategy name.
    /// @param _referral Spark referral code (0 to disable).
    /// @return bytes32 The deterministic salt.
    function _saltTokenizedLend(address _pool, address _aToken, address _asset, string calldata _name, uint16 _referral)
        internal
        pure
        returns (bytes32)
    {
        bytes32 nameHash = keccak256(bytes(_name));
        return keccak256(abi.encode(_pool, _aToken, _asset, nameHash, _referral, bytes2("LD"), bytes1("T")));
    }

    /// @dev Deterministic salt for the Strategy (SparkLend variant).
    /// @param _pool Spark Lend Pool address.
    /// @param _asset Underlying token accepted by the vault.
    /// @param _name Strategy name.
    /// @param _referral Spark referral code (0 to disable).
    /// @return bytes32 The deterministic salt.
    function _saltStrategyLend(address _pool, address _aToken, address _asset, string calldata _name, uint16 _referral)
        internal
        pure
        returns (bytes32)
    {
        bytes32 nameHash = keccak256(bytes(_name));
        return keccak256(abi.encode(_pool, _aToken, _asset, nameHash, _referral, bytes2("LD"), bytes1("S")));
    }
}

