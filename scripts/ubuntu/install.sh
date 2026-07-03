#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/common.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/common.sh"

RLDYOUR_DRY_RUN="${RLDYOUR_DRY_RUN:-1}"
STRICT="${RLDYOUR_STRICT:-0}"
SKIP_SYSTEM="${RLDYOUR_SKIP_SYSTEM:-0}"
SKIP_AI="${RLDYOUR_SKIP_AI:-0}"
SKIP_LSPS="${RLDYOUR_SKIP_LSPS:-0}"
SKIP_BROWSER="${RLDYOUR_SKIP_BROWSER:-0}"
SKIP_CHECKS="${RLDYOUR_SKIP_CHECKS:-0}"

CLAUDE_CODE_VERSION="2.1.199"
CODEX_VERSION="0.142.5"
OPENCODE_VERSION="1.17.13"
MIMOCODE_VERSION="0.1.4"
ANTIGRAVITY_INSTALL_SCRIPT="https://antigravity.google/cli/install.sh"

PYTHON_TOOLING_PACKAGES=(
  pyright-langserver
  pyright
  ruff
  pytest
)

BUN_LSP_PACKAGES=(
  typescript
  typescript-language-server
  yaml-language-server
  bash-language-server
  dockerfile-language-server-nodejs
  vscode-langservers-extracted
  taplo
)

APT_SYSTEM_PACKAGES=(
  ca-certificates
  build-essential
  curl
  gpg
  git
  jq
  python3
  python3-pip
  shellcheck
  clang
  clangd
  golang-go
  unzip
  wget
  zip
  gnupg
  lsb-release
)

APT_GOPLS_PACKAGE="gopls"

usage() {
  cat <<'EOF'
Usage: scripts/ubuntu/install.sh

Entrypoint for Ubuntu/server profile. This script is usually executed via
scripts/bootstrap.sh. It defaults to dry-run mode and supports strict checks
and skip flags.
EOF
}

apt_with_retries() {
  local -a cmd=(sudo -E DEBIAN_FRONTEND=noninteractive apt-get "$@")
  rldyour::run "${cmd[@]}"
}

ensure_apt_repo_updates() {
  rldyour::run sudo apt-get update
}

ensure_apt_packages() {
  rldyour::section "Install baseline apt packages"
  apt_with_retries install -y "${APT_SYSTEM_PACKAGES[@]}"
}

ensure_node() {
  rldyour::section "Ensure Node.js (>=22)"
  if command -v node >/dev/null 2>&1; then
    if rldyour::require_cmd_min_version node 22 "--version"; then
      rldyour::log "ok" "node already available: $(node --version)"
      return 0
    fi
  fi
  rldyour::run bash -c "curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -"
  rldyour::run sudo apt-get install -y nodejs
}

ensure_uv() {
  rldyour::section "Install uv toolchain"
  if command -v uv >/dev/null 2>&1; then
    rldyour::log "ok" "uv already installed: $(uv --version)"
    return 0
  fi
  rldyour::run bash -c "curl -LsSf https://astral.sh/uv/install.sh | sh"
}

ensure_bun() {
  rldyour::section "Install bun runtime"
  if command -v bun >/dev/null 2>&1; then
    rldyour::log "ok" "bun already installed: $(bun --version)"
    return 0
  fi
  rldyour::run bash -c "curl -fsSL https://bun.sh/install | bash"
}

ensure_rust() {
  rldyour::section "Install Rust toolchain"
  if command -v rustup >/dev/null 2>&1; then
    rldyour::log "ok" "rustup already installed"
  else
    rldyour::run bash -c "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y"
  fi
  if [ "$RLDYOUR_DRY_RUN" -eq 0 ] && [ -f "$HOME/.cargo/env" ]; then
    # shellcheck source=/dev/null
    source "$HOME/.cargo/env"
  fi
  if [ "$RLDYOUR_DRY_RUN" -eq 0 ]; then
    rldyour::run rustup component add rust-src rust-analyzer
  fi
}

ensure_dart() {
  rldyour::section "Install Dart (SDK)"
  if command -v dart >/dev/null 2>&1; then
    rldyour::log "ok" "dart already installed"
    return 0
  fi

  rldyour::run bash -c "sudo mkdir -p /usr/share/keyrings"
  rldyour::run bash -c "curl -fsSL https://dl-ssl.google.com/linux/linux_signing_key.pub | gpg --dearmor | sudo tee /usr/share/keyrings/dart-archive-keyring.gpg > /dev/null"
  rldyour::run bash -c "echo \"deb [arch=amd64 signed-by=/usr/share/keyrings/dart-archive-keyring.gpg] https://storage.googleapis.com/download.dartlang.org/linux/debian stable main\" | sudo tee /etc/apt/sources.list.d/dart_stable.list"
  rldyour::run sudo apt-get update
  rldyour::run sudo apt-get install -y dart
}

install_ai_runtimes() {
  rldyour::section "Install AI runtimes (pinned)"
  if ! command -v bun >/dev/null 2>&1; then
    if [ "$STRICT" -eq 1 ]; then
      rldyour::log "error" "bun is required for AI runtime install"
      exit 1
    fi
    rldyour::log "warn" "skip AI runtime install until bun is available"
    return 0
  fi

  if ! command -v claude-code >/dev/null 2>&1; then
    rldyour::run bun add -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"
  else
    rldyour::log "ok" "claude-code already present"
  fi

  if ! command -v codex >/dev/null 2>&1; then
    rldyour::run bun add -g "@openai/codex@${CODEX_VERSION}"
  else
    rldyour::log "ok" "codex already present"
  fi

  if ! command -v opencode >/dev/null 2>&1; then
    rldyour::run bun add -g "opencode-ai@${OPENCODE_VERSION}"
  else
    rldyour::log "ok" "opencode already present"
  fi

  if ! command -v agy >/dev/null 2>&1; then
    rldyour::run bash -c "curl -fsSL ${ANTIGRAVITY_INSTALL_SCRIPT} | bash"
  else
    rldyour::log "ok" "antigravity agy already present"
  fi

  if ! command -v mimo >/dev/null 2>&1; then
    rldyour::run bun add -g "@mimo-ai/cli@${MIMOCODE_VERSION}"
  else
    rldyour::log "ok" "mimo already present"
  fi
}

install_python_tooling() {
  rldyour::section "Install Python tooling"
  if ! command -v uv >/dev/null 2>&1; then
    if [ "$STRICT" -eq 1 ]; then
      rldyour::log "error" "uv is required for Python tooling"
      exit 1
    fi
    rldyour::log "warn" "skip Python tooling until uv is available"
    return 0
  fi
  for pkg in "${PYTHON_TOOLING_PACKAGES[@]}"; do
    if uv tool list | grep -q "^$pkg"; then
      rldyour::log "ok" "$pkg already managed by uv"
    else
      rldyour::run uv tool install --upgrade "$pkg"
    fi
  done
}

install_go_lsp() {
  rldyour::section "Install Go language server"
  if command -v gopls >/dev/null 2>&1; then
    rldyour::log "ok" "gopls already available"
    return 0
  fi
  rldyour::run sudo apt-get install -y "$APT_GOPLS_PACKAGE"
}

install_lsp() {
  rldyour::section "Install LSP set"
  if ! command -v bun >/dev/null 2>&1; then
    if [ "$STRICT" -eq 1 ]; then
      rldyour::log "error" "bun required for language-server bootstrap"
      exit 1
    fi
    rldyour::log "warn" "skip LSP bootstrap without bun"
    return 0
  fi
  for pkg in "${BUN_LSP_PACKAGES[@]}"; do
    rldyour::run bun add -g "$pkg"
  done
}

run_post_checks() {
  rldyour::section "Post-checks"
  bash "$SCRIPT_DIR/verify.sh" --strict --skip-optional
}

if [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

rldyour::assert_root "$REPO_ROOT"
rldyour::ensure_path

rldyour::section "rldyour-new-mac-or-ubuntu (Ubuntu) installer"
rldyour::log "info" "mode: $([ "$RLDYOUR_DRY_RUN" -eq 1 ] && echo dry-run || echo apply)"

if [ "$SKIP_SYSTEM" -eq 0 ]; then
  ensure_apt_repo_updates
  apt_with_retries install -y software-properties-common
  apt_with_retries install -y ca-certificates
  ensure_apt_packages
  ensure_node
  ensure_uv
  ensure_bun
  rldyour::ensure_path
  install_python_tooling
  ensure_rust
  ensure_dart
  install_go_lsp
else
  rldyour::log "warn" "system layer skipped by --skip-system"
fi

if [ "$SKIP_AI" -eq 0 ]; then
  install_ai_runtimes
else
  rldyour::log "warn" "AI runtimes skipped by --skip-ai"
fi

if [ "$SKIP_LSPS" -eq 0 ]; then
  install_lsp
else
  rldyour::log "warn" "LSP layer skipped by --skip-lsps"
fi

if [ "$SKIP_BROWSER" -eq 1 ]; then
  rldyour::log "warn" "browser tooling skipped by --skip-browser"
fi

if [ "$SKIP_CHECKS" -eq 0 ]; then
  run_post_checks
fi
