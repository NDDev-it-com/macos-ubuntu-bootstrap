#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AMBIENT_PATH=${PATH:-}
MINIMAL_PATH=$(/usr/bin/python3 -I "$SCRIPT_DIR/resolve_validation_path.py" \
  --contract "$REPO_ROOT/config/rldyour-contract.json" --ambient-path "$AMBIENT_PATH")

exec env -i HOME="${HOME:-/tmp}" LANG=C LC_ALL=C PATH="$MINIMAL_PATH" \
  RLDYOUR_VALIDATION_PATH_READY=1 /bin/bash "$SCRIPT_DIR/validate.sh"
