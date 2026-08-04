#!/usr/bin/env bash
# Pure persistence decisions, sourced by create-vm.sh and destroy.sh. No UTM,
# no side effects, so it is unit-testable on any machine.
set -euo pipefail

# Decide whether to create a fresh data disk or reuse the existing one.
# Arg: 1 if persist/data.qcow2 exists, 0 if not.
persist_action() {
  case "${1:?exists flag required}" in
    0) echo "create" ;;
    *) echo "reuse" ;;
  esac
}
