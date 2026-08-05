# infra-utm-redteam-main
# One-command main Kali attack box on UTM (Apple Silicon).

SHELL := /bin/bash
.DEFAULT_GOAL := help

.PHONY: help preflight up provision configure status ssh console down destroy lint test

# Allow `make ssh kali` / `make console kali` (bare VM name) alongside VM=kali.
BAREARG_GOALS := ssh console
ifneq ($(filter $(firstword $(MAKECMDGOALS)),$(BAREARG_GOALS)),)
BARE_ARGS := $(filter-out $(BAREARG_GOALS),$(MAKECMDGOALS))
ifneq ($(BARE_ARGS),)
.PHONY: $(BARE_ARGS)
$(eval $(BARE_ARGS):;@:)
endif
endif

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

up: ## Full hands-off deploy: preflight, create the VM, configure with Ansible
	@scripts/up.sh

preflight: ## Check macOS, UTM, required tools; generate SSH key
	@scripts/preflight.sh

provision: ## Create and boot the VM only (no Ansible)
	@scripts/up.sh --provision-only

configure: ## Run Ansible against the running VM
	@scripts/up.sh --configure-only

status: ## Show VM status
	@scripts/status.sh

ssh: ## SSH into the box: make ssh kali
	@scripts/ssh.sh $(or $(VM),$(BARE_ARGS))

console: ## Serial console (any kernel): make console kali
	@scripts/console.sh $(or $(VM),$(BARE_ARGS))

down: ## Stop the VM (keeps it)
	@scripts/down.sh

destroy: ## Stop and delete the VM and generated artifacts (persist/ + images/ kept)
	@scripts/destroy.sh

test: ## Run the shell unit tests
	@bash tests/nic-mode.sh
	@bash tests/persist-roundtrip.sh

lint: ## Syntax-check scripts and Ansible
	@bash -n scripts/*.sh tests/*.sh && echo "shell OK"
	@for f in scripts/*.applescript; do osascript -e "1" >/dev/null; done; echo "applescript present"
	@command -v ansible-lint >/dev/null && ansible-lint ansible/ || echo "ansible-lint not installed, skipping"
