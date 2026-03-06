# common.mk — Shared dev workflow targets for AAP operators
#
# Synced across all operator repos via GHA.
# Operator-specific customization goes in operator.mk.
#
# Usage:
#   make up        # Full dev deploy
#   make down      # Full dev undeploy
#
# Required variables (set in operator.mk):
#   NAMESPACE         — target namespace
#   DEPLOYMENT_NAME   — operator deployment name
#   VERSION           — operator version
#
# Optional overrides:
#   ENGINE=docker make up   # use docker instead of podman
#   QUAY_USER=myuser make up
#   DEV_TAG=mytag make up

##@ Common Variables

# Kube CLI auto-detect (oc preferred, kubectl fallback)
KUBECTL ?= $(shell command -v oc 2>/dev/null || command -v kubectl 2>/dev/null)

# Container engine
ENGINE ?= podman

# Dev workflow
QUAY_USER ?=
REGISTRIES ?= registry.redhat.io quay.io/$(QUAY_USER)
TAG ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo latest)
DEV_TAG ?= dev
DEV_TAG_PUSH ?= true
PULL_SECRET_FILE ?= dev/pull-secret.yml
CREATE_PULL_SECRET ?= false

# Dev image: quay.io/<user>/<operator-name>
_OPERATOR_NAME = $(notdir $(IMAGE_TAG_BASE))
DEV_IMG ?= quay.io/$(QUAY_USER)/$(_OPERATOR_NAME)

# Host architecture (for ARM-aware builds)
HOST_ARCH := $(shell uname -m)

# Auto-detect registry auth config
REGISTRY_AUTH_CONFIG ?= $(shell \
  if [ "$(ENGINE)" = "podman" ]; then \
    for f in "$${XDG_RUNTIME_DIR}/containers/auth.json" \
             "$${HOME}/.config/containers/auth.json" \
             "$${HOME}/.docker/config.json"; do \
      [ -f "$$f" ] && echo "$$f" && break; \
    done; \
  else \
    [ -f "$${HOME}/.docker/config.json" ] && echo "$${HOME}/.docker/config.json"; \
  fi)

# Portable sed -i (GNU vs BSD)
_SED_I = $(shell if sed --version >/dev/null 2>&1; then echo 'sed -i'; else echo 'sed -i ""'; fi)

##@ Dev Workflow

.PHONY: up
up: _require-quay-user _require-namespace ## Full dev deploy
	@$(MAKE) registry-login
	@$(MAKE) ns-wait
	@$(MAKE) ns-create
	@$(MAKE) pull-secret
	@$(MAKE) patch-pull-policy
	@$(MAKE) dev-build
	@$(MAKE) operator-up

.PHONY: down
down: _require-namespace ## Full dev undeploy
	@$(MAKE) operator-down

##@ Registry

.PHONY: registry-login
registry-login: ## Login to container registries
	@for registry in $(REGISTRIES); do \
		echo "Logging into $$registry..."; \
		$(ENGINE) login $$registry; \
	done

##@ Namespace

.PHONY: ns-wait
ns-wait: ## Wait for namespace to finish terminating
	@if $(KUBECTL) get namespace $(NAMESPACE) 2>/dev/null | grep -q 'Terminating'; then \
		echo "Namespace $(NAMESPACE) is terminating. Waiting..."; \
		while $(KUBECTL) get namespace $(NAMESPACE) 2>/dev/null | grep -q 'Terminating'; do \
			sleep 5; \
		done; \
		echo "Namespace $(NAMESPACE) terminated."; \
	fi

.PHONY: ns-create
ns-create: ## Create namespace if it does not exist
	@if ! $(KUBECTL) get namespace $(NAMESPACE) --no-headers 2>/dev/null | grep -q .; then \
		echo "Creating namespace $(NAMESPACE)"; \
		$(KUBECTL) create namespace $(NAMESPACE); \
	else \
		echo "Namespace $(NAMESPACE) already exists"; \
	fi

##@ Secrets

.PHONY: pull-secret
pull-secret: ## Apply pull secret from file or create from auth config
	@if [ "$(CREATE_PULL_SECRET)" != "true" ]; then \
		echo "Pull secret creation disabled (CREATE_PULL_SECRET=false)"; \
		exit 0; \
	fi; \
	if [ -f "$(PULL_SECRET_FILE)" ]; then \
		echo "Applying pull secret from $(PULL_SECRET_FILE)"; \
		$(KUBECTL) apply -n $(NAMESPACE) -f $(PULL_SECRET_FILE); \
	elif [ -n "$(REGISTRY_AUTH_CONFIG)" ] && [ -f "$(REGISTRY_AUTH_CONFIG)" ]; then \
		if ! $(KUBECTL) get secret redhat-operators-pull-secret -n $(NAMESPACE) 2>/dev/null | grep -q .; then \
			echo "Creating pull secret from $(REGISTRY_AUTH_CONFIG)"; \
			$(KUBECTL) create secret generic redhat-operators-pull-secret \
				--from-file=.dockerconfigjson="$(REGISTRY_AUTH_CONFIG)" \
				--type=kubernetes.io/dockerconfigjson \
				-n $(NAMESPACE); \
		else \
			echo "Pull secret already exists"; \
		fi; \
	else \
		echo "No pull secret file or registry auth config found, skipping"; \
		exit 0; \
	fi; \
	echo "Linking pull secret to default service account..."; \
	$(KUBECTL) patch serviceaccount default -n $(NAMESPACE) \
		-p '{"imagePullSecrets": [{"name": "redhat-operators-pull-secret"}]}' 2>/dev/null \
		&& echo "Pull secret linked to default SA" \
		|| echo "Warning: could not link pull secret to default SA"

##@ Build

.PHONY: podman-build
podman-build: ## Build image with podman
	podman build -t ${IMG} .

.PHONY: podman-push
podman-push: ## Push image with podman
	podman push ${IMG}

.PHONY: podman-buildx
podman-buildx: ## Build and push multi-arch image with podman (for ARM hosts)
	podman build --platform=$(PLATFORMS) --manifest ${IMG} -f Dockerfile .
	podman manifest push --all ${IMG}

.PHONY: dev-build
dev-build: ## Build and push dev image (ARM-aware)
	@echo "Building $(DEV_IMG):$(DEV_TAG) with $(ENGINE)..."
	@if [ "$(HOST_ARCH)" = "arm64" ] || [ "$(HOST_ARCH)" = "aarch64" ] && [ "$(ENGINE)" = "podman" ]; then \
		echo "ARM architecture detected ($(HOST_ARCH)). Using multi-arch build..."; \
		$(MAKE) podman-buildx IMG=$(DEV_IMG):$(DEV_TAG); \
	else \
		$(MAKE) $(ENGINE)-build IMG=$(DEV_IMG):$(DEV_TAG); \
		if [ "$(DEV_TAG_PUSH)" = "true" ]; then \
			$(MAKE) $(ENGINE)-push IMG=$(DEV_IMG):$(DEV_TAG); \
		fi; \
	fi

##@ Deployment Helpers

.PHONY: patch-pull-policy
patch-pull-policy: ## Patch imagePullPolicy to Always in manager config
	@for file in config/manager/manager.yaml; do \
		if [ -f "$$file" ] && grep -q 'imagePullPolicy: IfNotPresent' "$$file"; then \
			echo "Patching imagePullPolicy in $$file"; \
			$(_SED_I) 's|imagePullPolicy: IfNotPresent|imagePullPolicy: Always|g' "$$file"; \
		fi; \
	done

.PHONY: pre-deploy-cleanup
pre-deploy-cleanup: ## Delete existing operator deployment (safe)
	@if [ -n "$(DEPLOYMENT_NAME)" ]; then \
		echo "Cleaning up deployment $(DEPLOYMENT_NAME)..."; \
		$(KUBECTL) delete deployment $(DEPLOYMENT_NAME) \
			-n $(NAMESPACE) --ignore-not-found=true; \
	fi

##@ Validation

.PHONY: _require-quay-user
_require-quay-user:
	@if [ -z "$(QUAY_USER)" ]; then \
		echo "Error: QUAY_USER is required. Run: export QUAY_USER=<your-quay-username>"; \
		exit 1; \
	fi

.PHONY: _require-namespace
_require-namespace:
	@if [ -z "$(NAMESPACE)" ]; then \
		echo "Error: NAMESPACE is required. Set it in operator.mk or run: export NAMESPACE=<namespace>"; \
		exit 1; \
	fi
# Test change 1772821268
