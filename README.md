# YieldWeaver: Spark Multi-Strategy Vault

[![Tests](https://github.com/VitalR/yieldweaver/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/VitalR/yieldweaver/actions/workflows/test.yml) ![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg) ![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)

## Overview

Spark YieldWeaver is a production-ready, auditable integration that composes Spark’s curated yield sources into a single Octant-compatible multi-strategy vault. The system donates profits to a configured recipient while insulating depositors from losses via Spark Savings and SparkLend donation strategies. Governance controls target weights, idle buffers, and withdrawal queues to tailor allocations to different risk profiles.

This repository powers our submission for the “Best use of Spark curated yield” challenge. All logic, scripts, and tests are open source and organised for fast review by protocol judges and protocol engineers.

## Key Features

- **Multi-source Spark yield**: Combines Spark Savings V2 (Vault Savings Rate) and SparkLend (Aave v3-style pool) in a single ERC-4626 vault.
- **Octant V2 semantics**: Implements Yield Donating Strategy (YDS) flows—profits mint donation shares, losses burn them first.
- **Governance friendly**: Deterministic CREATE2 deployments, configurable weights/queue/idle buffer, and granular scripting.
- **Production-ready toolkit**: Foundry-based tests, gas-friendly struct refactors, hardened input validation, and JSON reporting.
- **USDC native**: All strategies and vaults are wired against USDC to match Spark’s curated mainnet markets.

## Architecture

```text
src/
 ├─ common/Errors.sol                # Shared custom errors
 ├─ spark/
 │   ├─ savings/                      # Spark Savings donation strategy + factory
 │   ├─ lend/                         # SparkLend donation strategy + factory
 │   └─ multistrategy/                # SparkMultiStrategyVault implementation
script/
 └─ spark/{savings,lend,multistrategy}/
     Deploy*.s.sol, Run*Flow.s.sol    # Deterministic deployment & flow scripts
reports/
 └─ spark/{savings,lend,multistrategy}/
     deployment-*.json, run-*.json    # Machine-readable execution reports
test/
 └─ spark/{savings,lend,multistrategy}/
     *.t.sol                          # Unit & integration-style tests
```

The multi-strategy vault keeps a configurable idle buffer (default 20%) and target weights (default 40% savings / 40% lend). Withdrawals follow a queue (default `[0, 1]`) to drain savings before lend. All profit/loss flows conform to Octant’s donation semantics.

## Deployments (Tenderly VNet, chainId 8)

| Component                                | Address                                      | Notes                                   |
| ---------------------------------------- | -------------------------------------------- | --------------------------------------- |
| USDC (underlying)                        | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | Mirrored mainnet USDC                   |
| Spark Savings Vault V2 (spUSDC)          | `0x28B3a8fb53B741A8Fd78c0fb9A6B2393d896a43d` | ERC-4626 backing savings strategy       |
| SparkLend Pool                           | `0xC13e21B648A5Ee794902342038FF3aDAB66BE987` | Aave v3-style pool                      |
| SparkLend aToken (aUSDC)                 | `0x377C3bd93f2a2984E1E7bE6A5C22c525eD4A4815` | Yield-bearing token                     |
| SparkSavingsDonationStrategy             | `0x01CE4023E950Da48a0167A5542D5682Ce6319a79` | Strategy proxy (delegates to tokenized) |
| YieldDonatingTokenizedStrategy (Savings) | `0x9aCd869ae6cdB07994C65BAf46a4c9b58503764E` | Donation-aware tokenized vault          |
| SparkLendDonationStrategy                | `0x28Ecb912d3176d8CEEa0a8f8eD1C023e402c2c76` | SparkLend strategy entry point          |
| YieldDonatingTokenizedStrategy (Lend)    | `0x932e29FB1D61509746777FD2F901B20B5f1EEAf7` | Donation-aware tokenized vault          |
| SparkMultiStrategyVault (msUSDC)         | `0x6ff9DFae2ca36CCd06f30Fb272bCcb2A88848568` | Fund-of-funds vault                     |

_Deployment JSONs live under `reports/spark/**/deployment-*.json` for reproducibility and auditing._

## Quick Start

### Prerequisites

- [Install Foundry and Forge](https://book.getfoundry.sh/getting-started/installation) (forge/cast/anvil)
- Access to a Tenderly VNet or matching RPC with Spark contracts

### Install & Configure

```bash
# Clone repository
git clone https://github.com/VitalR/yieldweaver.git
cd yieldweaver

# Install Foundry dependencies
forge install

# Copy env template and set values
cp .env.example .env
$EDITOR .env
# Required variables: ETH_RPC_URL, DEPLOYER_PRIVATE_KEY, SPARK_VAULT, UNDERLYING,
# SPARK_POOL, SPARK_ATOKEN, MANAGEMENT, KEEPER, EMERGENCY_ADMIN, DONATION, etc.
```

Detailed parameter explanations live in [`docs/spark/INTEGRATION.md`](docs/spark/INTEGRATION.md).

### Build, Test & Coverage

```bash
make build
make test
make coverage-lcov
```

Tests mirror the on-chain deployment layout and cover:

- Strategy configuration and guardrails (zero address, mismatched assets, access control)
- Donation semantics (minting on profit, burning on loss)
- Multi-strategy vault flows (deposit/mint/withdraw/redeem, queue order, idle buffer)
- Negative and edge cases (`vm.expectRevert`, `vm.mockCallRevert`, `vm.expectCall`)

### Deploy with CREATE2

```bash
# Spark Savings YDS (tokenized + strategy)
make deploy-spark

# SparkLend YDS (tokenized + strategy)
make deploy-spark-lend

# Multi-strategy vault (combining the addresses above)
make deploy-spark-multi
```

Deployment scripts emit structured logs and write JSON under `reports/spark/.../deployment-<chain>-<block>.json` with salts, addresses, and config.

### Operational Flows

```bash
# Inspect current user balances & totals (no transaction)
WITHDRAW_BPS=0 make spark-multi-flow-status

# Deposit and automatically rebalance (rebalance thresholds respect idle buffer)
WITHDRAW_BPS=0 make spark-multi-flow-deposit

# Manually rebalance without moving user funds
WITHDRAW_BPS=0 DO_REBALANCE=true DO_DEPOSIT=false make spark-multi-flow-rebalance

# Withdraw a fixed amount (set WITHDRAW_ASSETS)
WITHDRAW_BPS=0 WITHDRAW_ASSETS=10000000 make spark-multi-flow-withdraw-amount
```

_Important_: set `WITHDRAW_BPS=0` unless you explicitly want the flow script to auto-withdraw (default .env uses 25% for testing). All scripts produce JSON run reports under `reports/spark/.../run-*.json` capturing before/after snapshots.

## Project Organisation

| Path                       | Description                                                    |
| -------------------------- | -------------------------------------------------------------- |
| `src/spark/savings/`       | Spark Savings donation strategy and its CREATE2 factory        |
| `src/spark/lend/`          | SparkLend donation strategy and factory                        |
| `src/spark/multistrategy/` | `SparkMultiStrategyVault` implementation (Octant-lite)         |
| `script/spark/**`          | Foundry scripts for deploy & main flows (savings, lend, multi) |
| `test/spark/**`            | Comprehensive test suites mirroring `src/` layout              |
| `reports/spark/**`         | Deterministic deployment/run JSON artefacts                    |

## Security & Production Considerations

- Contracts have **not** undergone third-party auditing; deploy to production at your own risk.
- CREATE2 salts are deterministic—double-check `.env` before redeploying to avoid address clashes (factories guard `AlreadyDeployed()` per asset/pool pair).
- Deployments target a Tenderly Virtual Mainnet (chainId 8), a stateful fork of Ethereum mainnet used for deterministic testing. For mainnet, update addresses and rerun the scripts against live RPC endpoints.
- Donation recipient and role addresses are configurable through the factories; adjust before mainnet deployment.

## License

MIT © VitalR / YieldWeaver contributors
