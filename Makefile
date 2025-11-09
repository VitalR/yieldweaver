SHELL := /bin/bash

.PHONY: help build \
	check-env-deploy-savings check-env-deploy-lend check-env-deploy-multi \
	check-env-flow-savings check-env-flow-lend check-env-flow-multi \
	deploy-spark deploy-spark-lend deploy-spark-multi \
	spark-flow-deposit \
	spark-flow-tend \
	spark-flow-report \
	spark-flow-withdraw-all \
	spark-flow-withdraw-amount \
	spark-flow-status \
	spark-lend-flow-deposit \
	spark-lend-flow-tend \
	spark-lend-flow-report \
	spark-lend-flow-withdraw-all \
	spark-lend-flow-withdraw-amount \
	spark-lend-flow-status \
	spark-multi-flow-deposit \
	spark-multi-flow-rebalance \
	spark-multi-flow-withdraw-all \
	spark-multi-flow-withdraw-amount \
	spark-multi-flow-set-targets \
	spark-multi-flow-set-queue \
	spark-multi-flow-status \
	test test-test test-contract

# ------------- Common Config -------------

-include .env

RPC_URL        			?= $(ETH_RPC_URL)
DEPLOY_SCRIPT_SAVINGS  	:= script/spark/savings/DeploySparkSavingsYDS.s.sol:DeploySparkSavingsYDSScript
DEPLOY_SCRIPT_LEND     	:= script/spark/lend/DeploySparkLendYDS.s.sol:DeploySparkLendYDSScript
DEPLOY_SCRIPT_MULTI    	:= script/spark/multistrategy/DeploySparkMultiStrategyVault.s.sol:DeploySparkMultiStrategyVaultScript
FLOW_SCRIPT_SAVINGS    	:= script/spark/savings/RunSparkSavingsYDSMainFlow.s.sol:RunSparkSavingsYDSMainFlowScript
FLOW_SCRIPT_LEND       	:= script/spark/lend/RunSparkLendYDSMainFlow.s.sol:RunSparkLendYDSMainFlowScript
FLOW_SCRIPT_MULTI      	:= script/spark/multistrategy/RunSparkMultiStrategyVaultFlow.s.sol:RunSparkMultiStrategyVaultFlowScript

REQUIRED_DEPLOY_SAVINGS := DEPLOYER_PRIVATE_KEY SPARK_VAULT MANAGEMENT KEEPER EMERGENCY_ADMIN DONATION
REQUIRED_DEPLOY_LEND    := DEPLOYER_PRIVATE_KEY SPARK_POOL MANAGEMENT KEEPER EMERGENCY_ADMIN DONATION
REQUIRED_FLOW_SAVINGS   := DEPLOYER_PRIVATE_KEY STRATEGY TOKENIZED SPARK_VAULT UNDERLYING NAME
REQUIRED_FLOW_LEND      := DEPLOYER_PRIVATE_KEY
REQUIRED_DEPLOY_MULTI   := DEPLOYER_PRIVATE_KEY UNDERLYING
REQUIRED_FLOW_MULTI     := DEPLOYER_PRIVATE_KEY

# ------------- Meta: help -------------

help:
	@echo "--------------------------------------"
	@echo "Spark YDS workflows"
	@echo "--------------------------------------"
	@echo "make deploy-spark              # Deploy factory + pair"
	@echo "make spark-flow-deposit        # Approve + deposit (no auto tend)"
	@echo "make spark-flow-tend           # Tend-only maintenance"
	@echo "make spark-flow-report         # Report-only harvest"
	@echo "make spark-flow-withdraw-all   # Withdraw entire available limit"
	@echo "make spark-flow-withdraw-amount WITHDRAW_ASSETS=100000000  # Withdraw fixed amount"
	@echo "make spark-flow-status         # Inspect user shares/assets & strategy totals"
	@echo "--------------------------------------"
	@echo "make deploy-spark-lend         # Deploy SparkLend strategy pair"
	@echo "make spark-lend-flow-deposit   # SparkLend deposit flow"
	@echo "make spark-lend-flow-withdraw-all  # SparkLend withdraw max"
	@echo "make spark-lend-flow-status    # SparkLend inspect/status"
	@echo "--------------------------------------"
	@echo "make deploy-spark-multi        # Deploy Spark multi-strategy vault"
	@echo "make spark-multi-flow-deposit  # Multi vault deposit + auto rebalance"
	@echo "make spark-multi-flow-rebalance  # Manual rebalance with no deposit"
	@echo "make spark-multi-flow-set-targets  # Update targets using NEW_TARGET_BPS_* env vars"
	@echo "make spark-multi-flow-set-queue   # Update withdrawal queue via NEW_QUEUE_* env vars"
	@echo "make spark-multi-flow-status   # Inspect multi vault state without tx"

# ------------- Build, Test, Clean, Format -------------

build :; forge build
test :; forge test -vvv
test-test :; forge test -vvv --match-test $(test)
test-contract :; forge test -vvv --match-contract $(contract)
clean :; forge clean
clean-build :; forge clean && forge build
fmt :; forge fmt

coverage :; forge coverage --exclude-tests
coverage-lcov:
	@forge coverage --report lcov
	@lcov --remove lcov.info \
		"src/interfaces/*" \
		"test/*" \
		"script/*" \
		--output-file lcov-filtered.info --rc lcov_branch_coverage=1
	@genhtml lcov-filtered.info --branch-coverage --output-directory out/coverage
	@open out/coverage/index.html || echo "Not macOS? Open manually or run: make coverage"

# ------------- Helpers -------------

check-env-deploy-savings:
	@set -a; [ -f .env ] && . ./.env; set +a; \
	for var in $(REQUIRED_DEPLOY_SAVINGS); do \
		if [ -z "$$${!var}" ]; then echo "Missing env: $$var"; exit 1; fi; \
	done

check-env-deploy-lend:
	@set -a; [ -f .env ] && . ./.env; set +a; \
	missing=""; \
	for var in $(REQUIRED_DEPLOY_LEND); do \
		if [ -z "$$${!var}" ]; then missing="$$missing $$var"; fi; \
	done; \
	if [ -z "$$SPARK_ATOKEN" ] && [ -z "$$ATOKEN" ]; then missing="$$missing SPARK_ATOKEN|ATOKEN"; fi; \
	if [ -z "$$UNDERLYING_LEND" ] && [ -z "$$UNDERLYING" ]; then missing="$$missing UNDERLYING_LEND|UNDERLYING"; fi; \
	if [ -n "$$missing" ]; then echo "Missing env:$$missing"; exit 1; fi

check-env-deploy-multi:
	@set -a; [ -f .env ] && . ./.env; set +a; \
	missing=""; \
	for var in $(REQUIRED_DEPLOY_MULTI); do \
		if [ -z "$$${!var}" ]; then missing="$$missing $$var"; fi; \
	done; \
	if [ -z "$$STRATEGY_SAVINGS" ] && [ -z "$$STRATEGY_0" ]; then missing="$$missing STRATEGY_SAVINGS|STRATEGY_0"; fi; \
	if [ -z "$$STRATEGY_LEND" ] && [ -z "$$STRATEGY_1" ]; then missing="$$missing STRATEGY_LEND|STRATEGY_1"; fi; \
	if [ -z "$$TARGET_BPS_SAVINGS" ] && [ -z "$$TARGET_BPS_0" ]; then missing="$$missing TARGET_BPS_SAVINGS|TARGET_BPS_0"; fi; \
	if [ -z "$$TARGET_BPS_LEND" ] && [ -z "$$TARGET_BPS_1" ]; then missing="$$missing TARGET_BPS_LEND|TARGET_BPS_1"; fi; \
	if [ -n "$$missing" ]; then echo "Missing env:$$missing"; exit 1; fi

check-env-flow-savings:
	@set -a; [ -f .env ] && . ./.env; set +a; \
	for var in $(REQUIRED_FLOW_SAVINGS); do \
		if [ -z "$$${!var}" ]; then echo "Missing env: $$var"; exit 1; fi; \
	 done

check-env-flow-lend:
	@set -a; [ -f .env ] && . ./.env; set +a; \
	missing=""; \
	for var in $(REQUIRED_FLOW_LEND); do \
		if [ -z "$$${!var}" ]; then missing="$$missing $$var"; fi; \
	done; \
	if [ -z "$$STRATEGY_LEND" ] && [ -z "$$STRATEGY" ]; then missing="$$missing STRATEGY_LEND|STRATEGY"; fi; \
	if [ -z "$$TOKENIZED_LEND" ] && [ -z "$$TOKENIZED" ]; then missing="$$missing TOKENIZED_LEND|TOKENIZED"; fi; \
	if [ -z "$$SPARK_ATOKEN" ] && [ -z "$$ATOKEN" ]; then missing="$$missing SPARK_ATOKEN|ATOKEN"; fi; \
	if [ -z "$$UNDERLYING_LEND" ] && [ -z "$$UNDERLYING" ]; then missing="$$missing UNDERLYING_LEND|UNDERLYING"; fi; \
	if [ -z "$$NAME_LEND" ] && [ -z "$$NAME" ]; then missing="$$missing NAME_LEND|NAME"; fi; \
	if [ -n "$$missing" ]; then echo "Missing env:$$missing"; exit 1; fi

check-env-flow-multi:
	@set -a; [ -f .env ] && . ./.env; set +a; \
	missing=""; \
	for var in $(REQUIRED_FLOW_MULTI); do \
		if [ -z "$$${!var}" ]; then missing="$$missing $$var"; fi; \
	done; \
	if [ -z "$$MULTI_VAULT" ] && [ -z "$$VAULT" ]; then missing="$$missing MULTI_VAULT|VAULT"; fi; \
	if [ -n "$$missing" ]; then echo "Missing env:$$missing"; exit 1; fi

# ------------- Deploy, Flow Savings -------------

deploy-spark: check-env-deploy-savings
	@echo "Deploying Spark Savings YDS (RPC: $(RPC_URL))"
	@set -a; [ -f .env ] && . ./.env; set +a; \
	forge script $(DEPLOY_SCRIPT_SAVINGS) \
		--rpc-url $(RPC_URL) \
		--private-key $${DEPLOYER_PRIVATE_KEY} \
		--broadcast -vvvv

spark-flow-deposit: check-env-flow-savings
	@echo "Running Spark flow: deposit"
	@set -a; [ -f .env ] && . ./.env; set +a; \
	export DO_APPROVE=true DO_DEPOSIT=true DO_TEND=false DO_WITHDRAW=false; \
	forge script $(FLOW_SCRIPT_SAVINGS) \
		--rpc-url $(RPC_URL) \
		--private-key $${DEPLOYER_PRIVATE_KEY} \
		--broadcast -vvvv

spark-flow-tend: check-env-flow-savings
	@echo "Running Spark flow: tend only"
	@set -a; [ -f .env ] && . ./.env; set +a; \
	export DO_DEPOSIT=false DO_TEND=true DO_WITHDRAW=false DO_APPROVE=false; \
	forge script $(FLOW_SCRIPT_SAVINGS) \
		--rpc-url $(RPC_URL) \
		--private-key $${DEPLOYER_PRIVATE_KEY} \
		--broadcast -vvvv

spark-flow-report: check-env-flow-savings
	@echo "Running Spark flow: report only"
	@set -a; [ -f .env ] && . ./.env; set +a; \
	export DO_DEPOSIT=false DO_TEND=false DO_REPORT=true DO_WITHDRAW=false DO_APPROVE=false; \
	forge script $(FLOW_SCRIPT_SAVINGS) \
		--rpc-url $(RPC_URL) \
		--private-key $${DEPLOYER_PRIVATE_KEY} \
		--broadcast -vvvv

spark-flow-withdraw-all: check-env-flow-savings
	@echo "Running Spark flow: withdraw all"
	@set -a; [ -f .env ] && . ./.env; set +a; \
	export DO_DEPOSIT=false DO_TEND=false DO_REPORT=false DO_APPROVE=false DO_WITHDRAW=true WITHDRAW_ALL=true; \
	forge script $(FLOW_SCRIPT_SAVINGS) \
		--rpc-url $(RPC_URL) \
		--private-key $${DEPLOYER_PRIVATE_KEY} \
		--broadcast -vvvv

# WITHDRAW_ASSETS=50000000 make spark-flow-withdraw-amount
spark-flow-withdraw-amount: check-env-flow-savings
	@if [ -z "$(WITHDRAW_ASSETS)" ]; then echo "Usage: WITHDRAW_ASSETS=<amount> make $@"; exit 1; fi
	@echo "Running Spark flow: withdraw $(WITHDRAW_ASSETS)"
	@set -a; [ -f .env ] && . ./.env; set +a; \
	export DO_DEPOSIT=false DO_TEND=false DO_REPORT=false DO_APPROVE=false DO_WITHDRAW=true WITHDRAW_ALL=false WITHDRAW_ASSETS=$(WITHDRAW_ASSETS); \
	forge script $(FLOW_SCRIPT_SAVINGS) \
		--rpc-url $(RPC_URL) \
		--private-key $${DEPLOYER_PRIVATE_KEY} \
		--broadcast -vvvv

spark-flow-status: check-env-flow-savings
	@echo "Running Spark flow: status"
	@set -a; [ -f .env ] && . ./.env; set +a; \
	export DO_DEPOSIT=false DO_TEND=false DO_REPORT=false DO_WITHDRAW=false DO_APPROVE=false DO_INSPECT=true; \
	forge script $(FLOW_SCRIPT_SAVINGS) \
		--rpc-url $(RPC_URL) \
		--private-key $${DEPLOYER_PRIVATE_KEY} \
		-vvv

# ------------- Deploy, Flow Lend -------------

deploy-spark-lend: check-env-deploy-lend
	@echo "Deploying Spark Lend YDS (RPC: $(RPC_URL))"
	@set -a; [ -f .env ] && . ./.env; set +a; \
	forge script $(DEPLOY_SCRIPT_LEND) \
		--rpc-url $(RPC_URL) \
		--private-key $${DEPLOYER_PRIVATE_KEY} \
		--broadcast -vvvv

spark-lend-flow-deposit: check-env-flow-lend
	@echo "Running SparkLend flow: deposit"
	@set -a; [ -f .env ] && . ./.env; set +a; \
	export DO_APPROVE=true DO_DEPOSIT=true DO_TEND=false DO_WITHDRAW=false; \
	forge script $(FLOW_SCRIPT_LEND) \
		--rpc-url $(RPC_URL) \
		--private-key $${DEPLOYER_PRIVATE_KEY} \
		--broadcast -vvvv

spark-lend-flow-tend: check-env-flow-lend
	@echo "Running SparkLend flow: tend only"
	@set -a; [ -f .env ] && . ./.env; set +a; \
	export DO_DEPOSIT=false DO_TEND=true DO_WITHDRAW=false DO_APPROVE=false; \
	forge script $(FLOW_SCRIPT_LEND) \
		--rpc-url $(RPC_URL) \
		--private-key $${DEPLOYER_PRIVATE_KEY} \
		--broadcast -vvvv

spark-lend-flow-report: check-env-flow-lend
	@echo "Running SparkLend flow: report only"
	@set -a; [ -f .env ] && . ./.env; set +a; \
	export DO_DEPOSIT=false DO_TEND=false DO_REPORT=true DO_WITHDRAW=false DO_APPROVE=false; \
	forge script $(FLOW_SCRIPT_LEND) \
		--rpc-url $(RPC_URL) \
		--private-key $${DEPLOYER_PRIVATE_KEY} \
		--broadcast -vvvv

spark-lend-flow-withdraw-all: check-env-flow-lend
	@echo "Running SparkLend flow: withdraw all"
	@set -a; [ -f .env ] && . ./.env; set +a; \
	export DO_DEPOSIT=false DO_TEND=false DO_REPORT=false DO_APPROVE=false DO_WITHDRAW=true WITHDRAW_ALL=true; \
	forge script $(FLOW_SCRIPT_LEND) \
		--rpc-url $(RPC_URL) \
		--private-key $${DEPLOYER_PRIVATE_KEY} \
		--broadcast -vvvv

spark-lend-flow-withdraw-amount: check-env-flow-lend
	@if [ -z "$(WITHDRAW_ASSETS)" ]; then echo "Usage: WITHDRAW_ASSETS=<amount> make $@"; exit 1; fi
	@echo "Running SparkLend flow: withdraw $(WITHDRAW_ASSETS)"
	@set -a; [ -f .env ] && . ./.env; set +a; \
	export DO_DEPOSIT=false DO_TEND=false DO_REPORT=false DO_APPROVE=false DO_WITHDRAW=true WITHDRAW_ALL=false WITHDRAW_ASSETS=$(WITHDRAW_ASSETS); \
	forge script $(FLOW_SCRIPT_LEND) \
		--rpc-url $(RPC_URL) \
		--private-key $${DEPLOYER_PRIVATE_KEY} \
		--broadcast -vvvv

spark-lend-flow-status: check-env-flow-lend
	@echo "Running SparkLend flow: status"
	@set -a; [ -f .env ] && . ./.env; set +a; \
	export DO_DEPOSIT=false DO_TEND=false DO_REPORT=false DO_WITHDRAW=false DO_APPROVE=false DO_INSPECT=true; \
	forge script $(FLOW_SCRIPT_LEND) \
		--rpc-url $(RPC_URL) \
		--private-key $${DEPLOYER_PRIVATE_KEY} \
		-vvv

# ------------- Deploy, Flow Multi Strategy -------------

deploy-spark-multi: check-env-deploy-multi
	@echo "Deploying Spark Multi Strategy Vault (RPC: $(RPC_URL))"
	@set -a; [ -f .env ] && . ./.env; set +a; \
	forge script $(DEPLOY_SCRIPT_MULTI) \
		--rpc-url $(RPC_URL) \
		--private-key $${DEPLOYER_PRIVATE_KEY} \
		--slow --broadcast -vvvv

spark-multi-flow-deposit: check-env-flow-multi
	@echo "Running Spark multi vault flow: deposit"
	@set -a; [ -f .env ] && . ./.env; set +a; \
	export DO_APPROVE=true DO_DEPOSIT=true DO_WITHDRAW=false DO_REDEEM=false DO_REBALANCE=false; \
	forge script $(FLOW_SCRIPT_MULTI) \
		--rpc-url $(RPC_URL) \
		--private-key $${DEPLOYER_PRIVATE_KEY} \
		--broadcast -vvvv

spark-multi-flow-rebalance: check-env-flow-multi
	@echo "Running Spark multi vault flow: manual rebalance"
	@set -a; [ -f .env ] && . ./.env; set +a; \
	export DO_APPROVE=false DO_DEPOSIT=false DO_WITHDRAW=false DO_REDEEM=false DO_REBALANCE=true; \
	forge script $(FLOW_SCRIPT_MULTI) \
		--rpc-url $(RPC_URL) \
		--private-key $${DEPLOYER_PRIVATE_KEY} \
		--broadcast -vvvv

spark-multi-flow-withdraw-all: check-env-flow-multi
	@echo "Running Spark multi vault flow: withdraw all"
	@set -a; [ -f .env ] && . ./.env; set +a; \
	export DO_APPROVE=false DO_DEPOSIT=false DO_REDEEM=false DO_REBALANCE=false DO_WITHDRAW=true WITHDRAW_ALL=true; \
	forge script $(FLOW_SCRIPT_MULTI) \
		--rpc-url $(RPC_URL) \
		--private-key $${DEPLOYER_PRIVATE_KEY} \
		--broadcast -vvvv

spark-multi-flow-withdraw-amount: check-env-flow-multi
	@if [ -z "$(WITHDRAW_ASSETS)" ]; then echo "Usage: WITHDRAW_ASSETS=<amount> make $@"; exit 1; fi
	@echo "Running Spark multi vault flow: withdraw $(WITHDRAW_ASSETS)"
	@set -a; [ -f .env ] && . ./.env; set +a; \
	export DO_APPROVE=false DO_DEPOSIT=false DO_REDEEM=false DO_REBALANCE=false DO_WITHDRAW=true WITHDRAW_ALL=false WITHDRAW_ASSETS=$(WITHDRAW_ASSETS); \
	forge script $(FLOW_SCRIPT_MULTI) \
		--rpc-url $(RPC_URL) \
		--private-key $${DEPLOYER_PRIVATE_KEY} \
		--broadcast -vvvv

spark-multi-flow-set-targets: check-env-flow-multi
	@echo "Running Spark multi vault flow: set targets"
	@set -a; [ -f .env ] && . ./.env; set +a; \
	export DO_APPROVE=false DO_DEPOSIT=false DO_WITHDRAW=false DO_REDEEM=false DO_REBALANCE=false DO_SET_TARGETS=true DO_SET_QUEUE=$${DO_SET_QUEUE:-false}; \
	forge script $(FLOW_SCRIPT_MULTI) \
		--rpc-url $(RPC_URL) \
		--private-key $${DEPLOYER_PRIVATE_KEY} \
		--broadcast -vvvv

spark-multi-flow-set-queue: check-env-flow-multi
	@echo "Running Spark multi vault flow: set withdrawal queue"
	@set -a; [ -f .env ] && . ./.env; set +a; \
	export DO_APPROVE=false DO_DEPOSIT=false DO_WITHDRAW=false DO_REDEEM=false DO_REBALANCE=false DO_SET_QUEUE=true DO_SET_TARGETS=$${DO_SET_TARGETS:-false}; \
	forge script $(FLOW_SCRIPT_MULTI) \
		--rpc-url $(RPC_URL) \
		--private-key $${DEPLOYER_PRIVATE_KEY} \
		--broadcast -vvvv

spark-multi-flow-status: check-env-flow-multi
	@echo "Running Spark multi vault flow: status"
	@set -a; [ -f .env ] && . ./.env; set +a; \
	export DO_APPROVE=false DO_DEPOSIT=false DO_WITHDRAW=false DO_REDEEM=false DO_REBALANCE=false DO_INSPECT=true; \
	forge script $(FLOW_SCRIPT_MULTI) \
		--rpc-url $(RPC_URL) \
		--private-key $${DEPLOYER_PRIVATE_KEY} \
		-vvv