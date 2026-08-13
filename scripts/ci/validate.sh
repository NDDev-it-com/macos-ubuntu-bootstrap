#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
[ "${RLDYOUR_VALIDATION_PATH_READY:-0}" = 1 ] || {
  echo "validation must run through scripts/ci/run-clean-validation.sh" >&2
  exit 2
}

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
version = data['adapter']['version']
agents = (Path("${REPO_ROOT}") / 'AGENTS.md').read_text(encoding='utf-8')
readme = (Path("${REPO_ROOT}") / 'README.md').read_text(encoding='utf-8')
changelog = (Path("${REPO_ROOT}") / 'CHANGELOG.md').read_text(encoding='utf-8')
if f'## Contract {version}' not in agents:
    raise SystemExit('AGENTS.md contract heading must match VERSION')
if f'current contract is {chr(96)}{version}{chr(96)}' not in readme:
    raise SystemExit('README.md contract version must match VERSION')
if not any(line.startswith(f'## [{version}] - ') for line in changelog.splitlines()):
    raise SystemExit('CHANGELOG.md must contain the bracketed current release heading')
ubuntu = data.get('targets', {}).get('ubuntu', {})
if ubuntu.get('gui_architectures') != ['amd64']:
    raise SystemExit('Ubuntu GUI architecture boundary must be explicit and amd64-only')
harnesses = data.get('harnesses', {})
if harnesses.get('policy') != 'vendor-official':
    raise SystemExit('AI CLI policy must require official vendor distributions')
if harnesses.get('active') != ['codex', 'claude-code', 'grok-build']:
    raise SystemExit('active AI CLI set must be codex, claude-code, grok-build')
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
require_file "$REPO_ROOT/scripts/support_evidence.py"
require_file "$REPO_ROOT/config/support-evidence-matrix.json"
require_file "$REPO_ROOT/config/script-inventory.json"
require_file "$REPO_ROOT/scripts/ci/shell_contract.py"
require_file "$REPO_ROOT/scripts/ci/audit_test_modules.py"
require_file "$REPO_ROOT/scripts/ci/run-locked-test-audit.sh"
require_file "$REPO_ROOT/scripts/ci/run-clean-validation.sh"
require_file "$REPO_ROOT/scripts/ci/resolve_validation_path.py"
require_file "$REPO_ROOT/scripts/ci/validate.sh"
require_file "$REPO_ROOT/scripts/ci/lint.sh"
require_file "$REPO_ROOT/scripts/ci/script_inventory.py"
require_file "$REPO_ROOT/scripts/lib/common.sh"
require_file "$REPO_ROOT/scripts/macos/install.sh"
require_file "$REPO_ROOT/scripts/macos/verify.sh"
require_file "$REPO_ROOT/scripts/ubuntu/install.sh"
require_file "$REPO_ROOT/scripts/ubuntu/server.sh"
require_file "$REPO_ROOT/scripts/ubuntu/verify.sh"
require_file "$REPO_ROOT/scripts/ubuntu/verify-server.sh"

python3 -I "$REPO_ROOT/scripts/ci/script_inventory.py" validate
python3 "$REPO_ROOT/scripts/support_evidence.py" validate
bash "$REPO_ROOT/scripts/ci/lint.sh"

COMMON_PLAN=(--plan --skip-system --skip-ai --skip-lsps --skip-checks)
bash "$REPO_ROOT/scripts/bootstrap.sh" --platform macos --profile desktop --gui "${COMMON_PLAN[@]}"
bash "$REPO_ROOT/scripts/bootstrap.sh" --platform macos --profile desktop --no-gui "${COMMON_PLAN[@]}"
bash "$REPO_ROOT/scripts/bootstrap.sh" --platform ubuntu --profile desktop --gui "${COMMON_PLAN[@]}"
bash "$REPO_ROOT/scripts/bootstrap.sh" --platform ubuntu --profile desktop --no-gui "${COMMON_PLAN[@]}"
bash "$REPO_ROOT/scripts/bootstrap.sh" --platform ubuntu --profile server --docker-mode rootful "${COMMON_PLAN[@]}"
bash "$REPO_ROOT/scripts/bootstrap.sh" --platform ubuntu --profile server --docker-mode rootless "${COMMON_PLAN[@]}"
bash "$REPO_ROOT/scripts/bootstrap.sh" --platform ubuntu --profile desktop-builds --gui "${COMMON_PLAN[@]}"
bash "$REPO_ROOT/scripts/bootstrap.sh" --platform ubuntu --profile desktop-builds --no-gui "${COMMON_PLAN[@]}"

if bash "$REPO_ROOT/scripts/bootstrap.sh" --platform ubuntu --plan >/dev/null 2>&1; then
  echo "Ubuntu profile inference unexpectedly succeeded" >&2
  exit 1
fi

if rg -n 'curl[^|]*\|[[:space:]]*(ba)?sh' "$REPO_ROOT/scripts"; then
  echo "remote curl-to-shell pipeline is forbidden" >&2
  exit 1
fi

echo "ci-validate-ok"
