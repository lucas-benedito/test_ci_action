# operator.mk — AAP Gateway Operator specific targets and variables
#
# This file is NOT synced across repos. Each operator maintains its own.

##@ Operator Variables

VERSION ?= 0.0.1
IMAGE_TAG_BASE ?= quay.io/aap/aap-gateway-operator
NAMESPACE ?= aap
DEPLOYMENT_NAME ?= aap-gateway-operator-controller-manager

# Deployment method: bundle (default) or catalog
DEPLOY_METHOD ?= bundle

# Bundle configuration
BUNDLE_VERSION ?= devel
# Override to skip Konflux bundle resolution (e.g. DEV_BUNDLE_IMG=quay.io/...@sha256:xxx)
DEV_BUNDLE_IMG ?=
CATALOG_SOURCE ?= aap-cloud-index-27-next
CATALOG_SOURCE_NAMESPACE ?= openshift-marketplace

# Dev CR to apply after deployment
DEV_CR ?= dev/aap-cr/aap-fresh-install.yml

# Feature flags
BUILD_IMAGE ?= true
BUILD_IMAGE_SKIP_CI ?= false
CREATE_AAP ?= true
CREATE_SECRETS ?= false
CREATE_REGISTRY_CONFIG ?= false
CREATE_ICSP ?= false

# OLM cleanup flags
CLEAN_ALL ?= true
CLEAN_CATALOG ?= false
CLEAN_CSV ?= false
CLEAN_SUB ?= false

# Konflux API configuration
KONFLUX_API ?= https://api.stone-prod-p02.hjvn.p1.openshiftapps.com:6443
KONFLUX_NAMESPACE ?= ansible-tenant

# Bundle cache URL (internal GitLab)
GITLAB_BUNDLE_URL ?= https://gitlab.cee.redhat.com/aknochow/minc-aap/-/raw/bundles

# OCP version (auto-detected from cluster)
OCP_VERSION ?= $(shell $(KUBECTL) version -o json 2>/dev/null | \
	jq -r '.serverVersion.minor' 2>/dev/null | tr -d '+' | \
	awk '{if ($$0 ~ /^[0-9]+$$/) print "4." ($$0 - 13); else print "4.17"}')

##@ Gateway Operator

.PHONY: operator-up
operator-up: _olm-cleanup _olm-deploy _operator-build-and-inject _operator-post-deploy ## Gateway-specific deploy

.PHONY: operator-down
operator-down: ## Gateway-specific undeploy
	@echo "=== Cleaning up gateway operator resources ==="
	@# Delete restores
	-$(KUBECTL) delete ansibleautomationplatformrestore -n $(NAMESPACE) --all --ignore-not-found=true
	-$(KUBECTL) delete edarestore -n $(NAMESPACE) --all --ignore-not-found=true
	-$(KUBECTL) delete automationcontrollerrestore -n $(NAMESPACE) --all --ignore-not-found=true
	-$(KUBECTL) delete automationhubrestore -n $(NAMESPACE) --all --ignore-not-found=true
	@# Delete backups
	-$(KUBECTL) delete ansibleautomationplatformbackup -n $(NAMESPACE) --all --ignore-not-found=true
	-$(KUBECTL) delete edabackup -n $(NAMESPACE) --all --ignore-not-found=true
	-$(KUBECTL) delete automationcontrollerbackup -n $(NAMESPACE) --all --ignore-not-found=true
	-$(KUBECTL) delete automationhubbackup -n $(NAMESPACE) --all --ignore-not-found=true
	@# Delete operands
	-$(KUBECTL) delete ansibleautomationplatform -n $(NAMESPACE) --all --ignore-not-found=true
	-$(KUBECTL) delete eda -n $(NAMESPACE) --all --ignore-not-found=true
	-$(KUBECTL) delete automationcontroller -n $(NAMESPACE) --all --ignore-not-found=true
	-$(KUBECTL) delete automationhub -n $(NAMESPACE) --all --ignore-not-found=true
	-$(KUBECTL) delete ansiblelightspeed -n $(NAMESPACE) --all --ignore-not-found=true
	@# Delete PVCs and secrets
	-$(KUBECTL) delete pvc -n $(NAMESPACE) --all --ignore-not-found=true
	-$(KUBECTL) delete secrets -n $(NAMESPACE) --all --ignore-not-found=true
	@# Delete OLM resources
	-$(KUBECTL) delete subscription aap-gateway-operator -n $(NAMESPACE) --ignore-not-found=true
	-$(KUBECTL) delete subscription ansible-automation-platform-operator -n $(NAMESPACE) --ignore-not-found=true
	@# Delete namespace/project
	@if command -v oc >/dev/null 2>&1; then \
		oc delete project $(NAMESPACE) --ignore-not-found=true; \
	else \
		$(KUBECTL) delete namespace $(NAMESPACE) --ignore-not-found=true; \
	fi

##@ OLM Management

.PHONY: _olm-cleanup
_olm-cleanup:
	@# Expand CLEAN_ALL into individual flags
	@CLEAN_SUB_EFF=$(CLEAN_SUB); \
	CLEAN_CSV_EFF=$(CLEAN_CSV); \
	CLEAN_CATALOG_EFF=$(CLEAN_CATALOG); \
	if [ "$(CLEAN_ALL)" = "true" ]; then \
		CLEAN_SUB_EFF=true; \
		CLEAN_CSV_EFF=true; \
		CLEAN_CATALOG_EFF=true; \
	fi; \
	if [ "$$CLEAN_SUB_EFF" = "true" ]; then \
		SUB=$$($(KUBECTL) -n $(NAMESPACE) get sub --no-headers -o custom-columns=":metadata.name" 2>/dev/null | grep ansible-automation-platform-operator || true); \
		if [ -n "$$SUB" ]; then \
			echo "Deleting subscription: $$SUB"; \
			$(KUBECTL) -n $(NAMESPACE) delete sub $$SUB; \
			sleep 2; \
		fi; \
	fi; \
	if [ "$$CLEAN_CSV_EFF" = "true" ]; then \
		CSV=$$($(KUBECTL) -n $(NAMESPACE) get csv --no-headers -o custom-columns=":metadata.name" 2>/dev/null | grep aap-operator || true); \
		if [ -n "$$CSV" ]; then \
			echo "Deleting CSV: $$CSV"; \
			$(KUBECTL) -n $(NAMESPACE) delete csv $$CSV; \
			sleep 2; \
		fi; \
	fi; \
	if [ "$$CLEAN_CATALOG_EFF" = "true" ]; then \
		if $(KUBECTL) -n $(CATALOG_SOURCE_NAMESPACE) get catsrc $(CATALOG_SOURCE) --no-headers 2>/dev/null | grep -q .; then \
			echo "Deleting catalog source: $(CATALOG_SOURCE)"; \
			$(KUBECTL) -n $(CATALOG_SOURCE_NAMESPACE) delete catsrc $(CATALOG_SOURCE); \
			sleep 2; \
		fi; \
	fi

.PHONY: _olm-deploy
_olm-deploy:
	@if [ "$(DEPLOY_METHOD)" = "bundle" ]; then \
		$(MAKE) _deploy-bundle; \
	else \
		$(MAKE) _deploy-catalog; \
	fi

.PHONY: _deploy-bundle
_deploy-bundle: _ensure-operator-sdk
	@echo ""
	@echo "=== Deploying via Konflux Bundle (operator-sdk) ==="
	@echo ""
	@# Apply ImageDigestMirrorSet if requested
	@if [ "$(CREATE_ICSP)" = "true" ]; then \
		echo "Applying ImageDigestMirrorSet..."; \
		$(KUBECTL) apply -f dev/image-content-source-policy.yml; \
	fi
	@# Create OperatorGroup if not present
	@if ! $(KUBECTL) get operatorgroup -n $(NAMESPACE) --no-headers 2>/dev/null | grep -q .; then \
		echo "Creating OperatorGroup..."; \
		printf 'apiVersion: operators.coreos.com/v1\nkind: OperatorGroup\nmetadata:\n  name: aap-operator-group\n  namespace: %s\nspec:\n  targetNamespaces:\n  - %s\n' \
			"$(NAMESPACE)" "$(NAMESPACE)" | $(KUBECTL) apply -f -; \
	fi
	@# Get bundle image (use DEV_BUNDLE_IMG override, or resolve via Konflux)
	@if [ -n "$(DEV_BUNDLE_IMG)" ]; then \
		BUNDLE="$(DEV_BUNDLE_IMG)"; \
	else \
		BUNDLE=$$($(MAKE) -s _get-bundle-img); \
	fi; \
	if [ -z "$$BUNDLE" ]; then \
		echo "ERROR: Could not resolve bundle image. Set DEV_BUNDLE_IMG or BUNDLE_VERSION." >&2; \
		exit 1; \
	fi; \
	echo "Bundle: $$BUNDLE"; \
	echo ""; \
	PULL_SECRET_FLAG=""; \
	if $(KUBECTL) get secret redhat-operators-pull-secret -n $(NAMESPACE) 2>/dev/null | grep -q .; then \
		PULL_SECRET_FLAG="--pull-secret-name redhat-operators-pull-secret"; \
	fi; \
	operator-sdk run bundle "$$BUNDLE" \
		--namespace $(NAMESPACE) \
		--timeout 10m \
		--security-context-config restricted \
		$$PULL_SECRET_FLAG & \
	SDK_PID=$$!; \
	echo ""; \
	echo "Monitoring pod status while waiting for CSV..."; \
	while kill -0 $$SDK_PID 2>/dev/null; do \
		sleep 15; \
		PROBLEM_PODS=$$($(KUBECTL) get pods -n $(NAMESPACE) --no-headers 2>/dev/null | grep -E 'ImagePullBackOff|ErrImagePull|CrashLoopBackOff|Error' || true); \
		if [ -n "$$PROBLEM_PODS" ]; then \
			echo ""; \
			echo "⚠ Problem pods detected:"; \
			echo "$$PROBLEM_PODS"; \
			echo ""; \
			FIRST_POD=$$(echo "$$PROBLEM_PODS" | head -1 | awk '{print $$1}'); \
			echo "Events for $$FIRST_POD:"; \
			$(KUBECTL) get events -n $(NAMESPACE) --field-selector involvedObject.name=$$FIRST_POD --sort-by='.lastTimestamp' 2>/dev/null | tail -3; \
			echo ""; \
		fi; \
	done; \
	wait $$SDK_PID

.PHONY: _deploy-catalog
_deploy-catalog:
	@echo ""
	@echo "=== Deploying via Catalog Source (legacy) ==="
	@echo "Using $(CATALOG_SOURCE) catalog source"
	@echo ""
	$(KUBECTL) -n $(CATALOG_SOURCE_NAMESPACE) apply -f dev/catalog-sources/$(CATALOG_SOURCE).yaml
	ansible-playbook ./dev/apply-dev-templates.yml \
		-e "namespace=$(NAMESPACE)" \
		-e "catalog_source=$(CATALOG_SOURCE)" \
		-e "catalog_source_namespace=$(CATALOG_SOURCE_NAMESPACE)"

.PHONY: _ensure-operator-sdk
_ensure-operator-sdk:
	@if ! command -v operator-sdk >/dev/null 2>&1; then \
		echo "operator-sdk not found, installing $(OPERATOR_SDK_VERSION)..."; \
		ARCH=$$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/'); \
		OSNAME=$$(uname -s | tr '[:upper:]' '[:lower:]'); \
		BINARY="operator-sdk_$${OSNAME}_$${ARCH}"; \
		URL="https://github.com/operator-framework/operator-sdk/releases/download/$(OPERATOR_SDK_VERSION)"; \
		curl -sfLo /tmp/operator-sdk "$${URL}/$${BINARY}"; \
		curl -sfLo /tmp/checksums.txt "$${URL}/checksums.txt"; \
		EXPECTED=$$(grep "$${BINARY}$$" /tmp/checksums.txt | awk '{print $$1}'); \
		if command -v sha256sum >/dev/null 2>&1; then \
			ACTUAL=$$(sha256sum /tmp/operator-sdk | awk '{print $$1}'); \
		else \
			ACTUAL=$$(shasum -a 256 /tmp/operator-sdk | awk '{print $$1}'); \
		fi; \
		if [ "$$EXPECTED" != "$$ACTUAL" ]; then \
			echo "ERROR: operator-sdk checksum mismatch!" >&2; \
			echo "  Expected: $$EXPECTED" >&2; \
			echo "  Actual:   $$ACTUAL" >&2; \
			exit 1; \
		fi; \
		chmod +x /tmp/operator-sdk; \
		echo "Installed operator-sdk $(OPERATOR_SDK_VERSION) (checksum verified)"; \
		export PATH="/tmp:$$PATH"; \
	fi

##@ Bundle Resolution

.PHONY: _get-bundle-img
_get-bundle-img:
	@COMPONENT=$$(echo "$(BUNDLE_VERSION)" | sed \
		-e 's/^devel$$/aap-namespaced-bundle-container-devel/' \
		-e 's/^dev$$/aap-namespaced-bundle-container-devel/' \
		-e 's/^2\.6$$/aap-namespaced-bundle-container-26/' \
		-e 's/^2\.6-next$$/aap-namespaced-bundle-container-26-next/' \
		-e 's/^2\.5$$/aap-namespaced-bundle-container-25/' \
		-e 's/^2\.5-next$$/aap-namespaced-bundle-container-25-next/' \
		-e 's/^2\.4$$/aap-namespaced-bundle-container-24/'); \
	BUNDLE_RESULT=""; \
	if [ -n "$${KONFLUX_TOKEN:-}" ]; then \
		echo "Fetching bundle from Konflux API: $(BUNDLE_VERSION) ($$COMPONENT)" >&2; \
		BUNDLE_RESULT=$$($(KUBECTL) --token="$$KONFLUX_TOKEN" \
			--server="$(KONFLUX_API)" --insecure-skip-tls-verify \
			get component "$$COMPONENT" -n "$(KONFLUX_NAMESPACE)" \
			-o jsonpath='{.status.lastPromotedImage}' 2>/dev/null) || true; \
	fi; \
	if [ -z "$$BUNDLE_RESULT" ]; then \
		echo "Fetching bundle from cache: $(BUNDLE_VERSION)" >&2; \
		BUNDLE_RESULT=$$(curl -sf "$(GITLAB_BUNDLE_URL)/bundle-$(BUNDLE_VERSION).txt" 2>/dev/null) || true; \
	fi; \
	if [ -z "$$BUNDLE_RESULT" ]; then \
		echo "ERROR: Could not fetch bundle for version: $(BUNDLE_VERSION)" >&2; \
		echo "  Set BUNDLE_IMG directly: BUNDLE_IMG=quay.io/...@sha256:xxx make up" >&2; \
		exit 1; \
	fi; \
	echo "$$BUNDLE_RESULT"

##@ Post-Deploy

.PHONY: _operator-build-and-inject
_operator-build-and-inject:
	@if [ "$(BUILD_IMAGE)" != "true" ]; then \
		echo "Skipping image build (BUILD_IMAGE=false)"; \
		exit 0; \
	fi; \
	if [ "$(BUILD_IMAGE_SKIP_CI)" = "true" ]; then \
		echo "Skipping image build for CI pipeline"; \
		exit 0; \
	fi
	@# Wait for CSV to succeed
	@echo "Waiting for AAP operator CSV to succeed..."
	@while true; do \
		CSV_NAME=$$($(KUBECTL) get csv -n $(NAMESPACE) --no-headers 2>/dev/null | grep 'aap-operator.v' | awk '{print $$1}'); \
		if [ -z "$$CSV_NAME" ]; then \
			echo "Waiting for CSV to appear..."; \
			sleep 5; \
			continue; \
		fi; \
		CSV_STATUS=$$($(KUBECTL) get csv -n $(NAMESPACE) $$CSV_NAME -o jsonpath='{.status.phase}' 2>/dev/null); \
		if [ "$$CSV_STATUS" = "Succeeded" ]; then \
			echo "CSV $$CSV_NAME succeeded."; \
			break; \
		fi; \
		echo "CSV $$CSV_NAME status: $$CSV_STATUS. Waiting..."; \
		sleep 5; \
	done
	@# Build and push dev image
	@$(MAKE) dev-build
	@# Inject dev image into CSV
	@echo "Patching CSV with dev image $(DEV_IMG):$(DEV_TAG)..."
	@CSV_NAME=$$($(KUBECTL) get csv -n $(NAMESPACE) --no-headers | grep 'aap-operator.v' | awk '{print $$1}'); \
	$(KUBECTL) get csv -n $(NAMESPACE) $$CSV_NAME -o json | \
		jq --arg img "$(DEV_IMG):$(DEV_TAG)" \
		'(.spec.install.spec.deployments[].spec.template.spec.containers[] | select(.image | contains("gateway") and contains("operator")) | .image) = $$img' | \
		$(KUBECTL) apply -f -
	@# Wait for deployment to roll out with new image
	@echo "Waiting for deployment to use $(DEV_IMG):$(DEV_TAG)..."
	@while true; do \
		IMAGES=$$($(KUBECTL) get deployment $(DEPLOYMENT_NAME) -n $(NAMESPACE) \
			-o jsonpath='{.spec.template.spec.containers[*].image}' 2>/dev/null); \
		if echo "$$IMAGES" | grep -q "$(DEV_IMG):$(DEV_TAG)"; then \
			echo "Deployment updated with dev image."; \
			break; \
		fi; \
		echo "Waiting for image rollout..."; \
		sleep 10; \
	done

.PHONY: _operator-post-deploy
_operator-post-deploy:
	@# Wait for all pods to be ready
	@echo "Waiting for operator pods to be ready..."
	@while true; do \
		READY=$$($(KUBECTL) get deployment $(DEPLOYMENT_NAME) -n $(NAMESPACE) \
			-o jsonpath='{.status.readyReplicas}' 2>/dev/null); \
		DESIRED=$$($(KUBECTL) get deployment $(DEPLOYMENT_NAME) -n $(NAMESPACE) \
			-o jsonpath='{.status.replicas}' 2>/dev/null); \
		if [ -n "$$READY" ] && [ -n "$$DESIRED" ] && [ "$$READY" = "$$DESIRED" ] && [ "$$READY" -gt 0 ]; then \
			echo "All pods ready ($$READY/$$DESIRED)."; \
			break; \
		fi; \
		echo "Pods not ready ($$READY/$$DESIRED). Waiting..."; \
		sleep 10; \
	done
	@# Re-apply CRDs
	$(KUBECTL) apply -f config/crd/bases/aap.ansible.com_ansibleautomationplatforms.yaml
	$(KUBECTL) apply -f config/crd/bases/aap.ansible.com_ansibleautomationplatformrestores.yaml
	$(KUBECTL) apply -f config/crd/bases/aap.ansible.com_ansibleautomationplatformbackups.yaml
	@# Create secrets if requested
	@if [ "$(CREATE_SECRETS)" = "true" ]; then \
		$(KUBECTL) apply -n $(NAMESPACE) -f dev/admin-password-secret.yml; \
		$(KUBECTL) apply -n $(NAMESPACE) -f dev/aoc-admin-password.yml; \
	fi
	@# Apply dev CR
	@if [ "$(CREATE_AAP)" = "true" ] && [ -f "$(DEV_CR)" ]; then \
		echo "Applying dev CR: $(DEV_CR)"; \
		$(KUBECTL) apply -n $(NAMESPACE) -f $(DEV_CR); \
	fi

##@ Linting

.PHONY: lint
lint: ## Run ansible-lint with no_log check
	ansible-lint
