// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import {
    YieldDonatingTokenizedStrategy
} from "@octant-v2-core/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";

import { SparkSavingsDonationStrategy } from "./SparkSavingsDonationStrategy.sol";
import { Errors } from "../../common/Errors.sol";

/**
 * @title SparkSavingsStrategyFactory
 * @notice Factory (CREATE2) to deploy Octant v2 YDS pairs for:
 *         - Spark Savings Vaults V2 (ERC-4626)
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
 *
 * @dev Factory keeps runtime intentionally lean so the bytecode stays below the EIP-170 limit.
 */
contract SparkSavingsStrategyFactory is Ownable {
    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a new Spark Savings pair is deployed.
    /// @param strategy       Deployed SparkSavingsDonationStrategy address.
    /// @param tokenized      Deployed YieldDonatingTokenizedStrategy address.
    /// @param asset          Underlying ERC-20 handled by the strategy.
    /// @param sparkVault     Spark Savings Vault V2 used as yield source.
    /// @param name           Human-readable strategy name.
    /// @param referral       Spark referral code (0 if disabled).
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

    /*//////////////////////////////////////////////////////////////
                        STORAGE & CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Precomputed hash of the YieldDonatingTokenizedStrategy creation code.
    bytes32 internal constant YDS_CREATION_HASH = keccak256(type(YieldDonatingTokenizedStrategy).creationCode);

    /// @notice Mapping of deployed savings strategies keyed by underlying asset and Spark vault.
    mapping(address asset => mapping(address sparkVault => address strategy)) private _savingsStrategies;

    /// @param _initialOwner Address that will own the factory (recommend a multisig).
    constructor(address _initialOwner) Ownable(_initialOwner) { }

    /*//////////////////////////////////////////////////////////////
                    SAVINGS (ERC-4626) DEPLOY & PREDICT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploy a complete Octant v2 YDS pair using CREATE2 (deterministic addresses).
     * @dev Constructors of both contracts WILL run. Addresses depend on salt+init code hash.
     *
     * @param _sparkVault      Spark Savings Vault V2 (ERC-4626) address (e.g., spUSDC).
     * @param _asset           Underlying token accepted by the vault (must equal ISparkVault(sparkVault).asset()).
     * @param _name            Strategy name (forwarded to BaseStrategy).
     * @param _management      Management role address.
     * @param _keeper          Keeper role address.
     * @param _emergencyAdmin  Emergency admin role address.
     * @param _donationAddress Donation sink (dragon router) for TokenizedStrategy.
     * @param _enableBurning   If true, losses first burn donation shares (dragon) before affecting PPS.
     * @param _referral        Spark referral code (0 to disable).
     *
     * @return strategy  The deployed SparkSavingsDonationStrategy.
     * @return tokenized The deployed YieldDonatingTokenizedStrategy.
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
        require(_savingsStrategies[_asset][_sparkVault] == address(0), Errors.AlreadyDeployed());

        bytes memory ydsBytecode = type(YieldDonatingTokenizedStrategy).creationCode;
        bytes32 saltT = _saltTokenizedSavings(_sparkVault, _asset, _name, _referral);
        tokenized = Create2.deploy(0, saltT, ydsBytecode);

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
        bytes32 saltS = _saltStrategySavings(_sparkVault, _asset, _name, _referral);
        strategy = Create2.deploy(0, saltS, stratBytecode);

        _savingsStrategies[_asset][_sparkVault] = strategy;

        emit RegisteredSparkSavingsStrategy(strategy, tokenized, _asset, _sparkVault, _name, _referral, _enableBurning);
    }

    /**
     * @notice Predict CREATE2 addresses for the YDS pair given the exact constructor inputs.
     * @dev You MUST pass the *same* parameters here as you will to `deploySavingsPair(...)` to get identical
     * predictions.
     *
     * @param _sparkVault      Spark Savings Vault V2 (ERC-4626).
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
     * @return strategyPred  Predicted SparkSavingsDonationStrategy address.
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
        bytes32 saltT = _saltTokenizedSavings(_sparkVault, _asset, _name, _referral);
        tokenizedPred = Create2.computeAddress(saltT, YDS_CREATION_HASH, address(this));

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
                tokenizedPred,
                _referral
            )
        );
        bytes32 saltS = _saltStrategySavings(_sparkVault, _asset, _name, _referral);
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
        return _savingsStrategies[_asset][_vault];
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Deterministic salt for the TokenizedStrategy (savings variant).
    /// @param _vault Spark Savings Vault V2 (ERC-4626) address.
    /// @param _asset Underlying token accepted by the vault.
    /// @param _name Strategy name.
    /// @param _referral Spark referral code (0 to disable).
    /// @return bytes32 The deterministic salt.
    function _saltTokenizedSavings(address _vault, address _asset, string calldata _name, uint16 _referral)
        internal
        pure
        returns (bytes32)
    {
        bytes32 nameHash = keccak256(bytes(_name));
        return keccak256(abi.encode(_vault, _asset, nameHash, _referral, bytes2("SV"), bytes1("T")));
    }

    /// @dev Deterministic salt for the Strategy (savings variant).
    /// @param _vault Spark Savings Vault V2 (ERC-4626) address.
    /// @param _asset Underlying token accepted by the vault.
    /// @param _name Strategy name.
    /// @param _referral Spark referral code (0 to disable).
    /// @return bytes32 The deterministic salt.
    function _saltStrategySavings(address _vault, address _asset, string calldata _name, uint16 _referral)
        internal
        pure
        returns (bytes32)
    {
        bytes32 nameHash = keccak256(bytes(_name));
        return keccak256(abi.encode(_vault, _asset, nameHash, _referral, bytes2("SV"), bytes1("S")));
    }
}

