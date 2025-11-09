# Octant v2 YDS with Spark: Savings and SparkLend

This repository includes production-ready Yield Donating Strategies (YDS) for integrating Spark’s curated yield sources:

- Spark Savings Vaults V2 via `SparkSavingsDonationStrategy`
- SparkLend (Aave v3-style) via `SparkLendDonationStrategy`
- A fixed-allocation fund-of-funds `SparkMultiStrategyVault` that combines the two donation strategies

Both strategies conform to Octant v2 YDS semantics: user principal remains flat, realized profits are minted as donation shares to the configured donation address; donation shares are burned first on loss.

## References

- Octant v2: Introduction to YDS: https://docs.v2.octant.build/docs/yield_donating_strategy/introduction-to-yds/
- Octant v2: Introduction: https://docs.v2.octant.build/docs/introduction/
- Spark Documentation Portal: https://docs.spark.fi/

## Contracts

- `src/spark/savings/SparkSavingsDonationStrategy.sol` – ERC-4626 direct-deposit adapter into Spark Savings Vaults V2
- `src/spark/lend/SparkLendDonationStrategy.sol` – Aave v3-style supply/withdraw adapter into SparkLend
- `src/spark/savings/SparkSavingsStrategyFactory.sol` – CREATE2 factory for Spark Savings YDS pairs
- `src/spark/lend/SparkLendStrategyFactory.sol` – CREATE2 factory for SparkLend YDS pairs
- `src/spark/multistrategy/SparkMultiStrategyVault.sol` – fixed-allocation ERC-4626 vault allocating across Spark Savings & SparkLend donation strategies

## Scripts

- Deploy Spark Savings YDS: `script/spark/savings/DeploySparkSavingsYDS.s.sol`
- Deploy SparkLend YDS: `script/spark/lend/DeploySparkLendYDS.s.sol`
- Savings YDS flow: `script/spark/savings/RunSparkSavingsYDSMainFlow.s.sol`
- SparkLend YDS flow: `script/spark/lend/RunSparkLendYDSMainFlow.s.sol`
- Deploy Spark multi-strategy vault: `script/spark/multistrategy/DeploySparkMultiStrategyVault.s.sol`
- Multi-strategy flow: `script/spark/multistrategy/RunSparkMultiStrategyVaultFlow.s.sol`

## Makefile shortcuts

- `make deploy-spark` – deploy Spark Savings YDS pair
- `make deploy-spark-lend` – deploy SparkLend YDS pair
- `make spark-flow-deposit` / `make spark-flow-status` – run Savings flow helpers
- `make spark-lend-flow-deposit` / `make spark-lend-flow-status` – run SparkLend flow helpers
- `make deploy-spark-multi` – deploy Spark multi-strategy vault
- `make spark-multi-flow-deposit` / `make spark-multi-flow-status` – run multi-vault flow helpers

## Env (USDC Tenderly VNet reference)

Savings:

- `SPARK_VAULT` – Spark Savings Vault (e.g. spUSDC `0x28B3…a43d`)
- `UNDERLYING` – (optional) asset override; defaults to `vault.asset()`
- Optional overrides: `NAME_SAVINGS`, `FACTORY_SAVINGS`
- Roles: `MANAGEMENT`, `KEEPER`, `EMERGENCY_ADMIN`, `DONATION`
- Post-deploy wiring: `STRATEGY_SAVINGS`, `TOKENIZED_SAVINGS`

SparkLend:

- `SPARK_POOL` – SparkLend `IPool`
- `SPARK_ATOKEN` (fallback `ATOKEN`) – reserve aToken (e.g. aUSDC `0x377C…4815`)
- `UNDERLYING_LEND` (fallback `UNDERLYING`) – asset backing the reserve (e.g. USDC)
- Optional overrides: `NAME_LEND`, `FACTORY_LEND`, `STRATEGY_LEND`, `TOKENIZED_LEND`
- Roles: `MANAGEMENT`, `KEEPER`, `EMERGENCY_ADMIN`, `DONATION`
- Flow helpers auto-set `DO_APPROVE=true` on deposits
- Post-deploy wiring: `STRATEGY_LEND`, `TOKENIZED_LEND`

Multi-strategy vault:

- `MULTI_NAME`, `MULTI_SYMBOL`, `OWNER`
- `IDLE_BPS` – idle buffer (default 1_000 = 10%)
- `STRATEGY_SAVINGS`, `STRATEGY_LEND`, plus optional `STRATEGY_<i>`
- `TARGET_BPS_SAVINGS`, `TARGET_BPS_LEND`, plus optional `TARGET_BPS_<i>` (sum with `IDLE_BPS` must equal 10_000)
- Optional withdrawal queue override: `WITHDRAW_QUEUE_<i>`
- Runtime wiring: `MULTI_VAULT`

## Keeper Notes

- Savings strategy exposes `pokeDrip()` (management) to optionally call `vault.drip()` in deployments where explicit accrual is required.
- Both strategies implement `tend()` for batching idle deployment above a threshold.

## Testing

- Savings tests: `test/spark/savings/SparkSavingsDonationStrategy.t.sol`
- SparkLend tests: `test/spark/lend/SparkLendDonationStrategy.t.sol`
- Multi-strategy tests: `test/spark/multistrategy/SparkMultiStrategyVault.t.sol`

## Reports

- Deployment reports are emitted under `reports/spark/<product>/deployment-<chain>-<block>.json`
  - Savings: `reports/spark/savings/...`
  - Lend: `reports/spark/lend/...`
  - Multi-strategy: `reports/spark/multistrategy/...`
- Flow runs create `reports/spark/<product>/run-<chain>-<block>.json`; keep only runs needed for debugging or demos before committing
- Set `WITHDRAW_BPS=0` in env files unless intentionally withdrawing during scripted flows (default templates already do this)
