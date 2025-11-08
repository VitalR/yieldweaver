# Octant v2 YDS with Spark: Savings and SparkLend

This repository includes production-ready Yield Donating Strategies (YDS) for integrating Spark:

- Spark Savings Vaults V2 via `SparkSavingsDonationStrategy`
- SparkLend (Aave v3-style) via `SparkLendDonationStrategy`

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

## Scripts

- Unified deploy (`STRAT_KIND=SAVINGS|LEND`): `script/spark/DeploySparkYDS.s.sol`
- Savings YDS flow: `script/spark/RunSparkYDSMainFlow.s.sol`
- SparkLend YDS flow: `script/spark/RunSparkLendYDSMainFlow.s.sol`

## Makefile shortcuts

- `make deploy-spark` – deploy Spark Savings YDS pair (defaults to `STRAT_KIND=SAVINGS`)
- `make deploy-spark-lend` – deploy SparkLend YDS pair (`STRAT_KIND=LEND`)
- `make spark-flow-deposit` / `make spark-flow-status` – run Savings flow helpers
- `make spark-lend-flow-deposit` / `make spark-lend-flow-status` – run SparkLend flow helpers

## Env (examples)

Savings:

- `SPARK_VAULT` – Spark Savings Vault (e.g. sUSDS)
- `UNDERLYING` – asset (e.g. USDS)
- Optional overrides: `NAME_SAVINGS`, `FACTORY_SAVINGS`
- Roles: `MANAGEMENT`, `KEEPER`, `EMERGENCY_ADMIN`, `DONATION`

SparkLend:

- `SPARK_POOL` – SparkLend `IPool`
- `SPARK_ATOKEN` (fallback `ATOKEN`) – reserve aToken (e.g. spUSDS)
- `UNDERLYING_LEND` (fallback `UNDERLYING`) – asset backing the reserve (e.g. USDS)
- Optional overrides: `NAME_LEND`, `FACTORY_LEND`, `STRATEGY_LEND`, `TOKENIZED_LEND`
- Roles: `MANAGEMENT`, `KEEPER`, `EMERGENCY_ADMIN`, `DONATION`
- Flow helpers auto-set `DO_APPROVE=true` on deposits

## Keeper Notes

- Savings strategy exposes `pokeDrip()` (management) to optionally call `vault.drip()` in deployments where explicit accrual is required.
- Both strategies implement `tend()` for batching idle deployment above a threshold.

## Testing

- Savings tests: `test/spark/SparkSavingsDonationStrategy.t.sol`
- SparkLend tests: `test/spark/SparkLendDonationStrategy.t.sol`

## Reports

- Deployment reports are emitted to `reports/spark-yds/deployment-<chain>-<block>.json`
- Flow runs create `reports/spark-yds/run-<chain>-<block>.json`; keep only runs needed for debugging or demos before committing
