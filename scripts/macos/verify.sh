#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/common.sh"

STRICT=0
INCLUDE_OPTIONAL=1

for arg in "${@:-}"; do
  case "$arg" in
    --strict)
      STRICT=1
      ;;
    --skip-optional)
      INCLUDE_OPTIONAL=0
      ;;
    --help)
      cat <<'EOF'
Usage: scripts/macos/verify.sh [--strict] [--skip-optional]
EOF
      exit 0
      ;;
  esac
done

rldyour::ensure_path
rldyour::section "rldyour-new-mac-or-ubuntu macOS verification"

required_cmds=(
  "git"
  "curl"
  "node"
  "bun"
  "uv"
  "python3"
  "go"
  "rustup"
  "dart"
  "shellcheck"
  "pyright-langserver"
  "pyright"
  "ruff"
  "typescript-language-server"
  "yaml-language-server"
  "bash-language-server"
  "rust-analyzer"
  "gopls"
  "marksman"
  "taplo"
  "clangd"
  "codex"
  "opencode"
  "vscode-html-language-server"
  "vscode-css-language-server"
  "vscode-json-language-server"
  "docker-language-server"
  "chrome-devtools-mcp"
  "playwright-cli"
)

optional_cmds=(
  "mimo"
  "agy"
)

for cmd in "${required_cmds[@]}"; do
  rldyour::require_cmd "$cmd" required
done

rldyour::require_one_of_cmd required claude-code claude

if [ "$INCLUDE_OPTIONAL" -eq 1 ]; then
  for cmd in "${optional_cmds[@]}"; do
    rldyour::require_cmd "$cmd" optional
  done
fi

rldyour::section "Runtime versions"
printf 'git:      %s\n' "$(git --version)"
printf 'node:     %s\n' "$(node --version)"
printf 'bun:      %s\n' "$(bun --version)"
printf 'uv:       %s\n' "$(uv --version)"
printf 'go:       %s\n' "$(go version | awk '{print $3}')"
printf 'rustup:   %s\n' "$(rustup --version | head -n 1)"
printf 'dart:     %s\n' "$(dart --version 2>&1 | head -n 1)"
printf 'python:   %s\n' "$(python3 --version)"

if [ "$STRICT" -eq 1 ] || [ "$INCLUDE_OPTIONAL" -eq 0 ]; then
  rldyour::log "info" "verification finished in strict-like mode"
fi
