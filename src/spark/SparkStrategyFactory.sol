// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {
    YieldDonatingTokenizedStrategy
} from "@octant-v2-core/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";

import { SparkSavingsDonationStrategy } from "./SparkSavingsDonationStrategy.sol";
import { SparkLendDonationStrategy } from "./SparkLendDonationStrategy.sol";
import { Errors } from "../common/Errors.sol";

/**
 * @title SparkStrategyFactory
 *  /// @notice Unified factory (CREATE2) to deploy Octant v2 YDS pairs for:
 * ///         - Spark Savings Vaults V2 (ERC-4626)
 * ///         - SparkLend (Aave v3-style Pool + aToken)
 * @notice Deterministic (CREATE2) factory that deploys a complete Octant v2 YDS pair:
 *         (1) a fresh `YieldDonatingTokenizedStrategy` and
 *         (2) a fresh `SparkSavingsDonationStrategy` wired to a Spark Savings Vault V2 (ERC-4626).
 *
 * @dev Rationale:
 *      - `TokenizedStrategy` owns ERC-4626-like share accounting and donate/burn logic.
 *      - `SparkSavingsDonationStrategy` (constructor-based) implements yield plumbing for Spark Savings Vaults V2.
 *      - We use CREATE2 for *both* so constructors run and addresses are predictable.
 *
 * Determinism:
 *      - Tokenized and Strategy are deployed with distinct salts derived from (vault, asset, name, referral, "T"/"S").
 *      - Use `predictSavingsAddresses(...)` to pre-compute both addresses off-chain/on-chain.
 *
 * Registry:
 *      - Enforces a single Strategy per (asset, vault) pair via `savingsStrategies[asset][vault]`.
 *
 * Security:
 *      - OnlyOwner (ideally a multisig) may deploy.
 *      - Factory performs light policy checks; Strategy enforces invariants (vault.asset() == asset, zero-addresses).
 */
contract SparkStrategyFactory is Ownable2Step {
    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/
    /// @notice Emitted when a new Spark YDS pair is deployed.
    /// @param strategy       Deployed SparkSavingsDonationStrategy address.
    /// @param tokenized      Deployed YieldDonatingTokenizedStrategy address.
    /// @param asset          Underlying ERC-20 handled by the vault/strategy.
    /// @param sparkVault     Spark Savings Vault V2 (ERC-4626) used as yield source.
    /// @param name           Human-readable strategy name.
    /// @param referral       Spark referral code used on 3-arg deposit (0 if disabled).
    /// @param enableBurning  Whether donation-burn-on-loss is enabled in this pair.
    event RegisteredSparkSavingsStrategy(
        address indexed strategy,
        address indexed tokenized,
        address indexed asset,
        address sparkVault,
        string name,
        uint16 referral,
        bool enableBurning
    );

    /// @notice Emitted when a new Spark Lend YDS pair is deployed.
    /// @param strategy       Deployed SparkLendDonationStrategy address.
    /// @param tokenized      Deployed YieldDonatingTokenizedStrategy address.
    /// @param asset          Underlying ERC-20 handled by the vault/strategy.
    /// @param pool           Spark Lend Pool address.
    /// @param aToken         Spark Lend aToken address.
    /// @param name           Human-readable strategy name.
    /// @param referral       Spark referral code used on 3-arg deposit (0 if disabled).
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

    /// @notice Mapping of deployed strategies by asset and spark vault.
    mapping(address asset => mapping(address vault => address strategy)) private savingsStrategies;

    /// @notice Mapping of deployed strategies by asset and pool.
    mapping(address asset => mapping(address pool => address strategy)) private lendStrategies;

    /// @param _initialOwner Address that will own the factory (recommend a multisig).
    constructor(address _initialOwner) Ownable(_initialOwner) { }

    /*//////////////////////////////////////////////////////////////
                    SAVINGS (ERC-4626) FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploy a complete Octant v2 YDS pair using CREATE2 (deterministic addresses).
     * @dev Constructors of both contracts WILL run. Addresses depend on salt+init code hash.
     *
     * @param _sparkVault      Spark Savings Vault V2 (ERC-4626) address (e.g., spUSDC)
     * @param _asset           Underlying token accepted by the vault (must equal ISparkVault(sparkVault).asset())
     * @param _name            Strategy name (forwarded to BaseStrategy)
     * @param _management      Management role address
     * @param _keeper          Keeper role address
     * @param _emergencyAdmin  Emergency admin role address
     * @param _donationAddress Donation sink (dragon router) for TokenizedStrategy
     * @param _enableBurning   If true, losses first burn donation shares (dragon) before affecting PPS
     * @param _referral        Spark referral code (0 to disable)
     *
     * @return strategy  The deployed SparkSavingsDonationStrategy
     * @return tokenized The deployed YieldDonatingTokenizedStrategy
     */
    function deploySavingsPair(
        address _sparkVault,
        address _asset,
        string calldata _name,
        address _management,
        address _keeper,
        address _emergencyAdmin,
        address _donationAddress,
        bool _enableBurning,
        uint16 _referral
    ) external onlyOwner returns (address strategy, address tokenized) {
        require(_sparkVault != address(0) && _asset != address(0), Errors.ZeroAddress());
        require(bytes(_name).length != 0, Errors.InvalidName());
        require(savingsStrategies[_asset][_sparkVault] == address(0), Errors.AlreadyDeployed());

        // -------- 1) CREATE2 deploy TokenizedStrategy (no constructor args expected) --------
        bytes32 saltT = _saltTokenizedSavings(_sparkVault, _asset, _name, _referral);
        bytes memory ydsBytecode = abi.encodePacked(
            type(YieldDonatingTokenizedStrategy).creationCode
            // If YDS ever gets constructor args, append abi.encode(args...) here AND in predictSavingsAddresses()
        );
        tokenized = Create2.deploy(0, saltT, ydsBytecode);

        // -------- 2) CREATE2 deploy Strategy (constructor-based; wire tokenized) ----------
        bytes32 saltS = _saltStrategySavings(_sparkVault, _asset, _name, _referral);
        bytes memory stratBytecode = abi.encodePacked(
            type(SparkSavingsDonationStrategy).creationCode,
            abi.encode(
                _sparkVault,
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
        strategy = Create2.deploy(0, saltS, stratBytecode);

        // -------- 3) Register + emit ------------------------------------------------------
        savingsStrategies[_asset][_sparkVault] = strategy;

        emit RegisteredSparkSavingsStrategy(strategy, tokenized, _asset, _sparkVault, _name, _referral, _enableBurning);
    }

    /**
     * @notice Predict CREATE2 addresses for the YDS pair given the exact constructor inputs.
     * @dev You MUST pass the *same* parameters here as you will to `deploySavingsPair(...)` to get identical
     * predictions.
     *
     * @param _sparkVault      Spark Savings Vault V2 (ERC-4626)
     * @param _asset           Underlying token accepted by the vault
     * @param _name           Strategy name
     * @param _management      Management role
     * @param _keeper          Keeper role
     * @param _emergencyAdmin  Emergency admin role
     * @param _donationAddress Donation sink (dragon router)
     * @param _enableBurning   Donation burn flag
     * @param _referral        Spark referral code (0 to disable)
     *
     * @return tokenizedPred Predicted YieldDonatingTokenizedStrategy address
     * @return strategyPred  Predicted SparkSavingsDonationStrategy address
     */
    function predictSavingsAddresses(
        address _sparkVault,
        address _asset,
        string calldata _name,
        address _management,
        address _keeper,
        address _emergencyAdmin,
        address _donationAddress,
        bool _enableBurning,
        uint16 _referral
    ) external view returns (address tokenizedPred, address strategyPred) {
        // Tokenized (YDS).
        bytes32 saltT = _saltTokenizedSavings(_sparkVault, _asset, _name, _referral);
        bytes memory ydsBytecode = abi.encodePacked(type(YieldDonatingTokenizedStrategy).creationCode);
        bytes32 ydsHash = keccak256(ydsBytecode);
        tokenizedPred = Create2.computeAddress(saltT, ydsHash, address(this));

        // Strategy.
        bytes32 saltS = _saltStrategySavings(_sparkVault, _asset, _name, _referral);
        bytes memory stratBytecode = abi.encodePacked(
            type(SparkSavingsDonationStrategy).creationCode,
            abi.encode(
                _sparkVault,
                _asset,
                _name,
                _management,
                _keeper,
                _emergencyAdmin,
                _donationAddress,
                _enableBurning,
                tokenizedPred, // The strategy will be wired to this tokenized address at deploy time.
                _referral
            )
        );
        bytes32 stratHash = keccak256(stratBytecode);
        strategyPred = Create2.computeAddress(saltS, stratHash, address(this));
    }

    /**
     * @notice Lookup a deployed strategy by (asset, vault) pair.
     * @param _asset  Underlying token.
     * @param _vault  Spark Savings Vault V2 (ERC-4626).
     * @return strategy The deployed strategy address, or `address(0)` if none.
     */
    function getDeployedSavingsStrategy(address _asset, address _vault) external view returns (address strategy) {
        return savingsStrategies[_asset][_vault];
    }

    /*//////////////////////////////////////////////////////////////
                    LEND (Pool + aToken) FUNCTIONS
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
        require(lendStrategies[_asset][_pool] == address(0), Errors.AlreadyDeployed());

        bytes32 saltT = _saltTokenizedLend(_pool, _asset, _name, _referral);
        bytes memory ydsBytecode = abi.encodePacked(type(YieldDonatingTokenizedStrategy).creationCode);
        tokenized = Create2.deploy(0, saltT, ydsBytecode);

        bytes32 saltS = _saltStrategyLend(_pool, _asset, _name, _referral);
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
        strategy = Create2.deploy(0, saltS, stratBytecode);

        lendStrategies[_asset][_pool] = strategy;
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
        bytes32 saltT = _saltTokenizedLend(_pool, _asset, _name, _referral);
        bytes memory ydsBytecode = abi.encodePacked(type(YieldDonatingTokenizedStrategy).creationCode);
        bytes32 ydsHash = keccak256(ydsBytecode);
        tokenizedPred = Create2.computeAddress(saltT, ydsHash, address(this));

        bytes32 saltS = _saltStrategyLend(_pool, _asset, _name, _referral);
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
        bytes32 stratHash = keccak256(stratBytecode);
        strategyPred = Create2.computeAddress(saltS, stratHash, address(this));
    }

    /**
     * @notice Lookup a deployed strategy by (asset, pool) pair.
     * @param _asset  Underlying token.
     * @param _pool  Spark Lend Pool address.
     * @return strategy The deployed strategy address, or `address(0)` if none.
     */
    function getDeployedLendStrategy(address _asset, address _pool) external view returns (address strategy) {
        return lendStrategies[_asset][_pool];
    }

    /*//////////////////////////////////////////////////////////////
                            UTILITIES
    //////////////////////////////////////////////////////////////*/

    /// @dev Deterministic salt for the TokenizedStrategy (savings variant).
    /// @param _sparkVault Spark Savings Vault V2 (ERC-4626) address.
    /// @param _asset Underlying token accepted by the vault.
    /// @param _name Strategy name.
    /// @param _referral Spark referral code (0 to disable).
    /// @return bytes32 The deterministic salt.
    function _saltTokenizedSavings(address _sparkVault, address _asset, string calldata _name, uint16 _referral)
        internal
        pure
        returns (bytes32)
    {
        bytes32 nameHash = keccak256(bytes(_name));
        return keccak256(abi.encode(_sparkVault, _asset, nameHash, _referral, bytes2("SV"), bytes1("T")));
    }

    /// @dev Deterministic salt for the Strategy (savings variant).
    /// @param _sparkVault Spark Savings Vault V2 (ERC-4626) address.
    /// @param _asset Underlying token accepted by the vault.
    /// @param _name Strategy name.
    /// @param _referral Spark referral code (0 to disable).
    /// @return bytes32 The deterministic salt.
    function _saltStrategySavings(address _sparkVault, address _asset, string calldata _name, uint16 _referral)
        internal
        pure
        returns (bytes32)
    {
        bytes32 nameHash = keccak256(bytes(_name));
        return keccak256(abi.encode(_sparkVault, _asset, nameHash, _referral, bytes2("SV"), bytes1("S")));
    }

    /// @dev Deterministic salt for the TokenizedStrategy (SparkLend variant).
    /// @param _pool Spark Lend Pool address.
    /// @param _asset Underlying token accepted by the vault.
    /// @param _name Strategy name.
    /// @param _referral Spark referral code (0 to disable).
    /// @return bytes32 The deterministic salt.
    function _saltTokenizedLend(address _pool, address _asset, string calldata _name, uint16 _referral)
        internal
        pure
        returns (bytes32)
    {
        bytes32 nameHash = keccak256(bytes(_name));
        return keccak256(abi.encode(_pool, _asset, nameHash, _referral, bytes2("LD"), bytes1("T")));
    }

    /// @dev Deterministic salt for the Strategy (SparkLend variant).
    /// @param _pool Spark Lend Pool address.
    /// @param _asset Underlying token accepted by the vault.
    /// @param _name Strategy name.
    /// @param _referral Spark referral code (0 to disable).
    /// @return bytes32 The deterministic salt.
    function _saltStrategyLend(address _pool, address _asset, string calldata _name, uint16 _referral)
        internal
        pure
        returns (bytes32)
    {
        bytes32 nameHash = keccak256(bytes(_name));
        return keccak256(abi.encode(_pool, _asset, nameHash, _referral, bytes2("LD"), bytes1("S")));
    }
}
