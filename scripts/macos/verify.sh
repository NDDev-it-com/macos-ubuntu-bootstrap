#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/common.sh"

STRICT=0
GUI_ENABLED="${RLDYOUR_GUI_ENABLED:-1}"
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=1 ;;
    --no-gui) GUI_ENABLED=0 ;;
    --help)
      echo "Usage: scripts/macos/verify.sh [--strict] [--no-gui]"
      exit 0
      ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

rldyour::ensure_path
rldyour::section "Verify macOS source/LSP workstation"

required_cmds=(
  git curl node bun uv python3 shellcheck shfmt clangd gopls
  pyright pyright-langserver basedpyright ruff
  tsc vtsls yaml-language-server bash-language-server docker-langserver
  vscode-html-language-server vscode-css-language-server vscode-json-language-server
  taplo marksman terraform-ls cmake-language-server
  codex zcode rtk
  cloak-chromium cloakbrowser-cdp-health chrome-devtools-mcp playwright-cli
)
for cmd in "${required_cmds[@]}"; do
  rldyour::require_cmd "$cmd" required
done
rldyour::require_one_of_cmd required docker-language-server docker-langserver

rldyour::require_cmd_min_version node 20.19 --version
# The active harness set (codex, zcode) is owned by its GDS modules. Deep harness
# proof (exact CLI/app versions, setup catalog) is delegated to each module's own
# status; here we only require the CLIs to resolve on PATH (checked above).
rtk --version 2>/dev/null | head -n 1 | grep -Eq '^rtk[[:space:]]+0\.43\.0([[:space:]]|$)' || {
  rldyour::log "missing" "rtk exact managed version 0.43.0"
  exit 1
}
cloakbrowser-cdp-health
chrome-devtools-mcp --version | grep -Fq "1.6.0"
playwright-cli --version | grep -Fq "0.1.17"
"$SCRIPT_DIR/../verify-browser-runtime.sh" --json
rldyour::verify_terminal_environment

if [ "$GUI_ENABLED" -eq 1 ]; then
  for app in Ghostty cmux ChatGPT Codex Claude; do
    [ -d "/Applications/${app}.app" ] || {
      rldyour::log "missing" "required GUI app: /Applications/${app}.app"
      exit 1
    }
  done
fi

if command -v docker >/dev/null 2>&1; then
  rldyour::log "warn" "unmanaged Docker is present; this desktop bootstrap neither uses nor removes it"
else
  rldyour::log "ok" "desktop policy: Docker is absent"
fi

[ "$STRICT" -eq 0 ] || rldyour::log "ok" "strict macOS verification passed"
