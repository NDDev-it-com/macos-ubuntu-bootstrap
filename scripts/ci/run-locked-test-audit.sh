#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
rldyour::ci::locked_python_usable() {
  local candidate=$1
  if [ ! -e "$candidate" ]; then
    return 1
  elif [ -d "$candidate" ]; then
    return 1
  elif [ ! -f "$candidate" ]; then
    return 1
  elif [ ! -x "$candidate" ]; then
    return 1
  else
    return 0
  fi
}

rldyour::ci::locked_audit_main() {
  local python=${RLDYOUR_LOCKED_TEST_PYTHON:-}
  case "$python" in
    /*) ;;
    *) echo "locked test Python must be an explicit absolute path" >&2; return 2 ;;
  esac
  if ! rldyour::ci::locked_python_usable "$python"; then
    echo "locked test Python is missing or not executable" >&2
    return 2
  fi

  env -i HOME="${HOME:-/tmp}" LANG=C LC_ALL=C PATH=/usr/bin:/bin \
    "$python" -I - "$REPO_ROOT" <<'PY'
import hashlib
import importlib.metadata
import pathlib
import site
import sys

root = pathlib.Path(sys.argv[1]).resolve(strict=True)
lock = root / "requirements-test.txt"
receipt = pathlib.Path(sys.prefix) / ".rldyour-requirements-test.sha256"
assert sys.prefix != sys.base_prefix, "locked tooling interpreter must be a virtual environment"
assert sys.flags.isolated == 1 and site.ENABLE_USER_SITE is False
assert importlib.metadata.version("pyflakes") == "3.4.0"
assert receipt.is_file() and not receipt.is_symlink(), "locked tooling receipt is missing"
expected = hashlib.sha256(lock.read_bytes()).hexdigest()
assert receipt.read_text(encoding="ascii").strip() == expected, "locked tooling receipt does not match requirements-test.txt"
PY

  exec env -i HOME="${HOME:-/tmp}" LANG=C LC_ALL=C PATH=/usr/bin:/bin \
    "$python" -I "$REPO_ROOT/scripts/ci/audit_test_modules.py" --root "$REPO_ROOT"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  rldyour::ci::locked_audit_main "$@"
fi
