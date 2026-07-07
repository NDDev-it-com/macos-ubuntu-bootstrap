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
Usage: scripts/ubuntu/verify.sh [--strict] [--skip-optional]
EOF
      exit 0
      ;;
  esac
done

rldyour::ensure_path
rldyour::section "rldyour-new-mac-or-ubuntu Ubuntu verification"

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
  "java"
  "shellcheck"
  "shfmt"
  "pyright-langserver"
  "pyright"
  "ruff"
  "basedpyright"
  "tsc"
  "vtsls"
  "yaml-language-server"
  "bash-language-server"
  "rust-analyzer"
  "gopls"
  "marksman"
  "taplo"
  "clangd"
  "oxlint"
  "biome"
  "osv-scanner"
  "gitleaks"
  "semgrep"
  "hadolint"
  "actionlint"
  "yamllint"
  "markdownlint-cli2"
  "jq"
  "xh"
  "prettier"
  "starship"
  "atuin"
  "fzf"
  "zoxide"
  "tmux"
  "gh"
  "btop"
  "duf"
  "hexyl"
  "pandoc"
  "codex"
  "opencode"
  "vscode-html-language-server"
  "vscode-css-language-server"
  "vscode-json-language-server"
)

# Browser providers (chrome-devtools-mcp, playwright-cli) are intentionally
# optional: they are installed by the --skip-browser-gated
# rldyour::install_browser_providers layer and must not fail strict verification
# on server-only profiles where the browser layer is skipped.
optional_cmds=(
  "mimo"
  "agy"
  "ty"
  "tsgo"
  "sqls"
  "R"
  "jdtls"
  "kotlin-language-server"
  "terraform-ls"
  "helm_ls"
  "cmake-language-server"
  "markdown-oxide"
  "kubeconform"
  "mise"
  "dasel"
  "mlr"
  "delta"
  "eza"
  "watchexec"
  "hyperfine"
  "just"
  "gh-actions-language-server"
  "gitlab-ci-ls"
  "postgres-language-server"
  "chrome-devtools-mcp"
  "playwright-cli"
)

for cmd in "${required_cmds[@]}"; do
  rldyour::require_cmd "$cmd" required
done

rldyour::require_one_of_cmd required claude-code claude
# macOS provides Docker's `docker-language-server` (Homebrew); Ubuntu provides
# `docker-langserver` (dockerfile-language-server-nodejs). Either satisfies the
# Dockerfile LSP requirement.
rldyour::require_one_of_cmd required docker-language-server docker-langserver
# Ubuntu's `fd-find` apt package installs the binary as `fdfind` (Debian naming
# divergence); Homebrew `fd` installs it as `fd`. Either satisfies the optional
# fd requirement.
rldyour::require_one_of_cmd optional fd fdfind
# Ubuntu's `bat` apt package installs the binary as `batcat` (same Debian naming
# divergence); Homebrew installs it as `bat`. Either satisfies the requirement.
rldyour::require_one_of_cmd required bat batcat

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
printf 'java:     %s\n' "$(java -version 2>&1 | head -n 1)"
printf 'clangd:   %s\n' "$(clangd --version 2>&1 | head -n 1)"

if [ "$STRICT" -eq 1 ] || [ "$INCLUDE_OPTIONAL" -eq 0 ]; then
  rldyour::log "info" "verification finished in strict-like mode"
fi
