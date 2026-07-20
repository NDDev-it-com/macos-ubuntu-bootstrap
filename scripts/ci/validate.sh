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
if data.get('schema_version') != 2:
    raise SystemExit('config/rldyour-contract.json: schema_version must be 2')
if data.get('adapter', {}).get('version') != (Path("${REPO_ROOT}") / 'VERSION').read_text().strip():
    raise SystemExit('contract adapter.version must match VERSION')
browser = data.get('browser_automation', {})
if browser.get('provider') != 'cloakbrowser' or browser.get('required') is not True or browser.get('fallback_allowed') is not False:
    raise SystemExit('browser contract must be mandatory/fail-closed through CloakBrowser')
if browser.get('active_providers') != ['playwright-cli', 'chrome-devtools-mcp']:
    raise SystemExit('browser contract must expose exactly the two managed active providers')
if (
    browser.get('webwright_status'),
    browser.get('webwright_enabled'),
    browser.get('disabled_wrapper'),
) != ('retired-fail-closed', False, 'webwright'):
    raise SystemExit('Webwright retirement contract is incomplete')
# One owner per harness (RVR-P1-004): codex and zcode are the active set and are
# owned by their authoritative NDDev modules, referenced by module-path env vars.
harnesses = data.get('harnesses', {})
if harnesses.get('policy') != 'one-owner-per-harness':
    raise SystemExit('harness policy must be one-owner-per-harness')
if harnesses.get('active') != ['codex', 'zcode']:
    raise SystemExit('active harness set must be exactly codex and zcode')
if 'ai_cli' in data:
    raise SystemExit('the inline ai_cli pin block must be removed')
print(f'contract-ok:{adapter_id}')
PY

check_cmd bash
check_cmd python3
check_cmd rg
require_dir "$REPO_ROOT/.github"
require_dir "$REPO_ROOT/.github/workflows"
require_dir "$REPO_ROOT/scripts"
require_dir "$REPO_ROOT/scripts/macos"
require_dir "$REPO_ROOT/scripts/ubuntu"
require_dir "$REPO_ROOT/docs"

require_file "$REPO_ROOT/.github/workflows/ci.yml"
require_file "$REPO_ROOT/scripts/bootstrap.sh"
require_file "$REPO_ROOT/scripts/auth-handoff.sh"
require_file "$REPO_ROOT/scripts/ci/validate.sh"
require_file "$REPO_ROOT/scripts/ci/lint.sh"
require_file "$REPO_ROOT/scripts/lib/common.sh"
require_file "$REPO_ROOT/scripts/browser_runtime_integrity.py"
require_file "$REPO_ROOT/scripts/verify-browser-runtime.sh"
require_file "$REPO_ROOT/scripts/macos/install.sh"
require_file "$REPO_ROOT/scripts/macos/verify.sh"
require_file "$REPO_ROOT/scripts/ubuntu/install.sh"
require_file "$REPO_ROOT/scripts/ubuntu/server.sh"
require_file "$REPO_ROOT/scripts/ubuntu/verify.sh"
require_file "$REPO_ROOT/scripts/ubuntu/verify-server.sh"
require_file "$REPO_ROOT/templates/browser/playwright-cli.json"
require_file "$REPO_ROOT/templates/browser/cloakbrowser-pyproject.toml"
require_file "$REPO_ROOT/templates/browser/cloakbrowser-uv.lock"
require_file "$REPO_ROOT/templates/browser/provider/package.json"
require_file "$REPO_ROOT/templates/browser/provider/bun.lock"
if [ -e "$REPO_ROOT/templates/browser/webwright-local-cdp.yaml" ] || \
  [ -e "$REPO_ROOT/templates/browser/webwright-uv.lock" ]; then
  echo "retired Webwright runtime inputs must not exist" >&2
  exit 1
fi

bash "$REPO_ROOT/scripts/ci/lint.sh"

COMMON_PLAN=(--plan --skip-system --skip-ai --skip-lsps --skip-checks)
bash "$REPO_ROOT/scripts/bootstrap.sh" --platform macos --profile desktop --gui "${COMMON_PLAN[@]}"
bash "$REPO_ROOT/scripts/bootstrap.sh" --platform macos --profile desktop --no-gui "${COMMON_PLAN[@]}"
bash "$REPO_ROOT/scripts/bootstrap.sh" --platform ubuntu --profile desktop --gui "${COMMON_PLAN[@]}"
bash "$REPO_ROOT/scripts/bootstrap.sh" --platform ubuntu --profile desktop --no-gui "${COMMON_PLAN[@]}"
bash "$REPO_ROOT/scripts/bootstrap.sh" --platform ubuntu --profile server --docker-mode rootful "${COMMON_PLAN[@]}"
bash "$REPO_ROOT/scripts/bootstrap.sh" --platform ubuntu --profile server --docker-mode rootless "${COMMON_PLAN[@]}"

if bash "$REPO_ROOT/scripts/bootstrap.sh" --platform ubuntu --skip-browser --plan >/dev/null 2>&1; then
  echo "--skip-browser unexpectedly succeeded" >&2
  exit 1
fi

if bash "$REPO_ROOT/scripts/bootstrap.sh" --platform ubuntu --plan >/dev/null 2>&1; then
  echo "Ubuntu profile inference unexpectedly succeeded" >&2
  exit 1
fi

if CLOAKBROWSER_BINARY_PATH=/tmp/unmanaged-browser \
  bash "$REPO_ROOT/scripts/bootstrap.sh" --platform ubuntu --profile desktop \
    --no-gui "${COMMON_PLAN[@]}" >/dev/null 2>&1; then
  echo "CloakBrowser binary trust override unexpectedly succeeded" >&2
  exit 1
fi

if rg -n 'curl[^|]*\|[[:space:]]*(ba)?sh' "$REPO_ROOT/scripts"; then
  echo "remote curl-to-shell pipeline is forbidden" >&2
  exit 1
fi

echo "ci-validate-ok"
