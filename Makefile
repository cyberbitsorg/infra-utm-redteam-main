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
	@for t in tests/*.sh; do echo "== $$t"; bash "$$t" || exit 1; done

# bash -n takes ONE script; extra arguments become its positional parameters, so
# a loop is the only way to check every file.
lint: ## Syntax-check scripts and Ansible
	@for f in scripts/*.sh tests/*.sh; do bash -n "$$f" || exit 1; done; echo "shell OK"
	@for f in scripts/*.applescript; do osacompile -o /dev/null "$$f" || exit 1; done; echo "applescript OK"
	@if command -v shellcheck >/dev/null; then shellcheck scripts/*.sh tests/*.sh; \
		else echo "shellcheck not installed, skipping"; fi
	@if command -v ansible-lint >/dev/null; then \
		ANSIBLE_COLLECTIONS_PATH="$(COLLECTIONS_PATH)" ansible-lint ansible/; \
		else echo "ansible-lint not installed, skipping"; fi

# ansible-lint bundles its own ansible-core, which searches only the default
# collection paths. Homebrew's ansible keeps its collections inside its own
# site-packages instead, so without this every play fails syntax-check on a
# module that ansible-playbook resolves fine. Ask ansible-galaxy where they are.
COLLECTIONS_PATH = $(shell ansible-galaxy collection list 2>/dev/null \
	| sed -n 's|^\# \(/.*\)/ansible_collections$$|\1|p' | tail -1)
