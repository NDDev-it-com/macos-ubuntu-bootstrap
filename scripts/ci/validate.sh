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

require_file() {
  local path=$1
  if [ -f "$path" ]; then
    return 0
  fi
  echo "missing required file: $path" >&2
  exit 1
}

require_dir() {
  local path=$1
  if [ -d "$path" ]; then
    return 0
  fi
  echo "missing required directory: $path" >&2
  exit 1
}

python3 - <<PY
from pathlib import Path
import json

path = Path("${REPO_ROOT}") / 'config' / 'rldyour-contract.json'
data = json.loads(path.read_text(encoding='utf-8'))
adapter_id = data.get('adapter', {}).get('id')
if not adapter_id:
    raise SystemExit('config/rldyour-contract.json: adapter.id is required')
print(f'contract-ok:{adapter_id}')
PY

check_cmd bash
check_cmd python3
require_dir "$REPO_ROOT/.github"
require_dir "$REPO_ROOT/.github/workflows"
require_dir "$REPO_ROOT/scripts"
require_dir "$REPO_ROOT/scripts/macos"
require_dir "$REPO_ROOT/scripts/ubuntu"
require_dir "$REPO_ROOT/docs"

require_file "$REPO_ROOT/.github/workflows/ci.yml"
require_file "$REPO_ROOT/scripts/bootstrap.sh"
require_file "$REPO_ROOT/scripts/ci/validate.sh"
require_file "$REPO_ROOT/scripts/ci/lint.sh"
require_file "$REPO_ROOT/scripts/lib/common.sh"
require_file "$REPO_ROOT/scripts/macos/install.sh"
require_file "$REPO_ROOT/scripts/macos/verify.sh"
require_file "$REPO_ROOT/scripts/ubuntu/install.sh"
require_file "$REPO_ROOT/scripts/ubuntu/verify.sh"

bash "$REPO_ROOT/scripts/ci/lint.sh"

bash "$REPO_ROOT/scripts/bootstrap.sh" --platform macos --plan --skip-checks
bash "$REPO_ROOT/scripts/bootstrap.sh" --platform ubuntu --plan --skip-checks

echo "ci-validate-ok"
