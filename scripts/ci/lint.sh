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

receipt_file=$(mktemp "${TMPDIR:-/tmp}/rldyour-shell-receipt.XXXXXX")
paths_file=$(mktemp "${TMPDIR:-/tmp}/rldyour-shell-paths.XXXXXX")
cleanup() {
  rm -f -- "$receipt_file" "$paths_file"
}
trap cleanup EXIT HUP INT TERM
if ! python3 -I "$REPO_ROOT/scripts/ci/script_inventory.py" receipt --gate shellcheck >"$receipt_file"; then
  echo "failed to create shell selection receipt" >&2
  exit 1
fi
if ! python3 -I "$REPO_ROOT/scripts/ci/script_inventory.py" paths --receipt "$receipt_file" >"$paths_file"; then
  echo "failed to verify shell selection receipt" >&2
  exit 1
fi

SCRIPT_PATHS=()
while IFS= read -r discovered; do
  SCRIPT_PATHS+=("$REPO_ROOT/$discovered")
done <"$paths_file"
if [ "${#SCRIPT_PATHS[@]}" -eq 0 ]; then
  echo "script inventory selected no shell scripts" >&2
  exit 1
fi
printf 'linting %d shell scripts\n' "${#SCRIPT_PATHS[@]}"

for script in "${SCRIPT_PATHS[@]}"; do
  check_script "$script"
  bash -n "$script"
done

for script in "${SCRIPT_PATHS[@]}"; do
  shellcheck -x "$script"
done

echo "scripts-lint-ok"
