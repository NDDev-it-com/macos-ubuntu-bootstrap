#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

check_cmd() {
  if command -v "$1" >/dev/null 2>&1; then
    return 0
  fi
  echo "missing required command: $1" >&2
  exit 1
}

check_script() {
  local script=$1
  if [ ! -f "$script" ]; then
    echo "missing script: $script" >&2
    exit 1
  fi
}

check_cmd bash
check_cmd shellcheck

SCRIPT_PATHS=(
  "$REPO_ROOT/scripts/bootstrap.sh"
  "$REPO_ROOT/scripts/lib/common.sh"
  "$REPO_ROOT/scripts/macos/install.sh"
  "$REPO_ROOT/scripts/macos/verify.sh"
  "$REPO_ROOT/scripts/ubuntu/install.sh"
  "$REPO_ROOT/scripts/ubuntu/verify.sh"
  "$REPO_ROOT/scripts/ci/lint.sh"
  "$REPO_ROOT/scripts/ci/validate.sh"
)

for script in "${SCRIPT_PATHS[@]}"; do
  check_script "$script"
  bash -n "$script"
done

for script in "${SCRIPT_PATHS[@]}"; do
  shellcheck -x "$script"
done

echo "scripts-lint-ok"
