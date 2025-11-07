SHELL := /bin/bash

.PHONY: help build check-env-deploy check-env-flow \
	deploy-spark \
	spark-flow-deposit \
	spark-flow-tend \
	spark-flow-report \
	spark-flow-withdraw-all \
	spark-flow-withdraw-amount \
	spark-flow-status

# ------------- Common Config -------------

-include .env

RPC_URL        ?= $(ETH_RPC_URL)
DEPLOY_SCRIPT  := script/spark/DeploySparkYDS.s.sol:DeploySparkYDSScript
FLOW_SCRIPT    := script/spark/RunSparkYDSMainFlow.s.sol:RunSparkYDSMainFlowScript

REQUIRED_DEPLOY := DEPLOYER_PRIVATE_KEY SPARK_VAULT UNDERLYING NAME MANAGEMENT KEEPER EMERGENCY_ADMIN DONATION
REQUIRED_FLOW   := DEPLOYER_PRIVATE_KEY STRATEGY TOKENIZED SPARK_VAULT UNDERLYING NAME

# ------------- Meta: help -------------

help:
	@echo "Spark YDS workflows"
	@echo "--------------------"
	@echo "make deploy-spark             # Deploy factory + pair"
	@echo "make spark-flow-deposit       # Approve + deposit (no auto tend)"
	@echo "make spark-flow-tend          # Tend-only maintenance"
	@echo "make spark-flow-report        # Report-only harvest"
	@echo "make spark-flow-withdraw-all  # Withdraw entire available limit"
	@echo "make spark-flow-withdraw-amount WITHDRAW_ASSETS=100000000  # Withdraw fixed amount"
	@echo "make spark-flow-status        # Inspect user shares/assets & strategy totals"

# ------------- Build, Test, Clean, Format -------------

build :; forge build
test :; forge test -vvv
test-test :; forge test -vvv --match-test $(TEST) -vvv
test-contract :; forge test -vvv --match-contract $(CONTRACT) -vvv
clean :; forge clean
fmt :; forge fmt

# ------------- Helpers -------------

check-env-deploy:
	@set -a; [ -f .env ] && . ./.env; set +a; \
	for var in $(REQUIRED_DEPLOY); do \
		if [ -z "$$${!var}" ]; then echo "Missing env: $$var"; exit 1; fi; \
	 done

check-env-flow:
	@set -a; [ -f .env ] && . ./.env; set +a; \
	for var in $(REQUIRED_FLOW); do \
		if [ -z "$$${!var}" ]; then echo "Missing env: $$var"; exit 1; fi; \
	 done

# ------------- Deploy, Flow -------------

deploy-spark: check-env-deploy
	@echo "Deploying Spark YDS (RPC: $(RPC_URL))"
	@set -a; [ -f .env ] && . ./.env; set +a; \
	forge script $(DEPLOY_SCRIPT) \
		--rpc-url $(RPC_URL) \
		--private-key $${DEPLOYER_PRIVATE_KEY} \
		--broadcast -vvvv

spark-flow-deposit: check-env-flow
	@echo "Running Spark flow: deposit"
	@set -a; [ -f .env ] && . ./.env; set +a; \
	export DO_DEPOSIT=true DO_TEND=false DO_WITHDRAW=false; \
	forge script $(FLOW_SCRIPT) \
		--rpc-url $(RPC_URL) \
		--private-key $${DEPLOYER_PRIVATE_KEY} \
		--broadcast -vvvv

spark-flow-tend: check-env-flow
	@echo "Running Spark flow: tend only"
	@set -a; [ -f .env ] && . ./.env; set +a; \
	export DO_DEPOSIT=false DO_TEND=true DO_WITHDRAW=false DO_APPROVE=false; \
	forge script $(FLOW_SCRIPT) \
		--rpc-url $(RPC_URL) \
		--private-key $${DEPLOYER_PRIVATE_KEY} \
		--broadcast -vvvv

spark-flow-report: check-env-flow
	@echo "Running Spark flow: report only"
	@set -a; [ -f .env ] && . ./.env; set +a; \
	export DO_DEPOSIT=false DO_TEND=false DO_REPORT=true DO_WITHDRAW=false DO_APPROVE=false; \
	forge script $(FLOW_SCRIPT) \
		--rpc-url $(RPC_URL) \
		--private-key $${DEPLOYER_PRIVATE_KEY} \
		--broadcast -vvvv

spark-flow-withdraw-all: check-env-flow
	@echo "Running Spark flow: withdraw all"
	@set -a; [ -f .env ] && . ./.env; set +a; \
	export DO_DEPOSIT=false DO_TEND=false DO_REPORT=false DO_APPROVE=false DO_WITHDRAW=true WITHDRAW_ALL=true; \
	forge script $(FLOW_SCRIPT) \
		--rpc-url $(RPC_URL) \
		--private-key $${DEPLOYER_PRIVATE_KEY} \
		--broadcast -vvvv

# WITHDRAW_ASSETS=50000000 make spark-flow-withdraw-amount
spark-flow-withdraw-amount: check-env-flow
	@if [ -z "$(WITHDRAW_ASSETS)" ]; then echo "Usage: WITHDRAW_ASSETS=<amount> make $@"; exit 1; fi
	@echo "Running Spark flow: withdraw $(WITHDRAW_ASSETS)"
	@set -a; [ -f .env ] && . ./.env; set +a; \
	export DO_DEPOSIT=false DO_TEND=false DO_REPORT=false DO_APPROVE=false DO_WITHDRAW=true WITHDRAW_ALL=false WITHDRAW_ASSETS=$(WITHDRAW_ASSETS); \
	forge script $(FLOW_SCRIPT) \
		--rpc-url $(RPC_URL) \
		--private-key $${DEPLOYER_PRIVATE_KEY} \
		--broadcast -vvvv

spark-flow-status: check-env-flow
	@echo "Running Spark flow: status"
	@set -a; [ -f .env ] && . ./.env; set +a; \
	export DO_DEPOSIT=false DO_TEND=false DO_REPORT=false DO_WITHDRAW=false DO_APPROVE=false DO_INSPECT=true; \
	forge script $(FLOW_SCRIPT) \
		--rpc-url $(RPC_URL) \
		--private-key $${DEPLOYER_PRIVATE_KEY} \
		-vvv
