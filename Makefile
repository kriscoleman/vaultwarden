# Replicated Onboarding — Local Validation
#
# Prerequisites:
#   - helm, replicated CLI, kubectl installed
#   - .envrc with: REPLICATED_APP, REPLICATED_API_TOKEN
#
# Usage:
#   make validate          # Full pipeline: deps → release → deploy → check
#   make release           # Package chart + create Replicated release
#   make deploy            # Create CMX cluster + helm install
#   make check             # Verify pods are healthy
#   make clean             # Tear down CMX cluster + customer

CHART_DIR    := charts/vaultwarden
APP          := $(REPLICATED_APP)
CHANNEL      := Unstable
CUSTOMER     := cmx-validate-$(APP)
CLUSTER_NAME := cmx-validate-$(APP)
NAMESPACE    := default
TTL          := 2h

# Derived
CHART_NAME   := $(shell grep '^name:' $(CHART_DIR)/Chart.yaml | awk '{print $$2}')
# OCI registry requires lowercase channel name
CHANNEL_LC   := $(shell echo $(CHANNEL) | tr A-Z a-z)
CHART_VER    := $(shell grep '^version:' $(CHART_DIR)/Chart.yaml | awk '{print $$2}')

.PHONY: validate release deploy check clean deps customer cluster teardown help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

validate: deps release deploy check ## Full pipeline: deps → release → deploy → check
	@echo ""
	@echo "✅ Validation complete — $(APP) is running on CMX"

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------

deps: ## Update Helm dependencies
	helm dependency update $(CHART_DIR)

release: deps ## Package chart + create Replicated release on Unstable
	@echo "📦 Packaging chart..."
	@helm package $(CHART_DIR) --destination /tmp/
	@echo "📦 Creating release on $(CHANNEL)..."
	@replicated release create \
		--app $(APP) \
		--chart /tmp/$(CHART_NAME)-$(CHART_VER).tgz \
		--promote $(CHANNEL) \
		--version $(CHART_VER) \
		|| { echo "❌ Release failed"; exit 1; }
	@rm -f /tmp/$(CHART_NAME)-$(CHART_VER).tgz
	@echo "✅ Release $(CHART_VER) promoted to $(CHANNEL)"

customer: ## Create or verify CMX validation customer
	@if replicated customer ls --app $(APP) 2>/dev/null | grep -q "$(CUSTOMER)"; then \
		echo "Customer $(CUSTOMER) already exists"; \
	else \
		echo "Creating customer $(CUSTOMER)..."; \
		replicated customer create \
			--app $(APP) \
			--name "$(CUSTOMER)" \
			--email "$(CUSTOMER)@factory.replicated.com" \
			--channel $(CHANNEL) \
			--type dev \
			--expires-in 720h; \
	fi

cluster: ## Provision CMX k3s cluster
	@if replicated cluster ls 2>/dev/null | grep -q "$(CLUSTER_NAME)"; then \
		echo "Cluster $(CLUSTER_NAME) already exists"; \
	else \
		echo "🚀 Provisioning CMX cluster ($(TTL) TTL)..."; \
		replicated cluster create \
			--name $(CLUSTER_NAME) \
			--distribution k3s \
			--version 1.32 \
			--ttl $(TTL) \
			--wait 5m; \
	fi
	@echo "Fetching kubeconfig..."
	@replicated cluster kubeconfig $$(replicated cluster ls 2>/dev/null | grep "$(CLUSTER_NAME)" | awk '{print $$1}')

deploy: customer cluster ## Deploy chart to CMX via Replicated registry
	@echo "🔐 Logging into Replicated registry..."
	@CUSTOMER_JSON=$$(replicated customer ls --app $(APP) --output json 2>/dev/null | python3 -c "import json,sys; data=json.load(sys.stdin); c=[x for x in data if x.get('name')=='$(CUSTOMER)']; print(json.dumps(c[0]) if c else '')") && \
	if [ -z "$$CUSTOMER_JSON" ]; then echo "❌ Customer $(CUSTOMER) not found"; exit 1; fi && \
	LICENSE_ID=$$(echo "$$CUSTOMER_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('installationId',''))") && \
	CUSTOMER_EMAIL=$$(echo "$$CUSTOMER_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('email',''))") && \
	echo "  Customer: $(CUSTOMER)" && \
	echo "  Email: $$CUSTOMER_EMAIL" && \
	echo "  License: $${LICENSE_ID:0:10}..." && \
	helm registry login registry.replicated.com \
		--username "$$CUSTOMER_EMAIL" \
		--password "$$LICENSE_ID" && \
	echo "📥 Installing $(CHART_NAME) from Replicated registry..." && \
	helm upgrade --install $(CHART_NAME) \
		oci://registry.replicated.com/$(APP)/$(CHANNEL_LC)/$(CHART_NAME) \
		--namespace $(NAMESPACE) \
		--wait \
		--timeout 5m \
	|| { echo "❌ Deploy failed"; exit 1; }
	@echo "✅ Deployed $(CHART_NAME) to CMX"

check: ## Verify all pods are running
	@echo "🔍 Checking pod health..."
	@kubectl get pods -n $(NAMESPACE) -o wide
	@echo ""
	@NOT_READY=$$(kubectl get pods -n $(NAMESPACE) --no-headers 2>/dev/null | grep -cv "Running\|Completed" || echo 0) && \
	if [ "$$NOT_READY" -gt 0 ]; then \
		echo "❌ $$NOT_READY pod(s) not ready"; \
		kubectl get pods -n $(NAMESPACE) --no-headers | grep -v "Running\|Completed"; \
		exit 1; \
	else \
		echo "✅ All pods healthy"; \
	fi

clean: ## Tear down CMX cluster and validation customer
	@echo "🧹 Cleaning up..."
	@CLUSTER_ID=$$(replicated cluster ls 2>/dev/null | grep "$(CLUSTER_NAME)" | awk '{print $$1}') && \
	if [ -n "$$CLUSTER_ID" ]; then \
		echo "Removing cluster $$CLUSTER_ID..."; \
		replicated cluster rm "$$CLUSTER_ID" || true; \
	fi
	@echo "Done"
